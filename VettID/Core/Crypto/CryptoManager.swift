import Foundation
import CryptoKit

#if canImport(Sodium)
import Sodium
#endif

// MARK: - Crypto Domain for HKDF

/// Domain separation for HKDF key derivation
/// Ensures keys derived for different purposes are cryptographically independent
///
/// Note: CEK domain (vettid-cek-v1) is vault-side only - app never encrypts credentials
enum CryptoDomain: String {
    case utk = "vettid-utk-v1"           // For encrypting payloads to vault (transaction keys)
    case pin = "vettid-pin-v1"           // For PIN encryption to enclave
    case session = "app-vault-session-v1" // For app-vault session encryption

    var saltData: Data {
        self.rawValue.data(using: .utf8)!
    }
}

/// Manages all cryptographic operations for VettID
/// Uses X25519 for key exchange and XChaCha20-Poly1305 for authenticated encryption
final class CryptoManager {

    #if canImport(Sodium)
    private static let sodium = Sodium()
    #endif

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

    /// Encrypt a password hash using a UTK public key with XChaCha20-Poly1305
    /// This is used during enrollment and authentication to securely send the password hash to the server
    ///
    /// Flow:
    /// 1. Generate ephemeral X25519 keypair
    /// 2. Compute shared secret with UTK public key
    /// 3. Derive encryption key using HKDF with domain separation
    /// 4. Encrypt password hash with XChaCha20-Poly1305 (24-byte nonce)
    ///
    /// Output format: ephemeral_pubkey (32) || nonce (24) || ciphertext
    ///
    /// - Parameters:
    ///   - passwordHash: The Argon2id hash of the password (or PHC string)
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

