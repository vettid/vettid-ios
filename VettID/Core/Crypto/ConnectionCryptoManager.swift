import Foundation
import CryptoKit
import Security

/// Manages cryptographic operations for connections
/// - X25519 key exchange
/// - HKDF key derivation
/// - XChaCha20-Poly1305 message encryption (using ChaCha20-Poly1305 with extended nonce)
final class ConnectionCryptoManager {

    // MARK: - Types

    enum CryptoError: Error, LocalizedError {
        case keyGenerationFailed
        case keyDerivationFailed
        case encryptionFailed
        case decryptionFailed
        case invalidPublicKey
        case invalidNonce
        case keychainError(OSStatus)
        case keyNotFound

        var errorDescription: String? {
            switch self {
            case .keyGenerationFailed:
                return "Failed to generate key pair"
            case .keyDerivationFailed:
                return "Failed to derive shared secret"
            case .encryptionFailed:
                return "Failed to encrypt message"
            case .decryptionFailed:
                return "Failed to decrypt message"
            case .invalidPublicKey:
                return "Invalid public key format"
            case .invalidNonce:
                return "Invalid nonce format"
            case .keychainError(let status):
                return "Keychain error: \(status)"
            case .keyNotFound:
                return "Connection key not found"
            }
        }
    }

    struct EncryptedMessage {
        let ciphertext: Data
        let nonce: Data
    }

    // MARK: - Constants

    private let keychainService = "com.vettid.connectionKeys"
    private let nonceSize = 24  // XChaCha20 uses 24-byte nonce
    private let keySize = 32    // 256-bit keys

    // MARK: - Initialization

    init() {}

    // MARK: - Key Generation

    /// Generate X25519 key pair for new connection
    func generateConnectionKeyPair() throws -> (publicKey: Data, privateKey: Data) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey

