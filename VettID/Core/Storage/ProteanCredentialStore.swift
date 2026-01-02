import Foundation
import Security

// MARK: - Protean Credential Store

/// Secure storage for Protean Credentials from the Nitro Enclave
///
/// The Protean Credential is an encrypted blob containing all user secrets,
/// created inside the Nitro Enclave and encrypted with the user's DEK
/// (derived from PIN/password).
///
/// Security features:
/// - Keychain storage with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// - No iCloud sync (device-only storage)
/// - Automatic versioning for credential updates
final class ProteanCredentialStore {

    // MARK: - Constants

    private let service = "com.vettid.protean-credential"
    private let metadataKey = "protean-credential-metadata"
    private let blobKey = "protean-credential-blob"

    // MARK: - Public API

    /// Store a Protean Credential blob with metadata
    func store(blob: Data, metadata: ProteanCredentialMetadata) throws {
        // Store the blob
        try storeBlob(blob)

        // Store the metadata
        try storeMetadata(metadata)
    }

    /// Retrieve the stored Protean Credential blob
    func retrieveBlob() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: blobKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw ProteanCredentialStoreError.retrieveFailed(status)
        }

        return data
    }

    /// Retrieve the credential metadata
    func retrieveMetadata() throws -> ProteanCredentialMetadata? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadataKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw ProteanCredentialStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(ProteanCredentialMetadata.self, from: data)
    }

    /// Check if a Protean Credential is stored
    func hasCredential() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: blobKey,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Update credential with new version (e.g., after PIN change)
    func updateCredential(blob: Data, newVersion: Int) throws {
        guard var metadata = try retrieveMetadata() else {
            throw ProteanCredentialStoreError.noCredentialStored
        }

        // Increment version
        metadata = ProteanCredentialMetadata(
            version: newVersion,
            createdAt: metadata.createdAt,
            updatedAt: Date(),
            backedUpAt: nil,  // Needs new backup
            sizeBytes: blob.count,
            userGuid: metadata.userGuid
        )

        try store(blob: blob, metadata: metadata)
    }

    /// Mark credential as backed up
    func markAsBackedUp(backupId: String) throws {
        guard var metadata = try retrieveMetadata() else {
            throw ProteanCredentialStoreError.noCredentialStored
        }

        metadata = ProteanCredentialMetadata(
            version: metadata.version,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            backedUpAt: Date(),
            backupId: backupId,
            sizeBytes: metadata.sizeBytes,
            userGuid: metadata.userGuid
        )

        try storeMetadata(metadata)
    }

    /// Delete the stored credential
    func delete() throws {
        // Delete blob
        let blobQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: blobKey
        ]
        let blobStatus = SecItemDelete(blobQuery as CFDictionary)

        // Delete metadata
        let metadataQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadataKey
        ]
        let metadataStatus = SecItemDelete(metadataQuery as CFDictionary)

        let blobSuccess = blobStatus == errSecSuccess || blobStatus == errSecItemNotFound
        let metadataSuccess = metadataStatus == errSecSuccess || metadataStatus == errSecItemNotFound

        guard blobSuccess && metadataSuccess else {
            throw ProteanCredentialStoreError.deleteFailed(blobSuccess ? metadataStatus : blobStatus)
        }
    }

    /// Check if credential needs backup (not backed up or newer than last backup)
    func needsBackup() -> Bool {
        guard let metadata = try? retrieveMetadata() else {
            return false
        }

        // No backup yet
        guard let backedUpAt = metadata.backedUpAt else {
            return true
        }

        // Credential was updated after last backup
        if let updatedAt = metadata.updatedAt, updatedAt > backedUpAt {
            return true
        }

        return false
    }

    // MARK: - Private Helpers

    private func storeBlob(_ blob: Data) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: blobKey,
            kSecValueData as String: blob,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: blobKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProteanCredentialStoreError.saveFailed(status)
        }
    }

    private func storeMetadata(_ metadata: ProteanCredentialMetadata) throws {
        let data = try JSONEncoder().encode(metadata)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadataKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadataKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProteanCredentialStoreError.saveFailed(status)
        }
    }
}

// MARK: - Metadata Model

/// Metadata about a stored Protean Credential
struct ProteanCredentialMetadata: Codable {
    /// Version number (increments on each update)
    let version: Int

    /// When the credential was first created
    let createdAt: Date

    /// When the credential was last updated
    let updatedAt: Date?

    /// When the credential was last backed up to VettID
    let backedUpAt: Date?

    /// Backup ID from the server (if backed up)
    var backupId: String?

    /// Size of the encrypted blob in bytes
    let sizeBytes: Int

    /// User GUID associated with this credential
    let userGuid: String

    init(
        version: Int,
        createdAt: Date,
        updatedAt: Date? = nil,
        backedUpAt: Date? = nil,
        backupId: String? = nil,
        sizeBytes: Int,
        userGuid: String
    ) {
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.backedUpAt = backedUpAt
        self.backupId = backupId
        self.sizeBytes = sizeBytes
        self.userGuid = userGuid
    }
}

// MARK: - Errors

enum ProteanCredentialStoreError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case noCredentialStored
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save Protean Credential: \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve Protean Credential: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete Protean Credential: \(status)"
        case .noCredentialStored:
            return "No Protean Credential stored"
        case .encodingFailed:
            return "Failed to encode credential metadata"
        case .decodingFailed:
            return "Failed to decode credential metadata"
        }
    }
}
