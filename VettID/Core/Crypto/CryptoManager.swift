import Foundation
import CryptoKit

/// Manages all cryptographic operations for VettID
/// Uses X25519 for key exchange and ChaChaPoly for authenticated encryption
final class CryptoManager {

    // MARK: - X25519 Key Generation

    /// Generate a new X25519 key pair for credential encryption
    static func generateX25519KeyPair() -> (privateKey: Curve25519.KeyAgreement.PrivateKey,
                                             publicKey: Curve25519.KeyAgreement.PublicKey) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }

    // MARK: - Ed25519 Signing

    /// Generate a new Ed25519 signing key pair
    static func generateEd25519KeyPair() -> (privateKey: Curve25519.Signing.PrivateKey,
                                              publicKey: Curve25519.Signing.PublicKey) {
        let privateKey = Curve25519.Signing.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }

    /// Sign data with Ed25519
    static func sign(data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        return try privateKey.signature(for: data)
    }

    /// Verify Ed25519 signature
    static func verify(signature: Data, for data: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        return publicKey.isValidSignature(signature, for: data)
    }

    // MARK: - Hybrid Encryption (X25519 + ChaChaPoly)

    /// Encrypt data using X25519 key exchange + ChaCha20-Poly1305
    /// - Parameters:
    ///   - plaintext: Data to encrypt
    ///   - recipientPublicKey: Recipient's X25519 public key
    /// - Returns: Encrypted payload containing ephemeral public key and ciphertext
    static func encrypt(plaintext: Data,
                        recipientPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> EncryptedPayload {
        // Generate ephemeral key pair
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeralPrivate.publicKey

        // Derive shared secret
        let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: recipientPublicKey)

        // Derive symmetric key using HKDF
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: "credential-encryption-v1".data(using: .utf8)!,
            outputByteCount: 32
        )

        // Encrypt with ChaCha20-Poly1305
        let sealedBox = try ChaChaPoly.seal(plaintext, using: symmetricKey)

        return EncryptedPayload(
            ephemeralPublicKey: ephemeralPublic.rawRepresentation,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
    }

    /// Decrypt data using X25519 key exchange + ChaCha20-Poly1305
    static func decrypt(payload: EncryptedPayload,
                        privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        // Reconstruct ephemeral public key
        let ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: payload.ephemeralPublicKey
        )

        // Derive shared secret
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)

        // Derive symmetric key
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: "credential-encryption-v1".data(using: .utf8)!,
            outputByteCount: 32
        )

        // Reconstruct sealed box
        let nonce = try ChaChaPoly.Nonce(data: payload.nonce)
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: payload.ciphertext,
            tag: payload.tag
        )

        // Decrypt
        return try ChaChaPoly.open(sealedBox, using: symmetricKey)
    }

    // MARK: - Secure Random

    /// Generate cryptographically secure random bytes
    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Generate a 256-bit random token (for LAT)
    static func generateToken() -> Data {
        return randomBytes(count: 32)
    }
}

// MARK: - Supporting Types

struct EncryptedPayload: Codable {
    let ephemeralPublicKey: Data  // 32 bytes
    let nonce: Data               // 12 bytes
    let ciphertext: Data
    let tag: Data                 // 16 bytes

    /// Combined representation for transmission
    var combined: Data {
        ephemeralPublicKey + nonce + ciphertext + tag
    }
}
