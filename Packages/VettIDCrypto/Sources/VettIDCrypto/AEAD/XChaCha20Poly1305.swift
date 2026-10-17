import Clibsodium

/// XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha): session-mode envelopes, claim bundles, claim-check blobs and
/// critical-item values (§4.2, §5.5, §6.4, §10.7). A fresh random 192-bit nonce per message. libsodium (IOS-PLAN ID6).
/// Mirrors vettid-android `XChaCha20Poly1305`.
public enum XChaCha20Poly1305 {
    /// A fresh random 24-byte nonce.
    public static func newNonce() -> [UInt8] { Randomness.bytes(Suite.xNonceSize) }

    /// Returns ciphertext || tag.
    public static func seal(key: [UInt8], nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) throws -> [UInt8] {
        try checkSizes(key, nonce)
        Sodium.require()
        var out = [UInt8](repeating: 0, count: plaintext.count + Suite.tagSize)
        var outLen: UInt64 = 0
        crypto_aead_xchacha20poly1305_ietf_encrypt(
            &out, &outLen, plaintext, UInt64(plaintext.count), aad, UInt64(aad.count), nil, nonce, key
        )
        return out
    }

    /// Opens ciphertext || tag; the tag is checked in constant time by the AEAD.
    public static func open(key: [UInt8], nonce: [UInt8], aad: [UInt8], ciphertext: [UInt8]) throws -> [UInt8] {
        guard ciphertext.count >= Suite.tagSize else { throw CryptoError.decrypt }
        try checkSizes(key, nonce)
        Sodium.require()
        var out = [UInt8](repeating: 0, count: ciphertext.count - Suite.tagSize)
        var outLen: UInt64 = 0
        let status = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &out, &outLen, nil, ciphertext, UInt64(ciphertext.count), aad, UInt64(aad.count), nonce, key
        )
        guard status == 0 else {
            Bytes.wipe(&out)
            throw CryptoError.decrypt
        }
        return out
    }

    private static func checkSizes(_ key: [UInt8], _ nonce: [UInt8]) throws {
        guard key.count == Suite.keySize, nonce.count == Suite.xNonceSize else { throw CryptoError.key("xchacha size") }
    }
}
