import Foundation
import Security
import LocalAuthentication

/// Secure storage for VettID Credentials using iOS Keychain
///
/// New key ownership model:
/// - Ledger owns: CEK (private), LTK (private)
/// - Mobile stores: encrypted blob, UTK pool (public keys only), LAT
///
/// Security features:
/// - Keychain storage with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// - Optional biometric protection for sensitive operations
/// - No iCloud sync (device-only storage)
final class CredentialStore {

    private let service = "com.vettid.credentials"

    /// Service name for biometric-protected credentials
    private let biometricService = "com.vettid.credentials.biometric"

    // MARK: - Biometric Access Control

    /// Create access control flags for biometric-protected storage
    private func createBiometricAccessControl() -> SecAccessControl? {
        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet, .or, .devicePasscode],  // Biometric or passcode fallback
            &error
        )
        if let error = error {
            print("[CredentialStore] Failed to create biometric access control: \(error.takeRetainedValue())")
            return nil
        }
        return access
    }

    // MARK: - Credential Storage

    /// Store a credential securely in the Keychain
    /// - Parameters:
    ///   - credential: The credential to store
    ///   - requireBiometric: If true, retrieval will require biometric/passcode authentication
    func store(credential: StoredCredential, requireBiometric: Bool = false) throws {
        let data = try JSONEncoder().encode(credential)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: requireBiometric ? biometricService : service,
            kSecAttrAccount as String: credential.userGuid,
            kSecValueData as String: data,
            // Security: Prevent synchronization to iCloud Keychain
            kSecAttrSynchronizable as String: false
        ]

        // Add biometric access control if requested
        if requireBiometric, let accessControl = createBiometricAccessControl() {
            query[kSecAttrAccessControl as String] = accessControl
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        // Delete existing item if present (from both services)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.userGuid
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let deleteBiometricQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: credential.userGuid
        ]
        SecItemDelete(deleteBiometricQuery as CFDictionary)

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
    /// - Parameters:
    ///   - userGuid: The user GUID to retrieve
    ///   - authenticationPrompt: Prompt shown for biometric authentication (if credential requires it)
    func retrieve(userGuid: String, authenticationPrompt: String = "Authenticate to access your credentials") throws -> StoredCredential? {
        // Try biometric-protected service first
        let biometricQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: userGuid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: authenticationPrompt
        ]

        var result: AnyObject?
        var status = SecItemCopyMatching(biometricQuery as CFDictionary, &result)

        // If found in biometric service, return it (will trigger biometric prompt)
        if status == errSecSuccess, let data = result as? Data {
            return try JSONDecoder().decode(StoredCredential.self, from: data)
        }

        // Fall back to non-biometric service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userGuid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        result = nil
        status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw CredentialStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(StoredCredential.self, from: data)
    }

    /// Retrieve the first stored credential (for single-credential scenarios)
    /// - Parameter authenticationPrompt: Prompt shown for biometric authentication (if credential requires it)
    func retrieveFirst(authenticationPrompt: String = "Authenticate to access your credentials") throws -> StoredCredential? {
        // Try biometric-protected service first
        let biometricQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: authenticationPrompt
        ]

        var result: AnyObject?
        var status = SecItemCopyMatching(biometricQuery as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            return try JSONDecoder().decode(StoredCredential.self, from: data)
        }

        // Fall back to non-biometric service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        result = nil
        status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw CredentialStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(StoredCredential.self, from: data)
    }

    /// Check if any credential is stored (does not require authentication)
    func hasStoredCredential() -> Bool {
        // Check non-biometric service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return true
        }

        // Check biometric service
        let biometricQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        return SecItemCopyMatching(biometricQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Delete a credential from the Keychain (from both biometric and non-biometric storage)
    func delete(userGuid: String) throws {
        // Delete from non-biometric service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userGuid
        ]
        let status1 = SecItemDelete(query as CFDictionary)

        // Delete from biometric service
        let biometricQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService,
            kSecAttrAccount as String: userGuid
        ]
        let status2 = SecItemDelete(biometricQuery as CFDictionary)

        // Consider success if deleted from either or not found
        let success1 = status1 == errSecSuccess || status1 == errSecItemNotFound
        let success2 = status2 == errSecSuccess || status2 == errSecItemNotFound

        guard success1 && success2 else {
            throw CredentialStoreError.deleteFailed(success1 ? status2 : status1)
        }
    }

    /// Delete all credentials from the Keychain (from both biometric and non-biometric storage)
    func deleteAll() throws {
        // Delete from non-biometric service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status1 = SecItemDelete(query as CFDictionary)

        // Delete from biometric service
        let biometricQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricService
        ]
        let status2 = SecItemDelete(biometricQuery as CFDictionary)

        let success1 = status1 == errSecSuccess || status1 == errSecItemNotFound
        let success2 = status2 == errSecSuccess || status2 == errSecItemNotFound

        guard success1 && success2 else {
            throw CredentialStoreError.deleteFailed(success1 ? status2 : status1)
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

/// Credential stored locally on the device (Nitro Enclave format)
/// Note: Mobile does NOT store private keys - only sealed credential and UTK public keys
struct StoredCredential: Codable {
    let userGuid: String
    let sealedCredential: String      // Base64 enclave-sealed blob
    let enclavePublicKey: String      // Identity public key from enclave
    let backupKey: String             // For backup encryption
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
            sealedCredential: sealedCredential,
            enclavePublicKey: enclavePublicKey,
            backupKey: backupKey,
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
            sealedCredential: package.sealedCredential,
            enclavePublicKey: package.enclavePublicKey,
            backupKey: package.backupKey,
            ledgerAuthToken: StoredLAT(
                latId: package.ledgerAuthToken.latId ?? package.ledgerAuthToken.token,
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
    let token: String     // Hex encoded 256-bit token or lat_xxx format
    let version: Int

    /// Verify the LAT matches what the server sent
    func matches(_ serverLAT: LedgerAuthToken) -> Bool {
        let serverLatId = serverLAT.latId ?? serverLAT.token
        return latId == serverLatId &&
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