        // Derive symmetric key using HKDF with domain separation
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: CryptoDomain.utk.saltData,
            sharedInfo: Data(),  // Empty info, domain is in salt
            outputByteCount: 32
        )

        // Encrypt with XChaCha20-Poly1305 (generates 24-byte nonce internally)
        let (encryptedData, nonceData) = try encryptXChaCha20Poly1305(
            plaintext: passwordHash,
            key: symmetricKey
        )

        return EncryptedPasswordPayload(
            encryptedPasswordHash: encryptedData.base64EncodedString(),
            ephemeralPublicKey: ephemeralPublic.rawRepresentation.base64EncodedString(),
            nonce: nonceData.base64EncodedString()
        )
    }

    // MARK: - XChaCha20-Poly1305

    /// Encrypt data using XChaCha20-Poly1305 (24-byte nonce)
    /// Returns both the ciphertext and the nonce used
    /// Falls back to ChaCha20-Poly1305 with derived subkey when Sodium unavailable
    static func encryptXChaCha20Poly1305(
        plaintext: Data,
        key: SymmetricKey
    ) throws -> (ciphertext: Data, nonce: Data) {
        #if canImport(Sodium)
        // Use libsodium's XChaCha20-Poly1305 - it generates the nonce
        let keyData = key.withUnsafeBytes { Data($0) }
        // Use the tuple-returning overload explicitly to avoid ambiguity
        guard let result: (authenticatedCipherText: [UInt8], nonce: [UInt8]) = sodium.aead.xchacha20poly1305ietf.encrypt(
            message: Array(plaintext),
            secretKey: Array(keyData),
            additionalData: nil
        ) else {
            throw CryptoError.encryptionFailed
        }
        return (Data(result.authenticatedCipherText), Data(result.nonce))
        #else
        // Fallback: Generate 24-byte nonce, use HChaCha20 to derive subkey, then ChaCha20-Poly1305
        let nonce = randomBytes(count: 24)
        let keyData = key.withUnsafeBytes { Data($0) }
        let subkey = try hChaCha20(key: keyData, nonce: Data(nonce.prefix(16)))
        let subNonce = Data(repeating: 0, count: 4) + nonce.suffix(8)  // 4 zeros + last 8 bytes

        let symmetricSubkey = SymmetricKey(data: subkey)
        let chachaNonce = try ChaChaPoly.Nonce(data: subNonce)
        let sealedBox = try ChaChaPoly.seal(plaintext, using: symmetricSubkey, nonce: chachaNonce)

        return (sealedBox.ciphertext + sealedBox.tag, nonce)
        #endif
    }

    /// Decrypt data using XChaCha20-Poly1305 (24-byte nonce)
    static func decryptXChaCha20Poly1305(
        ciphertext: Data,
        key: SymmetricKey,
        nonce: Data
    ) throws -> Data {
        guard nonce.count == 24 else {
            throw CryptoError.invalidNonce
        }

        #if canImport(Sodium)
        let keyData = key.withUnsafeBytes { Data($0) }
        guard let plaintext = sodium.aead.xchacha20poly1305ietf.decrypt(
            authenticatedCipherText: Array(ciphertext),
            secretKey: Array(keyData),
            nonce: Array(nonce),
            additionalData: nil
        ) else {
            throw CryptoError.decryptionFailed
        }
        return Data(plaintext)
        #else
        // Fallback: HChaCha20 subkey derivation
        let keyData = key.withUnsafeBytes { Data($0) }
        let subkey = try hChaCha20(key: keyData, nonce: Data(nonce.prefix(16)))
        let subNonce = Data(repeating: 0, count: 4) + nonce.suffix(8)

        let symmetricSubkey = SymmetricKey(data: subkey)
        let chachaNonce = try ChaChaPoly.Nonce(data: subNonce)

        // Separate ciphertext and tag (last 16 bytes)
        guard ciphertext.count >= 16 else {
            throw CryptoError.decryptionFailed
        }
        let tagStart = ciphertext.count - 16
        let ciphertextOnly = ciphertext.prefix(tagStart)
        let tag = ciphertext.suffix(16)

        let sealedBox = try ChaChaPoly.SealedBox(nonce: chachaNonce, ciphertext: ciphertextOnly, tag: tag)
        return try ChaChaPoly.open(sealedBox, using: symmetricSubkey)
        #endif
    }

    #if !canImport(Sodium)
    /// HChaCha20 core function for XChaCha20 construction
    /// Derives a 32-byte subkey from a 32-byte key and 16-byte nonce
    private static func hChaCha20(key: Data, nonce: Data) throws -> Data {
        guard key.count == 32, nonce.count == 16 else {
            throw CryptoError.encryptionFailed
        }

        // HChaCha20 constants (same as ChaCha20)
        var state: [UInt32] = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574  // "expand 32-byte k"
        ]

        // Add key (words 4-11)
        for i in 0..<8 {
            let offset = i * 4
            state.append(UInt32(key[offset]) | UInt32(key[offset+1]) << 8 |
                        UInt32(key[offset+2]) << 16 | UInt32(key[offset+3]) << 24)
        }

        // Add nonce (words 12-15)
        for i in 0..<4 {
            let offset = i * 4
            state.append(UInt32(nonce[offset]) | UInt32(nonce[offset+1]) << 8 |
                        UInt32(nonce[offset+2]) << 16 | UInt32(nonce[offset+3]) << 24)
        }

        // 20 rounds (10 double rounds)
        for _ in 0..<10 {
            // Column rounds
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            // Diagonal rounds
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }

        // Output: words 0-3 and 12-15 form the 32-byte subkey
        var subkey = Data(count: 32)
        for i in 0..<4 {
            let word = state[i]
            subkey[i*4] = UInt8(word & 0xFF)
            subkey[i*4+1] = UInt8((word >> 8) & 0xFF)
            subkey[i*4+2] = UInt8((word >> 16) & 0xFF)
            subkey[i*4+3] = UInt8((word >> 24) & 0xFF)
        }
        for i in 0..<4 {
            let word = state[12 + i]
            subkey[16 + i*4] = UInt8(word & 0xFF)
            subkey[16 + i*4+1] = UInt8((word >> 8) & 0xFF)
            subkey[16 + i*4+2] = UInt8((word >> 16) & 0xFF)
            subkey[16 + i*4+3] = UInt8((word >> 24) & 0xFF)
        }

        return subkey
    }

    /// ChaCha20 quarter round
    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = rotl(state[d], 16)
        state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = rotl(state[b], 12)
        state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = rotl(state[d], 8)
        state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = rotl(state[b], 7)
    }

    /// Left rotate
    private static func rotl(_ x: UInt32, _ n: Int) -> UInt32 {
        return (x << n) | (x >> (32 - n))
    }
    #endif

    // MARK: - Hybrid Encryption (X25519 + XChaCha20-Poly1305)

    /// Encrypt data to a raw X25519 public key (convenience method)
    /// Used for encrypting PIN to enclave's attestation-bound public key
    /// - Parameters:
    ///   - plaintext: Data to encrypt
    ///   - publicKey: Raw X25519 public key bytes (32 bytes)
    ///   - additionalData: Optional additional authenticated data (e.g., nonce for replay protection)
    ///   - domain: Crypto domain for HKDF key derivation (default: .pin for enclave encryption)
    /// - Returns: Encrypted payload containing ephemeral public key and ciphertext
    static func encryptToPublicKey(
        plaintext: Data,
        publicKey: Data,
        additionalData: Data? = nil,
        domain: CryptoDomain = .pin
    ) throws -> EncryptedPayload {
        let recipientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        return try encrypt(plaintext: plaintext, recipientPublicKey: recipientPublicKey, additionalData: additionalData, domain: domain)
    }

    /// Encrypt data using X25519 key exchange + XChaCha20-Poly1305 (24-byte nonce)
    /// Output format: ephemeral_pubkey (32) || nonce (24) || ciphertext+tag
    /// - Parameters:
    ///   - plaintext: Data to encrypt
    ///   - recipientPublicKey: Recipient's X25519 public key
    ///   - additionalData: Optional additional authenticated data
    ///   - domain: Crypto domain for HKDF key derivation (default: .utk for vault encryption)
    /// - Returns: Encrypted payload containing ephemeral public key and ciphertext
    static func encrypt(plaintext: Data,
                        recipientPublicKey: Curve25519.KeyAgreement.PublicKey,
                        additionalData: Data? = nil,
                        domain: CryptoDomain = .utk) throws -> EncryptedPayload {
        // Generate ephemeral key pair
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeralPrivate.publicKey

        // Derive shared secret
        let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: recipientPublicKey)

        // Derive symmetric key using HKDF with domain separation
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: domain.saltData,
            sharedInfo: Data(),  // Empty info, domain is in salt
            outputByteCount: 32
        )

        // Encrypt with XChaCha20-Poly1305 (generates 24-byte nonce internally)
        let (ciphertextWithTag, nonceData) = try encryptXChaCha20Poly1305(
            plaintext: plaintext,
            key: symmetricKey
        )

        // Separate ciphertext and tag for the payload struct
        // XChaCha20-Poly1305 tag is always 16 bytes
        let tagStart = ciphertextWithTag.count - 16
        let ciphertext = ciphertextWithTag.prefix(tagStart)
        let tag = ciphertextWithTag.suffix(16)

        return EncryptedPayload(
            ephemeralPublicKey: ephemeralPublic.rawRepresentation,
            nonce: nonceData,
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
    }

    /// Decrypt data using X25519 key exchange + XChaCha20-Poly1305
    static func decrypt(payload: EncryptedPayload,
                        privateKey: Curve25519.KeyAgreement.PrivateKey,
                        domain: CryptoDomain = .utk) throws -> Data {
        // Reconstruct ephemeral public key
        let ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: payload.ephemeralPublicKey
        )

        // Derive shared secret
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)

        // Derive symmetric key with domain separation
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: domain.saltData,
            sharedInfo: Data(),
            outputByteCount: 32
        )

        // Combine ciphertext and tag for decryption
        let ciphertextWithTag = payload.ciphertext + payload.tag

        // Decrypt with XChaCha20-Poly1305
        return try decryptXChaCha20Poly1305(
            ciphertext: ciphertextWithTag,
            key: symmetricKey,
            nonce: payload.nonce
        )
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
    let nonce: String                  // Base64: 24-byte nonce (XChaCha20-Poly1305)
}

struct EncryptedPayload: Codable {
    let ephemeralPublicKey: Data  // 32 bytes
    let nonce: Data               // 24 bytes (XChaCha20-Poly1305)
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
    case invalidNonce
    case encryptionFailed
    case decryptionFailed
    case hashingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "Invalid public key format"
        case .invalidNonce:
            return "Invalid nonce size"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        case .hashingFailed:
            return "Password hashing failed"
        }
    }
}
