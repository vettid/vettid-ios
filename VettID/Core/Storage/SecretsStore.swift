import Foundation
import Security
import CryptoKit

/// Secure storage for user secrets with encryption
final class SecretsStore {

    private let service = "com.vettid.secrets"
    private let metadataService = "com.vettid.secrets.metadata"
    private let passwordHashService = "com.vettid.secrets.passwordhash"

    // Salt for password-based key derivation (consistent across app)
    private let keySalt = "VettID-Secrets-Salt-v1".data(using: .utf8)!

    // MARK: - Password Hash Management

    /// Store the password hash for secret verification
    func storePasswordHash(_ hash: Data, salt: Data) throws {
        let payload = PasswordHashPayload(hash: hash, salt: salt)
        let data = try JSONEncoder().encode(payload)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordHashService,
            kSecAttrAccount as String: "password_hash",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretsStoreError.saveFailed(status)
        }
    }

    /// Retrieve stored password hash and salt
    func retrievePasswordHash() throws -> (hash: Data, salt: Data)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordHashService,
            kSecAttrAccount as String: "password_hash",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw SecretsStoreError.retrieveFailed(status)
        }

        let payload = try JSONDecoder().decode(PasswordHashPayload.self, from: data)
        return (payload.hash, payload.salt)
    }

    /// Verify password against stored hash
    func verifyPassword(_ password: String) async -> Bool {
        guard let stored = try? retrievePasswordHash() else {
            return false
        }

        do {
            // Verify using PasswordHasher
            return try PasswordHasher.verify(password: password, hash: stored.hash, salt: stored.salt)
        } catch {
            return false
        }
    }

    // MARK: - Secret Encryption/Decryption

    /// Derive encryption key from password
    private func deriveKey(from password: String) -> SymmetricKey {
        let passwordData = password.data(using: .utf8)!

        // Use HKDF to derive a key from the password
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: keySalt,
            info: "secret-encryption".data(using: .utf8)!,
            outputByteCount: 32
        )

        return derivedKey
    }

    /// Encrypt a secret value
    func encryptValue(_ plaintext: String, password: String) throws -> String {
        let key = deriveKey(from: password)
        let plaintextData = plaintext.data(using: .utf8)!

        let sealedBox = try ChaChaPoly.seal(plaintextData, using: key)

        // Combine nonce + ciphertext + tag
        let combined = sealedBox.nonce + sealedBox.ciphertext + sealedBox.tag
        return combined.base64EncodedString()
    }

    /// Decrypt a secret value
    func decryptValue(_ encryptedBase64: String, password: String) throws -> String {
        guard let combined = Data(base64Encoded: encryptedBase64) else {
            throw SecretsStoreError.decodingFailed
        }

        // Extract nonce (12 bytes), ciphertext, tag (16 bytes)
        guard combined.count > 28 else { // 12 + 16 minimum
            throw SecretsStoreError.decodingFailed
        }

        let nonceData = combined.prefix(12)
        let tagData = combined.suffix(16)
        let ciphertextData = combined.dropFirst(12).dropLast(16)

        let key = deriveKey(from: password)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData)

        let plaintextData = try ChaChaPoly.open(sealedBox, using: key)

        guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
            throw SecretsStoreError.decodingFailed
        }

        return plaintext
    }

    // MARK: - Secret Storage

    /// Store a secret securely
    func store(secret: Secret) throws {
        let data = try JSONEncoder().encode(secret)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.id,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretsStoreError.saveFailed(status)
        }
    }

    /// Retrieve a secret by ID
    func retrieve(id: String) throws -> Secret? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw SecretsStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(Secret.self, from: data)
    }

    /// Retrieve all secrets
    func retrieveAll() throws -> [Secret] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return []
            }
            throw SecretsStoreError.retrieveFailed(status)
        }

        guard let items = result as? [[String: Any]] else {
            return []
        }

        var secrets: [Secret] = []
        for item in items {
            if let data = item[kSecValueData as String] as? Data {
                if let secret = try? JSONDecoder().decode(Secret.self, from: data) {
                    secrets.append(secret)
                }
            }
        }

        return secrets.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Delete a secret
    func delete(id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsStoreError.deleteFailed(status)
        }
    }

    /// Delete all secrets
    func deleteAll() throws {
        let secretsQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        var status = SecItemDelete(secretsQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsStoreError.deleteFailed(status)
        }

        // Also delete password hash
        let hashQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordHashService
        ]

        status = SecItemDelete(hashQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsStoreError.deleteFailed(status)
        }
    }

    /// Check if secrets exist
    func hasSecrets() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Check if password hash is set up
    func hasPasswordHash() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordHashService,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

// MARK: - Supporting Types

private struct PasswordHashPayload: Codable {
    let hash: Data
    let salt: Data
}

// MARK: - Errors

enum SecretsStoreError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case decodingFailed
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save secret: \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve secret: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete secret: \(status)"
        case .encodingFailed:
            return "Failed to encode secret"
        case .decodingFailed:
            return "Failed to decode secret"
        case .encryptionFailed:
            return "Failed to encrypt secret"
        case .decryptionFailed:
            return "Failed to decrypt secret"
        }
    }
}