        return (
            publicKey: publicKey.rawRepresentation,
            privateKey: privateKey.rawRepresentation
        )
    }

    // MARK: - Key Exchange

    /// Derive shared secret from X25519 key exchange
    func deriveSharedSecret(
        privateKey: Data,
        peerPublicKey: Data
    ) throws -> Data {
        guard let privateKeyObj = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            throw CryptoError.keyGenerationFailed
        }

        guard let peerPublicKeyObj = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) else {
            throw CryptoError.invalidPublicKey
        }

        do {
            let sharedSecret = try privateKeyObj.sharedSecretFromKeyAgreement(with: peerPublicKeyObj)
            return sharedSecret.withUnsafeBytes { Data($0) }
        } catch {
            throw CryptoError.keyDerivationFailed
        }
    }

    /// Derive per-connection encryption key using HKDF
    func deriveConnectionKey(
        sharedSecret: Data,
        connectionId: String
    ) throws -> Data {
        let salt = Data(connectionId.utf8)
        let info = Data("VettID-Connection-Key".utf8)

        // Use HKDF to derive the connection key
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: info,
            outputByteCount: keySize
        )

        return derivedKey.withUnsafeBytes { Data($0) }
    }

    // MARK: - Message Encryption

    /// Encrypt message with ChaCha20-Poly1305
    /// Note: Uses extended nonce approach for XChaCha20-like behavior
    func encryptMessage(
        plaintext: String,
        connectionKey: Data
    ) throws -> EncryptedMessage {
        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw CryptoError.encryptionFailed
        }

        // Generate random nonce (24 bytes for XChaCha20-style)
        var nonce = Data(count: nonceSize)
        let result = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, nonceSize, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw CryptoError.encryptionFailed
        }

        // For CryptoKit's ChaCha20-Poly1305, we use 12 bytes of the nonce
        // and prepend the remaining 12 bytes to derive a subkey (XChaCha20 approach)
        let (subkey, shortNonce) = try deriveSubkeyAndNonce(from: connectionKey, nonce: nonce)

        do {
            let symmetricKey = SymmetricKey(data: subkey)
            let chaChaNonce = try ChaChaPoly.Nonce(data: shortNonce)
            let sealedBox = try ChaChaPoly.seal(plaintextData, using: symmetricKey, nonce: chaChaNonce)

            return EncryptedMessage(
                ciphertext: sealedBox.ciphertext + sealedBox.tag,
                nonce: nonce
            )
        } catch {
            throw CryptoError.encryptionFailed
        }
    }

    /// Decrypt message with ChaCha20-Poly1305
    func decryptMessage(
        ciphertext: Data,
        nonce: Data,
        connectionKey: Data
    ) throws -> String {
        guard nonce.count == nonceSize else {
            throw CryptoError.invalidNonce
        }

        // Split ciphertext and tag (tag is last 16 bytes)
        guard ciphertext.count >= 16 else {
            throw CryptoError.decryptionFailed
        }

        let tagSize = 16
        let actualCiphertext = ciphertext.prefix(ciphertext.count - tagSize)
        let tag = ciphertext.suffix(tagSize)

        // Derive subkey and short nonce from extended nonce
        let (subkey, shortNonce) = try deriveSubkeyAndNonce(from: connectionKey, nonce: nonce)

        do {
            let symmetricKey = SymmetricKey(data: subkey)
            let chaChaNonce = try ChaChaPoly.Nonce(data: shortNonce)
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: chaChaNonce,
                ciphertext: actualCiphertext,
                tag: tag
            )
            let decryptedData = try ChaChaPoly.open(sealedBox, using: symmetricKey)

            guard let plaintext = String(data: decryptedData, encoding: .utf8) else {
                throw CryptoError.decryptionFailed
            }

            return plaintext
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    /// Derive subkey and short nonce for XChaCha20-like operation
    private func deriveSubkeyAndNonce(from key: Data, nonce: Data) throws -> (subkey: Data, shortNonce: Data) {
        // Use first 16 bytes of nonce to derive subkey via HKDF
        let subkeyInput = nonce.prefix(16)
        let subkey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: subkeyInput,
            info: Data("VettID-XChaCha".utf8),
            outputByteCount: keySize
        )

        // Use last 12 bytes of nonce (or pad if needed)
        var shortNonce = Data(count: 12)
        if nonce.count >= 24 {
            shortNonce = nonce.suffix(12)
        } else {
            // Shouldn't happen with our 24-byte nonces, but handle gracefully
            let startIndex = max(0, nonce.count - 12)
            shortNonce = nonce.suffix(from: nonce.index(nonce.startIndex, offsetBy: startIndex))
            if shortNonce.count < 12 {
                shortNonce = Data(repeating: 0, count: 12 - shortNonce.count) + shortNonce
            }
        }

        return (subkey.withUnsafeBytes { Data($0) }, shortNonce)
    }

    // MARK: - Keychain Storage

    /// Store connection key securely in Keychain
    func storeConnectionKey(connectionId: String, key: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: connectionId,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            // Security: Prevent synchronization to iCloud Keychain
            kSecAttrSynchronizable as String: false
        ]

        // Delete any existing key first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptoError.keychainError(status)
        }
    }

    /// Retrieve connection key from Keychain
    func getConnectionKey(connectionId: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: connectionId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw CryptoError.keychainError(status)
        }

        return result as? Data
    }

    /// Delete connection key from Keychain
    func deleteConnectionKey(connectionId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: connectionId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoError.keychainError(status)
        }
    }

    // MARK: - Convenience Methods

    /// Encrypt a message for a connection, retrieving the key from Keychain
    func encryptForConnection(
        plaintext: String,
        connectionId: String
    ) throws -> EncryptedMessage {
        guard let key = try getConnectionKey(connectionId: connectionId) else {
            throw CryptoError.keyNotFound
        }
        return try encryptMessage(plaintext: plaintext, connectionKey: key)
    }

    /// Decrypt a message from a connection, retrieving the key from Keychain
    func decryptFromConnection(
        ciphertext: Data,
        nonce: Data,
        connectionId: String
    ) throws -> String {
        guard let key = try getConnectionKey(connectionId: connectionId) else {
            throw CryptoError.keyNotFound
        }
        return try decryptMessage(ciphertext: ciphertext, nonce: nonce, connectionKey: key)
    }
}
