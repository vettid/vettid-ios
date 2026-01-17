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
        // Salt must match across all platforms (iOS, Android, Lambda) for interoperability
        let hkdfSalt = "VettID-HKDF-Salt-v1".data(using: .utf8)!
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: "transaction-encryption-v1".data(using: .utf8)!,
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

    /// Encrypt data to a raw X25519 public key (convenience method)
    /// Used for encrypting PIN to enclave's attestation-bound public key
    /// - Parameters:
    ///   - plaintext: Data to encrypt
    ///   - publicKey: Raw X25519 public key bytes (32 bytes)
    ///   - additionalData: Optional additional authenticated data (e.g., nonce for replay protection)
    /// - Returns: Encrypted payload containing ephemeral public key and ciphertext
    static func encryptToPublicKey(
        plaintext: Data,
        publicKey: Data,
        additionalData: Data? = nil
    ) throws -> EncryptedPayload {
        let recipientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        return try encrypt(plaintext: plaintext, recipientPublicKey: recipientPublicKey, additionalData: additionalData)
    }

    /// Encrypt data using X25519 key exchange + ChaCha20-Poly1305
    /// - Parameters:
    ///   - plaintext: Data to encrypt
    ///   - recipientPublicKey: Recipient's X25519 public key
    ///   - additionalData: Optional additional authenticated data
    /// - Returns: Encrypted payload containing ephemeral public key and ciphertext
    static func encrypt(plaintext: Data,
                        recipientPublicKey: Curve25519.KeyAgreement.PublicKey,
                        additionalData: Data? = nil) throws -> EncryptedPayload {
        // Generate ephemeral key pair
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeralPrivate.publicKey

        // Derive shared secret
        let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: recipientPublicKey)

        // Derive symmetric key using HKDF
        // Salt must match across all platforms (iOS, Android, Lambda) for interoperability
        let hkdfSalt = "VettID-HKDF-Salt-v1".data(using: .utf8)!
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: "credential-encryption-v1".data(using: .utf8)!,
            outputByteCount: 32
        )

        // Generate explicit random 96-bit nonce for auditability
        let nonceData = randomBytes(count: 12)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)

        // Encrypt with ChaCha20-Poly1305
        let sealedBox = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: nonce)

        return EncryptedPayload(
            ephemeralPublicKey: ephemeralPublic.rawRepresentation,
            nonce: nonceData,
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
        // Salt must match across all platforms (iOS, Android, Lambda) for interoperability
        let hkdfSalt = "VettID-HKDF-Salt-v1".data(using: .utf8)!
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
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

    // MARK: - Voting Key Derivation

    /// Derive a voting keypair from identity key and proposal ID
    /// This creates an unlinkable voting key that can only be derived by the user
    ///
    /// The derivation ensures:
    /// - Different voting key for each proposal (unlinkable across proposals)
    /// - Only the user can derive their voting key (knows identity private key)
    /// - Deterministic: same identity + proposal = same voting key
    ///
    /// - Parameters:
    ///   - identityPrivateKey: User's Ed25519 identity private key (32 bytes)
    ///   - proposalId: The proposal ID (used as salt)
    /// - Returns: Ed25519 signing keypair for this proposal
    static func deriveVotingKeyPair(
        identityPrivateKey: Data,
        proposalId: String
    ) throws -> (privateKey: Curve25519.Signing.PrivateKey, publicKey: Curve25519.Signing.PublicKey) {
        // Use HKDF to derive 32 bytes of key material
        let salt = proposalId.data(using: .utf8)!
        let info = "vettid-vote-v1".data(using: .utf8)!

        // Create a symmetric key from the identity private key for HKDF
        let inputKey = SymmetricKey(data: identityPrivateKey)

        // Derive key material using HKDF
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )

        // Convert to Ed25519 private key
        let keyData = derivedKey.withUnsafeBytes { Data($0) }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)

        return (privateKey, privateKey.publicKey)
    }

    /// Derive voting public key for finding user's vote in published list
    /// - Parameters:
    ///   - identityPrivateKey: User's Ed25519 identity private key
    ///   - proposalId: The proposal ID
    /// - Returns: Base64-encoded voting public key
    static func deriveVotingPublicKey(
        identityPrivateKey: Data,
        proposalId: String
    ) throws -> String {
        let (_, publicKey) = try deriveVotingKeyPair(
            identityPrivateKey: identityPrivateKey,
            proposalId: proposalId
        )
        return publicKey.rawRepresentation.base64EncodedString()
    }

    // MARK: - Merkle Tree Verification

    /// Verify a Merkle proof for a vote
    /// - Parameters:
    ///   - voteHash: The hash of the vote being verified
    ///   - proof: Array of sibling hashes in the proof path
    ///   - root: The expected Merkle root
    ///   - index: The index of the vote in the tree
    /// - Returns: True if the proof is valid
    static func verifyMerkleProof(
        voteHash: String,
        proof: [String],
        root: String,
        index: Int
    ) -> Bool {
        guard let voteHashData = Data(base64Encoded: voteHash) else {
            return false
        }

        var currentHash = voteHashData
        var currentIndex = index

        for siblingHashBase64 in proof {
            guard let siblingHash = Data(base64Encoded: siblingHashBase64) else {
                return false
            }

            // Determine order based on index (even = left, odd = right)
            let combined: Data
            if currentIndex % 2 == 0 {
                combined = currentHash + siblingHash
            } else {
                combined = siblingHash + currentHash
            }

            // Hash the combined data
            currentHash = Data(SHA256.hash(data: combined))
            currentIndex /= 2
        }

        // Compare with expected root
        guard let expectedRoot = Data(base64Encoded: root) else {
            return false
        }

        return currentHash == expectedRoot
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
