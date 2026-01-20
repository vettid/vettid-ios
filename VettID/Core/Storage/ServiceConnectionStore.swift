import Foundation
import Security

/// Secure storage for Service Connections using iOS Keychain
///
/// Stores service connection records, notification settings, and offline actions.
///
/// Security features:
/// - Keychain storage with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// - No iCloud sync (device-only storage)
/// - Separate storage keys for connections, settings, and offline queue
final class ServiceConnectionStore {

    // MARK: - Service Identifiers

    private let connectionsService = "com.vettid.service.connections"
    private let settingsService = "com.vettid.service.settings"
    private let offlineQueueService = "com.vettid.service.offline"
    private let profileCacheService = "com.vettid.service.profilecache"

    // MARK: - Connection Storage

    /// Store a service connection record
    func store(connection: ServiceConnectionRecord) throws {
        let data = try JSONEncoder().encode(connection)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionsService,
            kSecAttrAccount as String: connection.id,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        // Delete existing item if present
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionsService,
            kSecAttrAccount as String: connection.id
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ServiceConnectionStoreError.saveFailed(status)
        }
    }

    /// Update an existing service connection
    func update(connection: ServiceConnectionRecord) throws {
        let data = try JSONEncoder().encode(connection)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionsService,
            kSecAttrAccount as String: connection.id
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                try store(connection: connection)
                return
            }
            throw ServiceConnectionStoreError.saveFailed(status)
        }
    }

    /// Retrieve a service connection by ID
    func retrieve(connectionId: String) throws -> ServiceConnectionRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionsService,
            kSecAttrAccount as String: connectionId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw ServiceConnectionStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(ServiceConnectionRecord.self, from: data)
    }

    /// List all service connections
    /// - Parameters:
    ///   - includeArchived: Include archived connections
    ///   - includeRevoked: Include revoked connections
    func listConnections(includeArchived: Bool = false, includeRevoked: Bool = false) throws -> [ServiceConnectionRecord] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionsService,
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
            throw ServiceConnectionStoreError.retrieveFailed(status)
        }

        guard let items = result as? [[String: Any]] else {
            return []
        }

        var connections: [ServiceConnectionRecord] = []
        for item in items {
            guard let data = item[kSecValueData as String] as? Data else { continue }
            do {
                let connection = try JSONDecoder().decode(ServiceConnectionRecord.self, from: data)

                // Apply filters
                if !includeArchived && connection.isArchived { continue }
                if !includeRevoked && connection.status == .revoked { continue }

                connections.append(connection)
            } catch {
                // Skip malformed entries
                continue
            }
        }

        return connections.sorted { ($0.lastActivityAt ?? $0.createdAt) > ($1.lastActivityAt ?? $1.createdAt) }
    }

    /// Delete a service connection
    func delete(connectionId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionsService,
            kSecAttrAccount as String: connectionId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceConnectionStoreError.deleteFailed(status)
        }

        // Also delete associated settings
        try? deleteNotificationSettings(connectionId: connectionId)
    }

    /// Delete all service connections
    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionsService
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceConnectionStoreError.deleteFailed(status)
        }

        // Also delete all settings
        try? deleteAllNotificationSettings()
    }

    // MARK: - Notification Settings Storage

    /// Store notification settings for a service connection
    func storeNotificationSettings(_ settings: ServiceNotificationSettings) throws {
        let data = try JSONEncoder().encode(settings)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: settingsService,
            kSecAttrAccount as String: settings.connectionId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        // Delete existing item if present
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: settingsService,
            kSecAttrAccount as String: settings.connectionId
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ServiceConnectionStoreError.saveFailed(status)
        }
    }

    /// Retrieve notification settings for a service connection
    func retrieveNotificationSettings(connectionId: String) throws -> ServiceNotificationSettings? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: settingsService,
            kSecAttrAccount as String: connectionId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw ServiceConnectionStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(ServiceNotificationSettings.self, from: data)
    }

    /// Delete notification settings for a connection
    func deleteNotificationSettings(connectionId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: settingsService,
            kSecAttrAccount as String: connectionId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceConnectionStoreError.deleteFailed(status)
        }
    }

    /// Delete all notification settings
    private func deleteAllNotificationSettings() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: settingsService
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceConnectionStoreError.deleteFailed(status)
        }
    }

    // MARK: - Offline Queue Storage

    /// Store an offline action
    func storeOfflineAction(_ action: OfflineServiceAction) throws {
        let data = try JSONEncoder().encode(action)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: offlineQueueService,
            kSecAttrAccount as String: action.id,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        // Delete existing item if present
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: offlineQueueService,
            kSecAttrAccount as String: action.id
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ServiceConnectionStoreError.saveFailed(status)
        }
    }

    /// Update an offline action
    func updateOfflineAction(_ action: OfflineServiceAction) throws {
        let data = try JSONEncoder().encode(action)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: offlineQueueService,
            kSecAttrAccount as String: action.id
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                try storeOfflineAction(action)
                return
            }
            throw ServiceConnectionStoreError.saveFailed(status)
        }
    }

    /// List all pending offline actions
    func listOfflineActions(status filterStatus: SyncStatus? = nil) throws -> [OfflineServiceAction] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: offlineQueueService,
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
            throw ServiceConnectionStoreError.retrieveFailed(status)
        }

        guard let items = result as? [[String: Any]] else {
            return []
        }

        var actions: [OfflineServiceAction] = []
        for item in items {
            guard let data = item[kSecValueData as String] as? Data else { continue }
            do {
                let action = try JSONDecoder().decode(OfflineServiceAction.self, from: data)

                // Apply filter
                if let filterStatus = filterStatus, action.syncStatus != filterStatus {
                    continue
                }

                actions.append(action)
            } catch {
                continue
            }
        }

        return actions.sorted { $0.createdAt < $1.createdAt }
    }

    /// Delete an offline action
    func deleteOfflineAction(actionId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: offlineQueueService,
            kSecAttrAccount as String: actionId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceConnectionStoreError.deleteFailed(status)
        }
    }

    /// Delete all synced offline actions
    func clearSyncedActions() throws {
        let actions = try listOfflineActions(status: .synced)
        for action in actions {
            try deleteOfflineAction(actionId: action.id)
        }
    }

    // MARK: - Service Profile Cache

    /// Cache a service profile for offline viewing
    func cacheServiceProfile(_ profile: ServiceProfile) throws {
        let data = try JSONEncoder().encode(profile)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileCacheService,
            kSecAttrAccount as String: profile.id,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        // Delete existing cache entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileCacheService,
            kSecAttrAccount as String: profile.id
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ServiceConnectionStoreError.saveFailed(status)
        }
    }

    /// Retrieve a cached service profile
    func retrieveCachedProfile(serviceId: String) throws -> ServiceProfile? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileCacheService,
            kSecAttrAccount as String: serviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            throw ServiceConnectionStoreError.retrieveFailed(status)
        }

        return try JSONDecoder().decode(ServiceProfile.self, from: data)
    }

    /// Delete a cached service profile
    func deleteCachedProfile(serviceId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileCacheService,
            kSecAttrAccount as String: serviceId
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceConnectionStoreError.deleteFailed(status)
        }
    }

    // MARK: - Utility Methods

    /// Check if a connection exists
    func hasConnection(connectionId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectionsService,
            kSecAttrAccount as String: connectionId,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Count of active service connections
    func activeConnectionCount() throws -> Int {
        let connections = try listConnections(includeArchived: false, includeRevoked: false)
        return connections.filter { $0.status == .active }.count
    }

    /// Get connections by service GUID
    func connectionsByService(serviceGuid: String) throws -> [ServiceConnectionRecord] {
        let connections = try listConnections(includeArchived: true, includeRevoked: true)
        return connections.filter { $0.serviceGuid == serviceGuid }
    }

    /// Get connections with pending contract updates
    func connectionsWithPendingUpdates() throws -> [ServiceConnectionRecord] {
        let connections = try listConnections(includeArchived: false, includeRevoked: false)
        return connections.filter { $0.pendingContractVersion != nil }
    }

    /// Get favorite connections
    func favoriteConnections() throws -> [ServiceConnectionRecord] {
        let connections = try listConnections(includeArchived: false, includeRevoked: false)
        return connections.filter { $0.isFavorite }
    }

    /// Get connections by tag
    func connectionsByTag(_ tag: String) throws -> [ServiceConnectionRecord] {
        let connections = try listConnections(includeArchived: false, includeRevoked: false)
        return connections.filter { $0.tags.contains(tag) }
    }

    /// Get all unique tags across connections
    func allTags() throws -> [String] {
        let connections = try listConnections(includeArchived: false, includeRevoked: false)
        var tags = Set<String>()
        for connection in connections {
            tags.formUnion(connection.tags)
        }
        return Array(tags).sorted()
    }
}

// MARK: - Errors

enum ServiceConnectionStoreError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case decodingFailed
    case notFound

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save service connection: \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve service connection: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete service connection: \(status)"
        case .encodingFailed:
            return "Failed to encode service connection"
        case .decodingFailed:
            return "Failed to decode service connection"
        case .notFound:
            return "Service connection not found"
        }
    }
}
