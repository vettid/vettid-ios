import Foundation
import Security

/// Secure storage for VettID Credentials using iOS Keychain
///
/// New key ownership model:
/// - Ledger owns: CEK (private), LTK (private)
/// - Mobile stores: encrypted blob, UTK pool (public keys only), LAT
final class CredentialStore {

    private let service = "com.vettid.credentials"

    // MARK: - Credential Storage

    /// Store a credential securely in the Keychain
    func store(credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.userGuid,
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

    /// Update an existing credential in the Keychain
    func update(credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.userGuid
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            // If not found, try to add instead
            if status == errSecItemNotFound {
                try store(credential: credential)
                return
            }
            throw CredentialStoreError.saveFailed(status)
        }
    }

    /// Retrieve a credential from the Keychain by user GUID
    func retrieve(userGuid: String) throws -> StoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userGuid,
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

    /// Retrieve the first stored credential (for single-credential scenarios)
    func retrieveFirst() throws -> StoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
    func delete(userGuid: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userGuid
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.deleteFailed(status)
        }
    }

    /// List all stored user GUIDs
    func listUserGuids() throws -> [String] {
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

    // MARK: - Credential Blob Backup/Restore

    /// Retrieve all credentials as a serialized blob for backup
    func retrieveCredentialBlob() -> Data? {
        do {
            let userGuids = try listUserGuids()
            var credentials: [StoredCredential] = []

            for guid in userGuids {
                if let credential = try retrieve(userGuid: guid) {
                    credentials.append(credential)
                }
            }

            guard !credentials.isEmpty else { return nil }
            return try JSONEncoder().encode(credentials)
        } catch {
            return nil
        }
    }

    /// Store credentials from a serialized backup blob
    func storeCredentialBlob(_ data: Data) throws {
        let credentials = try JSONDecoder().decode([StoredCredential].self, from: data)

        for credential in credentials {
            try store(credential: credential)
        }
    }
}

// MARK: - Stored Credential Model

/// Credential stored locally on the device
/// Note: Mobile does NOT store private keys - only encrypted blob and UTK public keys
struct StoredCredential: Codable {
    let userGuid: String
    let encryptedBlob: String         // Base64 encoded - cannot decrypt locally
    let cekVersion: Int               // Track CEK version for sync
    let ledgerAuthToken: StoredLAT    // For verifying server authenticity
    let transactionKeys: [StoredUTK]  // Pool of User Transaction Keys (public only)
    let createdAt: Date
    var lastUsedAt: Date
    var vaultStatus: String?

    /// Get an unused transaction key
    func getUnusedKey() -> StoredUTK? {
        return transactionKeys.first { !$0.isUsed }
    }

    /// Get a specific transaction key by ID
    func getKey(byId keyId: String) -> StoredUTK? {
        return transactionKeys.first { $0.keyId == keyId }
    }

    /// Count of remaining unused keys
    var unusedKeyCount: Int {
        transactionKeys.filter { !$0.isUsed }.count
    }

    /// Create updated credential with a key marked as used
    func markingKeyUsed(keyId: String) -> StoredCredential {
        let updatedKeys = transactionKeys.map { key in
            if key.keyId == keyId {
                return StoredUTK(keyId: key.keyId, publicKey: key.publicKey, algorithm: key.algorithm, isUsed: true)
            }
            return key
        }

        return StoredCredential(
            userGuid: userGuid,
            encryptedBlob: encryptedBlob,
            cekVersion: cekVersion,
            ledgerAuthToken: ledgerAuthToken,
            transactionKeys: updatedKeys,
            createdAt: createdAt,
            lastUsedAt: Date(),
            vaultStatus: vaultStatus
        )
    }

    /// Create updated credential with new credential package from server
    func updatedWith(package: CredentialPackage, usedKeyId: String) -> StoredCredential {
        // Start with existing keys, mark the used one
        var updatedKeys = transactionKeys.map { key in
            if key.keyId == usedKeyId {
                return StoredUTK(keyId: key.keyId, publicKey: key.publicKey, algorithm: key.algorithm, isUsed: true)
            }
            return key
        }

        // Add any new keys from the server
        if let newKeys = package.newTransactionKeys {
            for keyInfo in newKeys {
                updatedKeys.append(StoredUTK(
                    keyId: keyInfo.keyId,
                    publicKey: keyInfo.publicKey,
                    algorithm: keyInfo.algorithm,
                    isUsed: false
                ))
            }
        }

        return StoredCredential(
            userGuid: userGuid,
            encryptedBlob: package.encryptedBlob,
            cekVersion: package.cekVersion,
            ledgerAuthToken: StoredLAT(
                latId: package.ledgerAuthToken.latId,
                token: package.ledgerAuthToken.token,
                version: package.ledgerAuthToken.version
            ),
            transactionKeys: updatedKeys,
            createdAt: createdAt,
            lastUsedAt: Date(),
            vaultStatus: vaultStatus
        )
    }
}

/// Ledger Auth Token for mutual authentication
struct StoredLAT: Codable {
    let latId: String
    let token: String     // Hex encoded 256-bit token
    let version: Int

    /// Verify the LAT matches what the server sent
    func matches(_ serverLAT: LedgerAuthToken) -> Bool {
        return latId == serverLAT.latId &&
               token == serverLAT.token &&
               version == serverLAT.version
    }
}

/// User Transaction Key - only public key stored locally
struct StoredUTK: Codable {
    let keyId: String
    let publicKey: String   // Base64 encoded X25519 public key
    let algorithm: String   // Should be "X25519"
    var isUsed: Bool

    /// Decode the public key bytes
    func publicKeyData() -> Data? {
        return Data(base64Encoded: publicKey)
    }
}

// MARK: - Errors

enum CredentialStoreError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case decodingFailed
    case noUnusedKeys

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save credential: \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve credential: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete credential: \(status)"
        case .encodingFailed:
            return "Failed to encode credential"
        case .decodingFailed:
            return "Failed to decode credential"
        case .noUnusedKeys:
            return "No unused transaction keys available"
        }
    }
}
