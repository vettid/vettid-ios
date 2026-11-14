import Foundation
import VettIDCalls
import VettIDCrypto
@preconcurrency import WebRTC

/// The frame cryptor's key provider options for one media suite, written out so that they can be checked
/// (VAULT-MESSAGING §10.10 "Media suites", the table of key provider options, fixed for every platform; CALLS-PLAN §12).
///
/// Per-participant keys (one per direction), HKDF-SHA-256 with the suite's frame label as salt, no automatic ratchet, no
/// "unencrypted" magic trailer (a frame that does not decrypt is never played), a key ring of one, and the suite's
/// frame-key length. The stack's shorter initializers default to PBKDF2 (100,000 rounds, a different key), which does
/// not match the other platforms: only the full initializer is used.
struct FrameKeyOptions: Equatable, Sendable {
    var sharedKey = false
    var ratchetSalt: [UInt8]
    var ratchetWindowSize = 0
    var uncryptedMagicBytes: [UInt8] = []
    /// Decryption failures after which the receiver reports `decryptionFailed` (about a fifth of a second of audio).
    var failureTolerance = 10
    var keyRingSize = 1
    var discardFrameWhenCryptorNotReady = true
    /// Always HKDF.
    var hkdf = true
    /// The frame key's length in bits: exactly 128 or 256.
    var keySizeBits: Int

    static let failureTolerance = 10
    static let keyRingSize = 1
    private static let aes128Bits = 128
    private static let aes256Bits = 256

    /// The options of [suite]. Throws unless the suite's frame key is exactly 128 or 256 bits.
    static func options(for suite: MediaSuite) throws -> FrameKeyOptions {
        FrameKeyOptions(ratchetSalt: Array(suite.frameLabel.utf8), keySizeBits: try bits(forKeyBytes: suite.frameKeySize))
    }

    /// The key provider's `keySize` for a frame key of [bytes] bytes. Only 128 and 256 bits pass: the library takes **any
    /// other value as 128 without a word**, so no value it would quietly turn into another suite ever reaches it.
    static func bits(forKeyBytes bytes: Int) throws -> Int {
        let bits = bytes * 8
        guard bits == aes128Bits || bits == aes256Bits else {
            throw MediaEngineError("a frame key of \(bits) bits")
        }
        return bits
    }

    /// The key provider for these options (the full initializer, always).
    func makeProvider() -> RTCFrameCryptorKeyProvider {
        RTCFrameCryptorKeyProvider(
            ratchetSalt: Data(ratchetSalt),
            ratchetWindowSize: Int32(ratchetWindowSize),
            sharedKeyMode: sharedKey,
            uncryptedMagicBytes: Data(uncryptedMagicBytes),
            failureTolerance: Int32(failureTolerance),
            keyRingSize: Int32(keyRingSize),
            discardFrameWhenCryptorNotReady: discardFrameWhenCryptorNotReady,
            keyDerivationAlgorithm: hkdf ? .HKDF : .PBKDF2,
            keySize: Int32(keySizeBits)
        )
    }
}

/// A failure of the engine itself. The text never holds an SDP, an address or key material: the stack's own text may quote
/// the SDP, so only that something failed goes on.
public struct MediaEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    public let what: String

    public init(_ what: String) { self.what = what }

    public var description: String { "media engine: \(what)" }
}

/// Bytes that are wiped in place when they have been handed on: the copy of a key that the stack's call needs.
final class SecretBytes: @unchecked Sendable {
    private var bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// Flips every byte (a test fault: the wrong key).
    func invert() {
        for index in bytes.indices { bytes[index] ^= 0xFF }
    }

    var data: Data { Data(bytes) }

    func wipe() { Bytes.wipe(&bytes) }
}
