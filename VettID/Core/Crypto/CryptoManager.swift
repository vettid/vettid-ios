import Foundation
import CryptoKit

/// Manages all cryptographic operations for VettID
/// Uses X25519 for key exchange and ChaChaPoly for authenticated encryption
final class CryptoManager {

    // MARK: - X25519 Key Generation

    /// Generate a new X25519 key pair for key agreement
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

    // MARK: - Password Encryption (for UTK flow)

    /// Encrypt a password hash using a UTK public key
    /// This is used during enrollment and authentication to securely send the password hash to the server
    ///
    /// Flow:
    /// 1. Generate ephemeral X25519 keypair
    /// 2. Compute shared secret with UTK public key
    /// 3. Derive encryption key using HKDF
    /// 4. Encrypt password hash with ChaCha20-Poly1305
    ///
    /// - Parameters:
    ///   - passwordHash: The Argon2id hash of the password
    ///   - utkPublicKeyBase64: The UTK public key (base64 encoded)
    /// - Returns: Encrypted password payload ready for API transmission
    static func encryptPasswordHash(
        passwordHash: Data,
        utkPublicKeyBase64: String
    ) throws -> EncryptedPasswordPayload {
        // Decode UTK public key
        guard let utkPublicKeyData = Data(base64Encoded: utkPublicKeyBase64) else {
            throw CryptoError.invalidPublicKey
        }

        let utkPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: utkPublicKeyData)

        // Generate ephemeral key pair
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeralPrivate.publicKey

        // Derive shared secret
        let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: utkPublicKey)

        // Derive symmetric key using HKDF with the specified info string
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: "password-encryption".data(using: .utf8)!,
            outputByteCount: 32
        )

        // Generate random 96-bit nonce
        let nonceData = randomBytes(count: 12)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)

        // Encrypt with ChaCha20-Poly1305
        let sealedBox = try ChaChaPoly.seal(passwordHash, using: symmetricKey, nonce: nonce)

        // Combine ciphertext and tag for transmission
        let encryptedData = sealedBox.ciphertext + sealedBox.tag

        return EncryptedPasswordPayload(
            encryptedPasswordHash: encryptedData.base64EncodedString(),
            ephemeralPublicKey: ephemeralPublic.rawRepresentation.base64EncodedString(),
            nonce: nonceData.base64EncodedString()
        )
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

    /// Generate a 256-bit random token
    static func generateToken() -> Data {
        return randomBytes(count: 32)
    }

    /// Generate a random salt for password hashing
    static func generateSalt() -> Data {
        return randomBytes(count: 16)
    }
}

// MARK: - Supporting Types

/// Payload for encrypted password hash transmission
struct EncryptedPasswordPayload {
    let encryptedPasswordHash: String  // Base64: ciphertext + tag
    let ephemeralPublicKey: String     // Base64: 32-byte X25519 public key
    let nonce: String                  // Base64: 12-byte nonce
}

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

// MARK: - Errors

enum CryptoError: Error, LocalizedError {
    case invalidPublicKey
    case encryptionFailed
    case decryptionFailed
    case hashingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "Invalid public key format"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        case .hashingFailed:
            return "Password hashing failed"
        }
    }
}
