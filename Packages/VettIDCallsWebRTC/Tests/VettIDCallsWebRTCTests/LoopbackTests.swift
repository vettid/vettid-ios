import Foundation
import Testing
import VettIDCalls
import VettIDCrypto
@preconcurrency import WebRTC
@testable import VettIDCallsWebRTC

/// vettid-android's `FrameFormatDeviceTest`, as far as a process on this machine can take it: two real engines, each driven
/// as a call drives it, on one stack whose audio device is ``FakeAudioDevice`` (no hardware). DTLS-SRTP stays on, so the
/// frames cannot be read off the wire (Android's test switches it off to do that, in a test-only stack: not ported);
/// the HKDF derivation, key size and trailer layout are checked in `FrameKeyTests` against the library's own cryptor instead, and here the receivers' and
/// senders' cryptor states and the statistics show that encrypted audio flows and is decrypted. Serialized: the tests
/// share the process's one stack and audio device.
@Suite(.serialized) @MainActor
struct LoopbackTests {
    @Test(arguments: [MediaSuite.aes128Gcm, MediaSuite.aes256Gcm])
    func encryptedAudioFlowsBothWaysAndTheCryptorsReportOk(_ suite: MediaSuite) async throws {
        let call = try LoopbackCall()
        defer { call.close() }
        try await call.connect(suiteA: suite, suiteB: suite, kCaller: randomKey(), kCallee: randomKey())

        let ok = await call.wait {
            for heard in [call.heardA, call.heardB] {
                if !heard.states(.send).contains(.ok) || !heard.states(.receive).contains(.ok) { return false }
            }
            return true
        }
        #expect(ok, "suite \(suite.id): A \(call.heardA.summary); B \(call.heardB.summary)")
        for heard in [call.heardA, call.heardB] {
            #expect(!heard.states(.receive).contains(.decryptionFailed))
            #expect(!heard.states(.send).contains(.encryptionFailed))
        }

        // The statistics: audio arrived on exactly one stream, on a direct (host) path, as Opus.
        let flowing = await call.wait {
            guard let a = await call.a.diagnostics(), let b = await call.b.diagnostics() else { return false }
            return a.packetsReceived > 20 && b.packetsReceived > 20
        }
        #expect(flowing)
        for engine in [call.a, call.b] {
            let reading = try #require(await engine.diagnostics())
            #expect(reading.inboundAudioStreams == 1)
            #expect(reading.relayed == false)
            #expect(reading.receiveCodec.lowercased() == "audio/opus")
            #expect(reading.sendCodec.lowercased() == "audio/opus")
            #expect(reading.sendCryptor == .ok)
            #expect(reading.receiveCryptor == .ok)
        }
        #expect(TestStack.device.delivered > 0)
        #expect(call.heardA.events.contains { if case .connection(.connected) = $0 { true } else { false } })
    }

    /// The other side's `a=ssrc` lines never reach the stack (`CallMedia.sdpWithoutSsrc`): the offer has them, the callee's
    /// stack holds a remote description without them, and with the fault on it holds them.
    @Test func theOtherSidesSsrcLinesAreStrippedBeforeTheStackSeesThem() async throws {
        let call = try LoopbackCall()
        defer { call.close() }
        try await call.connect(suiteA: .aes128Gcm, suiteB: .aes128Gcm, kCaller: randomKey(), kCallee: randomKey())
        #expect(call.offer.contains("a=ssrc:"))
        #expect(call.answer.contains("a=ssrc:"))
        #expect(!(await call.remoteSdp(of: call.b)).contains("a=ssrc"))
        #expect(!(await call.remoteSdp(of: call.a)).contains("a=ssrc"))

        let faulty = try LoopbackCall(calleeFaults: MediaFaults(keepRemoteSsrc: true))
        defer { faulty.close() }
        try await faulty.connect(suiteA: .aes128Gcm, suiteB: .aes128Gcm, kCaller: randomKey(), kCallee: randomKey())
        #expect((await faulty.remoteSdp(of: faulty.b)).contains("a=ssrc:"))
    }

    /// Cryptors made for different suites hear nothing in either direction, and a key is never set again after that.
    @Test func mismatchedSuitesHearNothingInEitherDirection() async throws {
        let call = try LoopbackCall()
        defer { call.close() }
        try await call.connect(suiteA: .aes256Gcm, suiteB: .aes128Gcm, kCaller: randomKey(), kCallee: randomKey())
        let failed = await call.wait {
            call.heardA.states(.receive).contains(.decryptionFailed) && call.heardB.states(.receive).contains(.decryptionFailed)
        }
        #expect(failed, "A \(call.heardA.summary); B \(call.heardB.summary)")
        #expect(!call.heardA.states(.receive).contains(.ok))
        #expect(!call.heardB.states(.receive).contains(.ok))

        var send = randomKey(), receive = randomKey()
        await #expect(throws: MediaEngineError.self) { try await call.a.setKeys(.aes256Gcm, send: &send, receive: &receive) }
        #expect(send.allSatisfy { $0 == 0 } && receive.allSatisfy { $0 == 0 })
    }

