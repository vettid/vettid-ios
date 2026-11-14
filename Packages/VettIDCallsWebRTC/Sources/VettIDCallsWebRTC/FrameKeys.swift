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

/// A key copy that is wiped in place when it has been handed on. The stack gets a `Data` that wraps this very buffer (this
/// code makes no further copy), so wiping the buffer after the call wipes what this code handed over.
final class SecretBytes: @unchecked Sendable {
    private let buffer: NSMutableData

    init(_ bytes: [UInt8]) { buffer = NSMutableData(bytes: bytes, length: bytes.count) }

    deinit { wipe() }

    var count: Int { buffer.length }

    /// Flips every byte (a test fault: the wrong key).
    func invert() {
        let pointer = buffer.mutableBytes.bindMemory(to: UInt8.self, capacity: buffer.length)
        for index in 0..<buffer.length { pointer[index] ^= 0xFF }
    }

    /// The bytes, without a copy (the stack reads this very buffer, so ``wipe()`` wipes what it was given): valid until then.
    /// (`Data(referencing:)` would copy a mutable buffer.)
    var data: Data { Data(bytesNoCopy: buffer.mutableBytes, count: buffer.length, deallocator: .none) }

    /// Where the bytes are (a test that ``data`` shares them).
    var address: UnsafeRawPointer { buffer.bytes }

    var isWiped: Bool { (0..<buffer.length).allSatisfy { buffer.bytes.load(fromByteOffset: $0, as: UInt8.self) == 0 } }

    func wipe() { buffer.resetBytes(in: NSRange(location: 0, length: buffer.length)) }
}
