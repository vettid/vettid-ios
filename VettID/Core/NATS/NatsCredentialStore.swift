import Foundation
import Security

/// Secure storage for NATS credentials using Keychain
final class NatsCredentialStore {

    // MARK: - Constants

    private let service = "com.vettid.nats"
    private let credentialsKey = "nats_credentials"
    private let accountInfoKey = "nats_account_info"

    // MARK: - Credentials Management

    /// Save NATS credentials to Keychain
    func saveCredentials(_ credentials: NatsCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try saveToKeychain(data: data, key: credentialsKey)
    }

    /// Retrieve NATS credentials from Keychain
    func getCredentials() throws -> NatsCredentials? {
        guard let data = try loadFromKeychain(key: credentialsKey) else {
            return nil
        }
        return try JSONDecoder().decode(NatsCredentials.self, from: data)
    }

    /// Delete NATS credentials from Keychain
    func deleteCredentials() throws {
        try deleteFromKeychain(key: credentialsKey)
    }

    /// Check if valid (non-expired) credentials exist
    func hasValidCredentials() throws -> Bool {
        guard let credentials = try getCredentials() else {
            return false
        }
        return !credentials.isExpired
    }

    // MARK: - Account Info Management

    /// Save NATS account info to Keychain
    func saveAccountInfo(_ accountInfo: NatsAccountInfo) throws {
        let data = try JSONEncoder().encode(accountInfo)
        try saveToKeychain(data: data, key: accountInfoKey)
    }

    /// Retrieve NATS account info from Keychain
    func getAccountInfo() throws -> NatsAccountInfo? {
        guard let data = try loadFromKeychain(key: accountInfoKey) else {
            return nil
        }
        return try JSONDecoder().decode(NatsAccountInfo.self, from: data)
    }

    /// Delete NATS account info from Keychain
    func deleteAccountInfo() throws {
        try deleteFromKeychain(key: accountInfoKey)
    }

    // MARK: - Clear All

    /// Clear all NATS-related data from Keychain
    func clearAll() throws {
        try? deleteCredentials()
        try? deleteAccountInfo()
    }

    // MARK: - Private Keychain Operations

    private func saveToKeychain(data: Data, key: String) throws {
        // First try to delete any existing item
        try? deleteFromKeychain(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw NatsCredentialStoreError.keychainError(status)
        }
    }

    private func loadFromKeychain(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw NatsCredentialStoreError.keychainError(status)
        }
    }

    private func deleteFromKeychain(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NatsCredentialStoreError.keychainError(status)
        }
    }
}

// MARK: - Errors

enum NatsCredentialStoreError: LocalizedError {
    case keychainError(OSStatus)
    case encodingError
    case decodingError

    var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .encodingError:
            return "Failed to encode credentials"
        case .decodingError:
            return "Failed to decode credentials"
        }
    }
}
