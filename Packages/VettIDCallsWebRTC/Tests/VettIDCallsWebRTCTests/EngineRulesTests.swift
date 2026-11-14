import Foundation
import Testing
import VettIDCalls
import VettIDCrypto
@preconcurrency import WebRTC
@testable import VettIDCallsWebRTC

/// The engine's rules that need an engine (and so the stack) but not a whole call. Serialized: one stack, one audio device.
@Suite(.serialized) @MainActor
struct EngineRulesTests {
    private func engine(_ config: MediaConfig = MediaConfig()) throws -> WebRtcMediaEngine {
        _ = TestStack.ready
        return try #require(try WebRtcMediaEngineFactory(testBuild: true).create(config: config) as? WebRtcMediaEngine)
    }

    private func connectionOpen(_ engine: WebRtcMediaEngine) -> Bool {
        WebRtcRuntime.queue.sync { engine.core.connection != nil }
    }

    // MARK: close racing the first stack call

    /// After the close, every body that reaches the queue throws and opens nothing.
    @Test func nothingIsOpenedAfterTheClose() async throws {
        let engine = try engine()
        engine.close()
        await #expect(throws: MediaEngineError.self) {
            try await engine.core.onQueue { core in try core.prepareAnswer(servers: [], suite: .aes128Gcm) }
        }
        await #expect(throws: MediaEngineError.self) {
            try await engine.core.onQueue { core in try core.openOffer(suite: .aes128Gcm) }
        }
        #expect(!connectionOpen(engine))
    }

    /// `close()` on the main actor against an accept that is on its way to the queue: whichever comes first, no peer
    /// connection is left open.
    @Test func aCloseDuringAnAcceptLeavesNoOpenConnection() async throws {
        let caller = try engine()
        let offer = try await caller.createOffer(suite: .aes128Gcm)
        caller.close()
        for round in 0..<30 {
            let callee = try engine()
            let accepting = Task { _ = try? await callee.acceptOffer(sdp: offer, servers: [], suite: .aes128Gcm) }
            for _ in 0..<(round % 4) { await Task.yield() }
            callee.close()
            await accepting.value
            // The queue is serial: when this returns, the close's teardown and everything before it have run.
            WebRtcRuntime.queue.sync {}
            #expect(!connectionOpen(callee), "round \(round)")
        }
    }

    // MARK: key copies and the no-rekey rule

    /// What the stack is given is the buffer itself, not a copy: wiping it wipes what the stack was handed (and its bridge).
    @Test func theKeyHandedToTheStackIsTheBufferThatIsWiped() {
        let key = SecretBytes(randomKey())
        let data = key.data
        data.withUnsafeBytes { #expect($0.baseAddress == key.address) }
        let bridged = data as NSData
        #expect(bridged.bytes == key.address)
        key.wipe()
        #expect(data.allSatisfy { $0 == 0 } && (bridged as Data).allSatisfy { $0 == 0 })
    }

    @Test func theKeyCopiesAreWipedAfterTheKeysAreSet() async throws {
        let engine = try engine()
        _ = try await engine.createOffer(suite: .aes256Gcm)
        let send = SecretBytes(randomKey())
        let receive = SecretBytes(randomKey())
        #expect(!send.isWiped && !receive.isWiped)
        try await engine.core.onQueue { core in try core.takeKeys(.aes256Gcm, send: send, receive: receive) }
        #expect(send.isWiped && receive.isWiped)
        // Wiped on a refusal too.
        let again = SecretBytes(randomKey())
        let other = SecretBytes(randomKey())
        await #expect(throws: MediaNotEncryptedError.self) {
            try await engine.core.onQueue { core in try core.takeKeys(.aes128Gcm, send: again, receive: other) }
        }
        engine.close()
    }

    /// A decryption failure is remembered for good: even with the receiver's state moved on, no key is set again.
    @Test func aDecryptionFailureForbidsEveryLaterKey() async throws {
        let engine = try engine()
        _ = try await engine.createOffer(suite: .aes128Gcm)
        var send = randomKey(), receive = randomKey()
        try await engine.setKeys(.aes128Gcm, send: &send, receive: &receive)
        engine.core.everFailed.value = true
        engine.core.receiveState.value = .ok
        send = randomKey()
        receive = randomKey()
        await #expect(throws: MediaEngineError.self) { try await engine.setKeys(.aes128Gcm, send: &send, receive: &receive) }
        #expect(send.allSatisfy { $0 == 0 } && receive.allSatisfy { $0 == 0 })
        engine.close()
    }

    /// The cryptor callback is what sets the flag.
    @Test func theCryptorCallbackRemembersTheFailure() async throws {
        let engine = try engine()
        _ = try await engine.createOffer(suite: .aes128Gcm)
        let observer = try #require(await engine.core.onQueue { $0.receiverObserver })
        #expect(!engine.core.everFailed.value)
        observer.frameCryptor(
            try #require(await engine.core.onQueue { $0.receiverCryptor }), didStateChangeWithParticipantId: "receive",
            with: .decryptionFailed
        )
        #expect(engine.core.everFailed.value)
        engine.close()
    }

    // MARK: the test options

    @Test func aNonTestFactoryRefusesEveryTestOption() {
        let plain = WebRtcMediaEngineFactory()
        let configs = [
            MediaConfig(dtlsPqcTrial: true),
            MediaConfig(faults: MediaFaults(keepRemoteSsrc: true)),
            MediaConfig(faults: MediaFaults(misstateOwnSsrc: true)),
            MediaConfig(faults: MediaFaults(sendUnencrypted: true)),
            MediaConfig(faults: MediaFaults(wrongSendKey: true)),
            MediaConfig(relayOnly: true),
        ]
        for config in configs {
            #expect(throws: MediaEngineError.self) { try plain.create(config: config) }
        }
    }

    // MARK: the library's frame cryptor in the other direction, and its ratchet

    /// Frames sealed by `CallFrames.seal` are played by the library's cryptor (suite 2), and not when sealed under the
    /// 16-byte key.
    @Test func theLibraryOpensFramesSealedByCallFrames() throws {
        let material = randomKey()
        let provider = try FrameKeyOptions.options(for: .aes256Gcm).makeProvider()
        let cryptor = try #require(RTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: provider))
        provider.setKey(Data(material), with: 0, forParticipant: "send")
        let message = Array("sealed in Swift".utf8)
        let iv = CallFrames.iv(ssrc: 0x1234_5678, timestamp: 960, sendCount: 3)
        for (suite, shouldOpen) in [(MediaSuite.aes256Gcm, true), (MediaSuite.aes128Gcm, false)] {
            let key = try CallFrames.frameKey(material, suite: suite)
            let sealed = try CallFrames.seal(frameKey: key, frame: message, clearBytes: 0, iv: iv)
            let body = Data(sealed[0..<(sealed.count - CallFrames.trailerSize - CallFrames.ivSize)])
            let packet = RTCEncryptedPacket(data: body, iv: Data(iv), keyIndex: 0)
            let opened = cryptor.decrypt("send", encryptedPacket: packet)
            if shouldOpen {
                #expect(opened.map { Array($0) } == message)
            } else {
                #expect(opened == nil)
            }
        }
    }

    /// The library's ratchet step under the engine's key provider, for the record (the engine never ratchets: window 0, no
    /// call of `ratchetKey`): the next key material is HKDF-SHA-256(material, frame label, 128 zero bytes, L = 32) for both
    /// suites, and the frames after it open under the frame key derived from that.
    @Test(arguments: [MediaSuite.aes256Gcm, MediaSuite.aes128Gcm])
    func theLibrarysRatchetStepUnderTheEnginesKeyProvider(_ suite: MediaSuite) throws {
        let provider = try FrameKeyOptions.options(for: suite).makeProvider()
        let cryptor = try #require(RTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: provider))
        let material = randomKey()
        provider.setKey(Data(material), with: 0, forParticipant: "send")
        let next = Array(provider.ratchetKey("send", with: 0))
        let expected = try Hkdf.derive(
            ikm: material, salt: Array(suite.frameLabel.utf8), info: [UInt8](repeating: 0, count: 128), length: 32
        )
        #expect(next == expected)
        let packet = try #require(cryptor.encrypt("send", keyIndex: 0, data: Data("after".utf8)))
        let sealed = Array(packet.data) + Array(packet.iv) + [UInt8(CallFrames.ivSize), UInt8(packet.keyIndex)]
        let key = try CallFrames.frameKey(next, suite: suite)
        #expect(CallFrames.open(frameKey: key, sealed: sealed, clearBytes: 0) == Array("after".utf8))
    }

    // MARK: adoptOfferedSection

    /// The offered section is not the transceiver that carries the cryptors (forced here by making the engine forget which
    /// one it is): the track and the cryptors move to the offered one before the answer, and the answer is still made.
    @Test func theCryptorsMoveToTheOfferedSectionWhenTheStackGaveAnotherTransceiver() async throws {
        let caller = try engine()
        let callee = try engine()
        let offer = try await caller.createOffer(suite: .aes128Gcm)
        try await callee.core.onQueue { core in try core.prepareAnswer(servers: [], suite: .aes128Gcm) }
        try await callee.core.setRemote(.offer, sdp: offer)
        try await callee.core.onQueue { core in core.senderId = "forced: not the offered section's sender" }
        let answer = try await callee.core.answerDescription()
        #expect(answer.contains("m=audio"))
        let state = try await callee.core.onQueue { core in
            (core.moved, core.senderCryptor?.enabled == true, core.receiverCryptor?.enabled == true,
             core.senderId == core.connection?.transceivers.first { !$0.isStopped }?.sender.senderId)
        }
        #expect(state.0 && state.1 && state.2 && state.3)
        caller.close()
        callee.close()
    }
}
