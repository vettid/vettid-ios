import Foundation
import Security

/// Secure storage for Protean Credentials using iOS Keychain
final class CredentialStore {

    private let service = "com.vettid.credentials"

    // MARK: - Credential Storage

    /// Store a credential securely in the Keychain
    func store(credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.credentialId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete existing item if present
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.saveFailed(status)
        }
    }

    /// Retrieve a credential from the Keychain
    func retrieve(credentialId: String) throws -> StoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw CredentialStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(StoredCredential.self, from: data)
    }

    /// Check if any credential is stored
    func hasStoredCredential() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Delete a credential from the Keychain
    func delete(credentialId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.deleteFailed(status)
        }
    }

    /// List all stored credential IDs
    func listCredentialIds() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return []
            }
            throw CredentialStoreError.retrieveFailed(status)
        }

        guard let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

// MARK: - Supporting Types

struct StoredCredential: Codable {
    let credentialId: String
    let vaultId: String
    let cekPrivateKey: Data       // X25519 private key (32 bytes)
    let cekPublicKey: Data        // X25519 public key (32 bytes)
    let signingPrivateKey: Data   // Ed25519 private key (32 bytes)
    let signingPublicKey: Data    // Ed25519 public key (32 bytes)
    let latCurrent: Data          // Current LAT token (32 bytes)
    let transactionKeys: [TransactionKey]
    let createdAt: Date
    let lastUsedAt: Date
}

struct TransactionKey: Codable {
    let keyId: String
    let privateKey: Data  // X25519 private key
    let publicKey: Data   // X25519 public key
    let isUsed: Bool
}

enum CredentialStoreError: Error {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case decodingFailed
}
