import Foundation

/// Handler for service connection operations via NATS
///
/// Manages service connections including discovery, contracts, data sharing,
/// and activity tracking. Services are organizational vaults that users connect to
/// via data contracts.
///
/// NATS Topics:
/// - `service.connection.discover` - Discover service from code
/// - `service.connection.initiate` - Accept contract, establish connection
/// - `service.connection.list` - List service connections
/// - `service.connection.get` - Get connection details
/// - `service.connection.update` - Update tags, favorite, muted, archived
/// - `service.connection.revoke` - Revoke connection (clean break)
/// - `service.connection.health` - Get health metrics
/// - `service.data.list` - List data stored by service
/// - `service.data.delete` - Delete service data
/// - `service.data.export` - Export all data from service
/// - `service.data.summary` - Get storage summary
/// - `service.request.list` - List pending requests
/// - `service.request.respond` - Approve/deny request
/// - `service.contract.get` - Get current contract
/// - `service.contract.accept` - Accept contract update
/// - `service.contract.reject` - Reject update (terminates connection)
/// - `service.contract.history` - Get version history
/// - `service.activity.list` - List activity
/// - `service.activity.summary` - Get activity summary
/// - `service.notifications.get` - Get notification settings
/// - `service.notifications.update` - Update settings
/// - `service.profile.get` - Get service profile
/// - `service.profile.resources` - Get trusted resources
actor ServiceConnectionHandler {

    // MARK: - Dependencies

    private let vaultResponseHandler: VaultResponseHandler

    // MARK: - Configuration

    private let defaultTimeout: TimeInterval = 30
    private let exportTimeout: TimeInterval = 60

    // MARK: - Initialization

    init(vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    // MARK: - Discovery

    /// Discover a service from QR code or universal link
    /// - Parameter code: Service discovery code
    /// - Returns: Service profile and proposed contract
    func discoverService(code: String) async throws -> ServiceDiscoveryResult {
        let payload: [String: AnyCodableValue] = [
            "code": AnyCodableValue(code)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.connection.discover",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.discoveryFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try parseDiscoveryResult(from: result)
    }

    // MARK: - Connection Management

    /// Initiate a service connection by accepting a contract
    /// - Parameters:
    ///   - serviceId: Service GUID
    ///   - contractId: Contract ID to accept
    ///   - fieldMappings: Fields to share with the service
    /// - Returns: New connection record
    func initiateConnection(
        serviceId: String,
        contractId: String,
        fieldMappings: [SharedFieldMapping]
    ) async throws -> ServiceConnectionRecord {
        let mappingsData = try JSONEncoder().encode(fieldMappings)
        let mappingsJson = String(data: mappingsData, encoding: .utf8) ?? "[]"

        let payload: [String: AnyCodableValue] = [
            "service_id": AnyCodableValue(serviceId),
            "contract_id": AnyCodableValue(contractId),
            "field_mappings": AnyCodableValue(mappingsJson)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.connection.initiate",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.connectionFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try parseConnectionRecord(from: result)
    }

    /// List all service connections
    /// - Parameters:
    ///   - includeArchived: Include archived connections
    ///   - includeRevoked: Include revoked connections
    /// - Returns: List of service connection records
    func listConnections(
        includeArchived: Bool = false,
        includeRevoked: Bool = false
    ) async throws -> [ServiceConnectionRecord] {
        let payload: [String: AnyCodableValue] = [
            "include_archived": AnyCodableValue(includeArchived),
            "include_revoked": AnyCodableValue(includeRevoked)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.connection.list",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.listFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let connectionsData = result["connections"]?.value as? String,
              let data = connectionsData.data(using: .utf8) else {
            return []
        }

        return (try? JSONDecoder().decode([ServiceConnectionRecord].self, from: data)) ?? []
    }

    /// Get details for a specific service connection
    /// - Parameter connectionId: Connection ID
    /// - Returns: Service connection record
    func getConnection(connectionId: String) async throws -> ServiceConnectionRecord {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.connection.get",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.getFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try parseConnectionRecord(from: result)
    }

    /// Update connection properties (tags, favorite, muted, archived)
    /// - Parameters:
    ///   - connectionId: Connection ID
    ///   - tags: Updated tags (nil to not change)
    ///   - isFavorite: Updated favorite status (nil to not change)
    ///   - isMuted: Updated muted status (nil to not change)
    ///   - isArchived: Updated archived status (nil to not change)
    /// - Returns: Response indicating success/failure
    func updateConnection(
        connectionId: String,
        tags: [String]? = nil,
        isFavorite: Bool? = nil,
        isMuted: Bool? = nil,
        isArchived: Bool? = nil
    ) async throws -> VaultEventResponse {
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        if let tags = tags {
            payload["tags"] = AnyCodableValue(tags)
        }
        if let isFavorite = isFavorite {
            payload["is_favorite"] = AnyCodableValue(isFavorite)
        }
        if let isMuted = isMuted {
            payload["is_muted"] = AnyCodableValue(isMuted)
        }
        if let isArchived = isArchived {
            payload["is_archived"] = AnyCodableValue(isArchived)
        }

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "service.connection.update",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Revoke a service connection (clean break - immediate access termination)
    /// - Parameter connectionId: Connection ID to revoke
    /// - Returns: Response indicating success/failure
    func revokeConnection(connectionId: String) async throws -> VaultEventResponse {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "service.connection.revoke",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Get connection health metrics
    /// - Parameter connectionId: Connection ID
    /// - Returns: Health metrics for the connection
    func getConnectionHealth(connectionId: String) async throws -> ServiceConnectionHealth {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.connection.health",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.healthCheckFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try parseConnectionHealth(from: result)
    }

    // MARK: - Data Transparency

    /// List data stored by a service in user's sandbox
    /// - Parameter connectionId: Connection ID
    /// - Returns: List of stored data records
    func listStoredData(connectionId: String) async throws -> [ServiceStorageRecord] {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.data.list",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.dataListFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let recordsData = result["records"]?.value as? String,
              let data = recordsData.data(using: .utf8) else {
            return []
        }

        return (try? JSONDecoder().decode([ServiceStorageRecord].self, from: data)) ?? []
    }

    /// Delete data stored by a service
    /// - Parameters:
    ///   - connectionId: Connection ID
    ///   - keys: Specific keys to delete (nil for all data)
    /// - Returns: Response indicating success/failure
    func deleteData(connectionId: String, keys: [String]? = nil) async throws -> VaultEventResponse {
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        if let keys = keys {
            payload["keys"] = AnyCodableValue(keys)
        }

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "service.data.delete",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Export all data from a service connection
    /// - Parameter connectionId: Connection ID
    /// - Returns: Exported data
    func exportData(connectionId: String) async throws -> ServiceDataExport {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.data.export",
            payload: payload,
            timeout: exportTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.exportFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try parseDataExport(from: result)
    }

    /// Get data storage summary for a service connection
    /// - Parameter connectionId: Connection ID
    /// - Returns: Storage summary
    func getDataSummary(connectionId: String) async throws -> ServiceDataSummary {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.data.summary",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.summaryFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try parseDataSummary(from: result)
    }

    // MARK: - Service Requests

    /// List pending service requests
    /// - Parameter connectionId: Optional connection ID to filter by
    /// - Returns: List of service requests
    func listRequests(connectionId: String? = nil) async throws -> [ServiceRequest] {
        var payload: [String: AnyCodableValue] = [:]

        if let connectionId = connectionId {
            payload["connection_id"] = AnyCodableValue(connectionId)
        }

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.request.list",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.requestListFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let requestsData = result["requests"]?.value as? String,
              let data = requestsData.data(using: .utf8) else {
            return []
        }

        return (try? JSONDecoder().decode([ServiceRequest].self, from: data)) ?? []
    }

    /// Respond to a service request
    /// - Parameters:
    ///   - requestId: Request ID
    ///   - approved: Whether to approve or deny
    ///   - responseData: Optional response data
    /// - Returns: Response indicating success/failure
    func respondToRequest(
        requestId: String,
        approved: Bool,
        responseData: [String: String]? = nil
    ) async throws -> VaultEventResponse {
        var payload: [String: AnyCodableValue] = [
            "request_id": AnyCodableValue(requestId),
            "approved": AnyCodableValue(approved)
        ]

        if let responseData = responseData {
            payload["response_data"] = AnyCodableValue(responseData)
        }

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "service.request.respond",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    // MARK: - Contract Management

    /// Get current contract for a service connection
    /// - Parameter connectionId: Connection ID
    /// - Returns: Current data contract
    func getContract(connectionId: String) async throws -> ServiceDataContract {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.contract.get",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.contractFetchFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let contractData = result["contract"]?.value as? String,
              let data = contractData.data(using: .utf8) else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try JSONDecoder().decode(ServiceDataContract.self, from: data)
    }

    /// Accept a contract update
    /// - Parameters:
    ///   - connectionId: Connection ID
    ///   - newContractVersion: New contract version to accept
    ///   - updatedFieldMappings: Updated field mappings for new requirements
    /// - Returns: Response indicating success/failure
    func acceptContractUpdate(
        connectionId: String,
        newContractVersion: Int,
        updatedFieldMappings: [SharedFieldMapping]
    ) async throws -> VaultEventResponse {
        let mappingsData = try JSONEncoder().encode(updatedFieldMappings)
        let mappingsJson = String(data: mappingsData, encoding: .utf8) ?? "[]"

        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "new_version": AnyCodableValue(newContractVersion),
            "field_mappings": AnyCodableValue(mappingsJson)
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "service.contract.accept",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Reject a contract update (terminates the connection)
    /// - Parameter connectionId: Connection ID
    /// - Returns: Response indicating success/failure
    func rejectContractUpdate(connectionId: String) async throws -> VaultEventResponse {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "service.contract.reject",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    /// Get contract version history
    /// - Parameter connectionId: Connection ID
    /// - Returns: List of contract versions
    func getContractHistory(connectionId: String) async throws -> [ContractVersion] {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.contract.history",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.historyFetchFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let historyData = result["history"]?.value as? String,
              let data = historyData.data(using: .utf8) else {
            return []
        }

        return (try? JSONDecoder().decode([ContractVersion].self, from: data)) ?? []
    }

    // MARK: - Activity

    /// List activity for a service connection
    /// - Parameters:
    ///   - connectionId: Connection ID
    ///   - limit: Maximum number of activities to return
    ///   - offset: Offset for pagination
    /// - Returns: List of activities
    func listActivity(
        connectionId: String,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> [ServiceActivity] {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "limit": AnyCodableValue(limit),
            "offset": AnyCodableValue(offset)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.activity.list",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.activityFetchFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let activityData = result["activities"]?.value as? String,
              let data = activityData.data(using: .utf8) else {
            return []
        }

        return (try? JSONDecoder().decode([ServiceActivity].self, from: data)) ?? []
    }

    /// Get activity summary for a service connection
    /// - Parameter connectionId: Connection ID
    /// - Returns: Activity summary
    func getActivitySummary(connectionId: String) async throws -> ServiceActivitySummary {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.activity.summary",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.activityFetchFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let summaryData = result["summary"]?.value as? String,
              let data = summaryData.data(using: .utf8) else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try JSONDecoder().decode(ServiceActivitySummary.self, from: data)
    }

    // MARK: - Notification Settings

    /// Get notification settings for a service connection
    /// - Parameter connectionId: Connection ID
    /// - Returns: Notification settings
    func getNotificationSettings(connectionId: String) async throws -> ServiceNotificationSettings {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.notifications.get",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            // Return default settings if not found
            return ServiceNotificationSettings.defaultSettings(for: connectionId)
        }

        guard let result = response.result,
              let settingsData = result["settings"]?.value as? String,
              let data = settingsData.data(using: .utf8) else {
            return ServiceNotificationSettings.defaultSettings(for: connectionId)
        }

        return (try? JSONDecoder().decode(ServiceNotificationSettings.self, from: data))
            ?? ServiceNotificationSettings.defaultSettings(for: connectionId)
    }

    /// Update notification settings for a service connection
    /// - Parameter settings: Updated settings
    /// - Returns: Response indicating success/failure
    func updateNotificationSettings(_ settings: ServiceNotificationSettings) async throws -> VaultEventResponse {
        let settingsData = try JSONEncoder().encode(settings)
        let settingsJson = String(data: settingsData, encoding: .utf8) ?? "{}"

        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(settings.connectionId),
            "settings": AnyCodableValue(settingsJson)
        ]

        return try await vaultResponseHandler.submitRawAndAwait(
            type: "service.notifications.update",
            payload: payload,
            timeout: defaultTimeout
        )
    }

    // MARK: - Service Profile

    /// Get cached service profile
    /// - Parameter connectionId: Connection ID
    /// - Returns: Service profile
    func getServiceProfile(connectionId: String) async throws -> ServiceProfile {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.profile.get",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.profileFetchFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let profileData = result["profile"]?.value as? String,
              let data = profileData.data(using: .utf8) else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try JSONDecoder().decode(ServiceProfile.self, from: data)
    }

    /// Get trusted resources for a service
    /// - Parameter connectionId: Connection ID
    /// - Returns: List of trusted resources
    func getTrustedResources(connectionId: String) async throws -> [TrustedResource] {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "service.profile.resources",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw ServiceConnectionHandlerError.resourcesFetchFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result,
              let resourcesData = result["resources"]?.value as? String,
              let data = resourcesData.data(using: .utf8) else {
            return []
        }

        return (try? JSONDecoder().decode([TrustedResource].self, from: data)) ?? []
    }

    // MARK: - Private Parsing Methods

    private func parseDiscoveryResult(from result: [String: AnyCodableValue]) throws -> ServiceDiscoveryResult {
        guard let profileData = result["service_profile"]?.value as? String,
              let profileBytes = profileData.data(using: .utf8),
              let contractData = result["proposed_contract"]?.value as? String,
              let contractBytes = contractData.data(using: .utf8) else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        let profile = try JSONDecoder().decode(ServiceProfile.self, from: profileBytes)
        let contract = try JSONDecoder().decode(ServiceDataContract.self, from: contractBytes)

        var missingFields: [FieldSpec] = []
        if let missingData = result["missing_required_fields"]?.value as? String,
           let missingBytes = missingData.data(using: .utf8) {
            missingFields = (try? JSONDecoder().decode([FieldSpec].self, from: missingBytes)) ?? []
        }

        return ServiceDiscoveryResult(
            serviceProfile: profile,
            proposedContract: contract,
            missingRequiredFields: missingFields
        )
    }

    private func parseConnectionRecord(from result: [String: AnyCodableValue]) throws -> ServiceConnectionRecord {
        guard let connectionData = result["connection"]?.value as? String,
              let data = connectionData.data(using: .utf8) else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try JSONDecoder().decode(ServiceConnectionRecord.self, from: data)
    }

    private func parseConnectionHealth(from result: [String: AnyCodableValue]) throws -> ServiceConnectionHealth {
        guard let healthData = result["health"]?.value as? String,
              let data = healthData.data(using: .utf8) else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try JSONDecoder().decode(ServiceConnectionHealth.self, from: data)
    }

    private func parseDataExport(from result: [String: AnyCodableValue]) throws -> ServiceDataExport {
        guard let exportData = result["export"]?.value as? String,
              let data = exportData.data(using: .utf8) else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try JSONDecoder().decode(ServiceDataExport.self, from: data)
    }

    private func parseDataSummary(from result: [String: AnyCodableValue]) throws -> ServiceDataSummary {
        guard let summaryData = result["summary"]?.value as? String,
              let data = summaryData.data(using: .utf8) else {
            throw ServiceConnectionHandlerError.invalidResponse
        }

        return try JSONDecoder().decode(ServiceDataSummary.self, from: data)
    }
}

// MARK: - Errors

enum ServiceConnectionHandlerError: LocalizedError {
    case discoveryFailed(String)
    case connectionFailed(String)
    case listFailed(String)
    case getFailed(String)
    case healthCheckFailed(String)
    case dataListFailed(String)
    case exportFailed(String)
    case summaryFailed(String)
    case requestListFailed(String)
    case contractFetchFailed(String)
    case historyFetchFailed(String)
    case activityFetchFailed(String)
    case profileFetchFailed(String)
    case resourcesFetchFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let reason):
            return "Failed to discover service: \(reason)"
        case .connectionFailed(let reason):
            return "Failed to connect to service: \(reason)"
        case .listFailed(let reason):
            return "Failed to list connections: \(reason)"
        case .getFailed(let reason):
            return "Failed to get connection: \(reason)"
        case .healthCheckFailed(let reason):
            return "Health check failed: \(reason)"
        case .dataListFailed(let reason):
            return "Failed to list stored data: \(reason)"
        case .exportFailed(let reason):
            return "Failed to export data: \(reason)"
        case .summaryFailed(let reason):
            return "Failed to get data summary: \(reason)"
        case .requestListFailed(let reason):
            return "Failed to list requests: \(reason)"
        case .contractFetchFailed(let reason):
            return "Failed to fetch contract: \(reason)"
        case .historyFetchFailed(let reason):
            return "Failed to fetch contract history: \(reason)"
        case .activityFetchFailed(let reason):
            return "Failed to fetch activity: \(reason)"
        case .profileFetchFailed(let reason):
            return "Failed to fetch service profile: \(reason)"
        case .resourcesFetchFailed(let reason):
            return "Failed to fetch trusted resources: \(reason)"
        case .invalidResponse:
            return "Invalid response from vault"
        }
    }
}
