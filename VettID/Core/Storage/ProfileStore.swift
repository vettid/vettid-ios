import Foundation
import Security

/// Secure storage for user profile using iOS Keychain
final class ProfileStore {

    private let service = "com.vettid.profile"

    // MARK: - Profile Storage

    /// Store a profile securely in the Keychain
    func store(profile: Profile) throws {
        let data = try JSONEncoder().encode(profile)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.guid,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete existing item if present
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProfileStoreError.saveFailed(status)
        }
    }

    /// Update an existing profile in the Keychain
    func update(profile: Profile) throws {
        let data = try JSONEncoder().encode(profile)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.guid
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            // If not found, try to add instead
            if status == errSecItemNotFound {
                try store(profile: profile)
                return
            }
            throw ProfileStoreError.saveFailed(status)
        }
    }

    /// Retrieve a profile from the Keychain by user GUID
    func retrieve(userGuid: String) throws -> Profile? {
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
            throw ProfileStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(Profile.self, from: data)
    }

    /// Retrieve the first stored profile (for single-user scenarios)
    func retrieveFirst() throws -> Profile? {
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
            throw ProfileStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(Profile.self, from: data)
    }

    /// Check if any profile is stored
    func hasStoredProfile() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Delete a profile from the Keychain
    func delete(userGuid: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userGuid
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileStoreError.deleteFailed(status)
        }
    }

    /// Delete all stored profiles
    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileStoreError.deleteFailed(status)
        }
    }
}

// MARK: - Errors

enum ProfileStoreError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save profile: \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve profile: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete profile: \(status)"
        case .encodingFailed:
            return "Failed to encode profile"
        case .decodingFailed:
            return "Failed to decode profile"
        }
    }
}
