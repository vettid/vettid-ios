import Foundation

/// The claim-check blob of VAULT-MESSAGING 0.32.0 §5.5, version 1: a version byte, a fresh nonce, and the content
/// framed with its length and padded with Padmé, under a fresh 256-bit key used for this one blob.
///
/// ```
/// blob   = ver (1: 0x01) || nonce (24) || XChaCha20-Poly1305(key, nonce, aad, framed)
/// aad    = "vettid/vms/2/blob" || 0x00 || ver
/// framed = uint32be(len(content)) || content || 0x00 * (Padme(4 + len(content)) - 4 - len(content))
/// ```
///
/// The receiver checks, in this order: the SHA-256 of the received bytes against the reference's `sha256` (constant
/// time, before anything is decrypted), the version, the AEAD, the framing (exact Padmé length, `len` within it, zero
/// padding), and the content's length against the reference's `size`. Fixed by vettid-vault's `blob.json` (§16).
/// Mirrors vettid-android `ClaimBlob`.
public enum ClaimBlob {
    public static let version: UInt8 = 1
    public static let label = Labels.blob

    /// Bytes around the framed plaintext: the version, the nonce and the tag (41).
    public static let overhead = 1 + Suite.xNonceSize + Suite.tagSize
    private static let lenSize = 4
    private static let header = 1 + Suite.xNonceSize

    /// Why a received blob was refused (the vector file's `error` names).
    public enum Failure: String, Sendable {
        case sha256, version, decrypt, framing, size
    }

    /// A refused blob. The description names the failure only; never bytes of the blob or its key.
    public struct Refused: Error, CustomStringConvertible, Sendable {
        public let failure: Failure
        public var description: String { "blob: \(failure.rawValue)" }
    }

    /// A sealed blob: the bytes to upload, its fresh [key], the [sha256] of [blob] and the content's [size]. The caller
    /// wipes the key and the bytes once the reference has been sent (or abandoned).
    public struct Sealed: Sendable {
        public let blob: [UInt8]
        public let key: [UInt8]
        public let sha256: [UInt8]
        public let size: Int
    }

    /// Padmé (Nikitin et al., 2019) for [l] ≥ 2: `E = floor(log2 L)`, `S = floor(log2 E) + 1`, `z = E - S`, and L
    /// rounded up to a multiple of `2^z`.
    public static func padme(_ l: UInt64) -> UInt64 {
        precondition(l >= 2, "padme undefined below 2")
        let e = 63 - l.leadingZeroBitCount
        let s = (Int.bitWidth - 1 - e.leadingZeroBitCount) + 1
        let z = e - s
        if z <= 0 { return l }
        let mask: UInt64 = (1 << UInt64(z)) - 1
        return (l + mask) & ~mask
    }

    /// The length of the blob that holds [contentSize] bytes of content: 41 + Padmé(4 + size).
    public static func blobLength(_ contentSize: UInt64) -> UInt64 { UInt64(overhead) + padme(UInt64(lenSize) + contentSize) }

    /// The AAD for version [ver].
    public static func aad(_ ver: UInt8 = version) -> [UInt8] { Array(label.utf8) + [0, ver] }

    /// [content] framed and padded (also the plaintext of the vault's stored attachment objects, §10.5.1).
    public static func frame(_ content: [UInt8]) throws -> [UInt8] {
        guard !content.isEmpty else { throw CryptoError.format("blob content empty") }
        guard content.count <= UInt32.max - UInt32(lenSize) else { throw CryptoError.format("blob content too large") }
        let total = Int(padme(UInt64(lenSize + content.count)))
        var out = Bytes.uintBE(UInt64(content.count), lenSize) + content
        out.append(contentsOf: [UInt8](repeating: 0, count: total - out.count))
        return out
    }

    /// The content of [framed] after the framing checks; throws ``Refused`` with ``Failure/framing``.
    public static func unframe(_ framed: [UInt8]) throws -> [UInt8] {
        guard framed.count >= lenSize + 1 else { throw Refused(failure: .framing) }
        let n = Int(Bytes.readUintBE(framed, 0, lenSize))
        guard n >= 1, n <= framed.count - lenSize, padme(UInt64(lenSize + n)) == UInt64(framed.count) else {
            throw Refused(failure: .framing)
        }
        var pad: UInt8 = 0
        for b in framed[(lenSize + n)...] { pad |= b }
        guard pad == 0 else { throw Refused(failure: .framing) }
        return Array(framed[lenSize..<(lenSize + n)])
    }

    /// Seals [content] under a fresh key (or [key], for the vector) and a fresh nonce.
    public static func seal(_ content: [UInt8], key: [UInt8]? = nil) throws -> Sealed {
        let key = key ?? Randomness.bytes(Suite.keySize)
        guard key.count == Suite.keySize else { throw CryptoError.key("blob key size") }
        var framed = try frame(content)
        defer { Bytes.wipe(&framed) }
        let nonce = XChaCha20Poly1305.newNonce()
        let ct = try XChaCha20Poly1305.seal(key: key, nonce: nonce, aad: aad(), plaintext: framed)
        let blob = [version] + nonce + ct
        return Sealed(blob: blob, key: key, sha256: Bytes.sha256(blob), size: content.count)
    }

    /// Opens a received [blob] whose reference named [sha256] and [size]: every check of §5.5 in order, nothing
    /// decrypted before the hash and the version passed. Returns the content.
    public static func open(_ blob: [UInt8], key: [UInt8], sha256: [UInt8], size: UInt64) throws -> [UInt8] {
        guard Bytes.constantTimeEquals(Bytes.sha256(blob), sha256) else { throw Refused(failure: .sha256) }
        guard blob.first == version else { throw Refused(failure: .version) }
        guard blob.count >= overhead + lenSize + 1 else { throw Refused(failure: .framing) }
        var framed: [UInt8]
        do {
            framed = try XChaCha20Poly1305.open(
                key: key, nonce: Array(blob[1..<header]), aad: aad(), ciphertext: Array(blob[header...])
            )
        } catch CryptoError.decrypt {
            throw Refused(failure: .decrypt)
        }
        defer { Bytes.wipe(&framed) }
        var content = try unframe(framed)
        guard UInt64(content.count) == size else {
            Bytes.wipe(&content)
            throw Refused(failure: .size)
        }
        return content
    }
}