    /// The engine never remakes its cryptors: an engine made for one suite refuses keys for the other, the call ends as
    /// not encrypted, and the arrays it was given are wiped all the same. Its sender, made and enabled but never keyed,
    /// sends nothing.
    @Test func keysForAnotherSuiteAreRefusedAndNothingIsSent() async throws {
        let call = try LoopbackCall()
        defer { call.close() }
        _ = TestStack.ready
        let offer = try await call.a.createOffer(suite: .aes256Gcm)
        #expect(offer.contains("opus"))
        var send = randomKey(), receive = randomKey()
        await #expect(throws: MediaNotEncryptedError.self) { try await call.a.setKeys(.aes128Gcm, send: &send, receive: &receive) }
        #expect(send.allSatisfy { $0 == 0 } && receive.allSatisfy { $0 == 0 })
        // The same suite is taken, and wiped.
        send = randomKey()
        receive = randomKey()
        try await call.a.setKeys(.aes256Gcm, send: &send, receive: &receive)
        #expect(send.allSatisfy { $0 == 0 } && receive.allSatisfy { $0 == 0 })
        let state = await call.a.diagnostics()
        #expect(state?.sendCryptor != .ok)
    }

    /// An engine offers Opus alone, in one audio section, unified plan, bundled.
    @Test func theOfferIsOneOpusAudioSection() async throws {
        let call = try LoopbackCall()
        defer { call.close() }
        _ = TestStack.ready
        let offer = try await call.a.createOffer(suite: .aes128Gcm)
        try CallMedia.requireOneOpusAudioSection(offer)
        #expect(offer.contains("a=sendrecv"))
        #expect(offer.contains("a=rtcp-mux"))
        #expect(offer.contains("a=group:BUNDLE"))
        let codecs = offer.components(separatedBy: "\n").filter { $0.hasPrefix("a=rtpmap:") }.map { $0.lowercased() }
        #expect(codecs.contains { $0.contains("opus/48000") })
        #expect(!codecs.contains { $0.contains("pcmu") || $0.contains("pcma") || $0.contains("isac") || $0.contains("g722") })
    }

    /// A second media section in the offer is media no cryptor covers: the engine refuses it, as not encrypted, before
    /// any answer exists (the signalling refuses such offers earlier; this is the second lock).
    @Test func anOfferWithASecondAudioSectionIsRefusedAsNotEncrypted() async throws {
        _ = TestStack.ready
        let two = try await Self.offerWithTwoAudioSections()
        let engine = try #require(try WebRtcMediaEngineFactory().create(config: MediaConfig()) as? WebRtcMediaEngine)
        defer { engine.close() }
        await #expect(throws: MediaNotEncryptedError.self) {
            _ = try await engine.acceptOffer(sdp: two, servers: [], suite: .aes128Gcm)
        }
    }

    /// An offer as a stack that was not told the call's rules would make it.
    private static func offerWithTwoAudioSections() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            WebRtcRuntime.queue.async {
                let config = RTCConfiguration()
                config.sdpSemantics = .unifiedPlan
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                guard let pc = WebRtcRuntime.factory().peerConnection(with: config, constraints: constraints, delegate: nil) else {
                    continuation.resume(throwing: MediaEngineError("no peer connection"))
                    return
                }
                _ = pc.addTransceiver(of: .audio)
                _ = pc.addTransceiver(of: .audio)
                pc.offer(for: constraints) { description, _ in
                    // Closed later, not inside the stack's own callback.
                    WebRtcRuntime.queue.asyncAfter(deadline: .now() + 0.5) { pc.close() }
                    if let description {
                        continuation.resume(returning: description.sdp)
                    } else {
                        continuation.resume(throwing: MediaEngineError("no offer"))
                    }
                }
            }
        }
    }

    @Test func aTestConfigurationIsRefusedInABuildThatIsNotATestBuild() throws {
        let plain = WebRtcMediaEngineFactory()
        #expect(throws: MediaEngineError.self) { try plain.create(config: MediaConfig(relayOnly: true)) }
        #expect(throws: MediaEngineError.self) { try plain.create(config: MediaConfig(faults: MediaFaults(sendUnencrypted: true))) }
        #expect(plain.suites == [.aes256Gcm, .aes128Gcm])
    }

    @Test func muteAndHoldKeepTheTrackOffUntilBothAreLifted() async throws {
        let call = try LoopbackCall()
        defer { call.close() }
        _ = TestStack.ready
        _ = try await call.a.createOffer(suite: .aes128Gcm)
        func enabled() async throws -> Bool { try await call.a.core.onQueue { $0.track?.isEnabled ?? false } }
        #expect(try await enabled())
        call.a.setMuted(true)
        #expect(try await !enabled())
        call.a.setHeld(true)
        call.a.setMuted(false)
        #expect(try await !enabled())
        call.a.setHeld(false)
        #expect(try await enabled())
        call.a.setHeld(true)
        #expect(try await !enabled())
    }
}
