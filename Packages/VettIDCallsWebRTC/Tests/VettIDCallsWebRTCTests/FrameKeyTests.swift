import Foundation
import Testing
import VettIDCrypto
@preconcurrency import WebRTC
@testable import VettIDCallsWebRTC

/// The key provider's options (VAULT-MESSAGING §10.10 "Media suites": fixed for every platform), and the media stack's own
/// frame cryptor checked against `CallFrames`, the repository's description of the frame format: the same check
/// vettid-android's `FrameFormatDeviceTest` makes with the library's data packet cryptor under the engine's key provider.
struct FrameKeyTests {
    // VAULT-MESSAGING 0.28.0 vectors (TEST ONLY): a direction key and the frame key derived from it, for each suite.
    static let kDirSuite1 = "df07dfb74e30ab8b952a864b0214911649859b9d371d50cc04daa84d5c952c08"
    static let frameKeySuite1 = "df487affce123283952f691628c1c2de"
    static let kDirSuite2 = "129e7ea015351c448613b72d821141780fbc2681c9562f2b47894d999c609617"
    static let frameKeySuite2 = "e2637ed9e4ab88d26b3f34869104e58d355e1eb7b6c5b7d3aea521bda4fd83da"

    @Test func theOptionsAreTheOnesTheSpecificationFixes() throws {
        for (suite, bits) in [(MediaSuite.aes128Gcm, 128), (MediaSuite.aes256Gcm, 256)] {
            let options = try FrameKeyOptions.options(for: suite)
            #expect(options.sharedKey == false)
            #expect(options.ratchetSalt == Array("vettid/vms/2/call-frame".utf8))
            #expect(options.ratchetSalt == Array(suite.frameLabel.utf8))
            #expect(options.ratchetWindowSize == 0)
            #expect(options.uncryptedMagicBytes.isEmpty)
            #expect(options.failureTolerance == 10)
            #expect(options.keyRingSize == 1)
            #expect(options.discardFrameWhenCryptorNotReady)
            #expect(options.hkdf)
            #expect(options.keySizeBits == bits)
            #expect(options.keySizeBits == suite.frameKeySize * 8)
        }
    }

    @Test func aKeySizeThatIsNotExactly128Or256BitsIsRefused() throws {
        #expect(try FrameKeyOptions.bits(forKeyBytes: 16) == 128)
        #expect(try FrameKeyOptions.bits(forKeyBytes: 32) == 256)
        // The library would take every one of these as 128 without a word.
        for bytes in [0, 1, 8, 15, 17, 24, 31, 33, 48, 64] {
            #expect(throws: MediaEngineError.self) { try FrameKeyOptions.bits(forKeyBytes: bytes) }
        }
    }

    @Test func theEnginesSuitesAreTheRegistrysInItsOrder() {
        #expect(WebRtcMediaEngine.supportedSuites == [.aes256Gcm, .aes128Gcm])
        #expect(MediaSuite.ordered(WebRtcMediaEngine.supportedSuites) == MediaSuite.preference)
    }

    @Test func theLibrarysFramesOpenUnderTheSpecificationsFrameKeyAndNoOther() throws {
        let vectors = [
            (MediaSuite.aes128Gcm, Self.kDirSuite1, Self.frameKeySuite1),
            (MediaSuite.aes256Gcm, Self.kDirSuite2, Self.frameKeySuite2),
        ]
        for (suite, kDir, expected) in vectors {
            let material = hex(kDir)
            let frameKey = try CallFrames.frameKey(material, suite: suite)
            #expect(Bytes.hex(frameKey) == expected)
            let (sealed, packet) = try encrypt(suite, material: material, message: Array("VettID frame format".utf8))
            // The library's output opens under the frame key the specification derives, to the same bytes.
            let opened = CallFrames.open(frameKey: frameKey, sealed: sealed, clearBytes: 0)
            #expect(opened == Array("VettID frame format".utf8))
            #expect(Array(packet.iv).count == CallFrames.ivSize)
            #expect(packet.keyIndex == UInt32(CallFrames.keyIndex))
            // And under no key of the other suite's length: the key size is the suite's, not the library's default.
            let other: MediaSuite = suite == .aes128Gcm ? .aes256Gcm : .aes128Gcm
            let otherKey = try CallFrames.frameKey(material, suite: other)
            #expect(CallFrames.open(frameKey: otherKey, sealed: sealed, clearBytes: 0) == nil)
        }
    }

    /// The spike's finding: the stack's shorter initializers (and the full one with PBKDF2) derive another key, which
    /// the other platforms cannot open. The engine must never make a provider that way.
    @Test func aPbkdf2ProviderMakesFramesThatDoNotOpenUnderTheSpecificationsKey() throws {
        let material = hex(Self.kDirSuite1)
        var options = try FrameKeyOptions.options(for: .aes128Gcm)
        options.hkdf = false
        let provider = options.makeProvider()
        let cryptor = try #require(RTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: provider))
        provider.setKey(Data(material), with: 0, forParticipant: "send")
        let packet = try #require(cryptor.encrypt("send", keyIndex: 0, data: Data("x".utf8)))
        let sealed = Array(packet.data) + Array(packet.iv) + [UInt8(CallFrames.ivSize), CallFrames.keyIndex]
        let frameKey = try CallFrames.frameKey(material, suite: .aes128Gcm)
        #expect(CallFrames.open(frameKey: frameKey, sealed: sealed, clearBytes: 0) == nil)
    }

    private func encrypt(_ suite: MediaSuite, material: [UInt8], message: [UInt8]) throws -> ([UInt8], RTCEncryptedPacket) {
        let provider = try FrameKeyOptions.options(for: suite).makeProvider()
        let cryptor = try #require(RTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: provider))
        provider.setKey(Data(material), with: 0, forParticipant: "send")
        let packet = try #require(cryptor.encrypt("send", keyIndex: 0, data: Data(message)))
        // The frame format: ciphertext and tag, then the IV, then the IV's length and the key index.
        return (Array(packet.data) + Array(packet.iv) + [UInt8(CallFrames.ivSize), UInt8(packet.keyIndex)], packet)
    }

    private func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}
