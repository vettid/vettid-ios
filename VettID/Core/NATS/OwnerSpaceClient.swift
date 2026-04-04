import Foundation

/// Client for communicating with the vault via OwnerSpace NATS topics
///
/// Topic structure:
/// - Publish: OwnerSpace.{guid}.forVault.{topic}
/// - Subscribe: OwnerSpace.{guid}.forApp.{topic}
final class OwnerSpaceClient {

    // MARK: - Properties

    private let connectionManager: NatsConnectionManager
    private let ownerSpaceId: String

    // Topic prefixes
    private var forVaultPrefix: String { "\(ownerSpaceId).forVault" }
    private var forAppPrefix: String { "\(ownerSpaceId).forApp" }
    private var eventTypesSubject: String { "\(ownerSpaceId).eventTypes" }

    // MARK: - Initialization

    init(connectionManager: NatsConnectionManager, ownerSpaceId: String) {
        self.connectionManager = connectionManager
        self.ownerSpaceId = ownerSpaceId
    }

    // MARK: - Send to Vault

    /// Send a message to the vault
    func sendToVault<T: Encodable>(_ message: T, topic: String) async throws {
        let fullTopic = "\(forVaultPrefix).\(topic)"
        try await connectionManager.publish(message, to: fullTopic)
    }

    /// Send raw data to the vault
    func sendToVault(_ data: Data, topic: String) async throws {
        let fullTopic = "\(forVaultPrefix).\(topic)"
        try await connectionManager.publish(data, to: fullTopic)
    }

    /// Execute a handler in the vault
    func executeHandler(handlerId: String, payload: [String: Any]) async throws -> String {
        let id = UUID().uuidString
        let message = ExecuteHandlerRequest(
            id: id,
            handlerId: handlerId,
            payload: payload
        )

        try await sendToVault(message, topic: "execute")
        return id
    }

    /// Request vault status
    func requestStatus() async throws -> String {
        let id = UUID().uuidString
        let message = StatusRequest(id: id)

        try await sendToVault(message, topic: "status")
        return id
    }

    // MARK: - Subscribe from Vault

    /// Subscribe to messages from the vault on a specific topic
    func subscribeToVault<T: Decodable>(topic: String, type: T.Type) async throws -> AsyncStream<T> {
        let fullTopic = "\(forAppPrefix).\(topic)"
        return try await connectionManager.subscribe(to: fullTopic, type: type)
    }

    /// Subscribe to all vault responses
    func subscribeToAllVaultResponses() async throws -> AsyncStream<VaultResponse> {
        let fullTopic = "\(forAppPrefix).>"
        return try await connectionManager.subscribe(to: fullTopic, type: VaultResponse.self)
    }

    /// Subscribe to handler results
    func subscribeToHandlerResults() async throws -> AsyncStream<HandlerResultResponse> {
        return try await subscribeToVault(topic: "result", type: HandlerResultResponse.self)
    }

    /// Subscribe to status responses
    func subscribeToStatusResponses() async throws -> AsyncStream<StatusResponse> {
        return try await subscribeToVault(topic: "status", type: StatusResponse.self)
    }

    /// Subscribe to vault events (legacy)
    func subscribeToEvents() async throws -> AsyncStream<VaultEvent> {
        return try await subscribeToVault(topic: "events", type: VaultEvent.self)
    }

    // MARK: - Security Events (Issue #17)

    /// Subscribe to security events from the vault
    /// Topics: forApp.recovery.>, forApp.transfer.>, forApp.security.>
    func subscribeToSecurityEvents() async throws -> AsyncStream<VaultSecurityEvent> {
        // Subscribe to all security-related topics using wildcards
        let topics = [
            "\(forAppPrefix).recovery.>",
            "\(forAppPrefix).transfer.>",
            "\(forAppPrefix).security.>"
        ]

        return AsyncStream { continuation in
            Task {
                // Create a task group to handle multiple subscriptions
                await withTaskGroup(of: Void.self) { group in
                    for topic in topics {
                        group.addTask { [weak self] in
                            guard let self = self else { return }

                            do {
                                let stream = try await self.connectionManager.subscribe(
                                    to: topic,
                                    type: SecurityEventMessage.self
                                )

                                for await message in stream {
                                    if let event = VaultSecurityEvent.parse(from: message) {
                                        continuation.yield(event)
                                    }
                                }
                            } catch {
                                #if DEBUG
                                print("[OwnerSpaceClient] Failed to subscribe to \(topic): \(error)")
                                #endif
                            }
                        }
                    }
                }

                continuation.finish()
            }
        }
    }

    /// Subscribe to recovery events only
    func subscribeToRecoveryEvents() async throws -> AsyncStream<VaultSecurityEvent> {
        let topic = "\(forAppPrefix).recovery.>"
        return try await subscribeToSecurityTopic(topic)
    }

    /// Subscribe to transfer events only
    func subscribeToTransferEvents() async throws -> AsyncStream<VaultSecurityEvent> {
        let topic = "\(forAppPrefix).transfer.>"
        return try await subscribeToSecurityTopic(topic)
    }

    /// Subscribe to fraud detection events only
    func subscribeToFraudEvents() async throws -> AsyncStream<VaultSecurityEvent> {
        let topic = "\(forAppPrefix).security.>"
        return try await subscribeToSecurityTopic(topic)
    }

    /// Helper to subscribe to a single security topic
    private func subscribeToSecurityTopic(_ topic: String) async throws -> AsyncStream<VaultSecurityEvent> {
        let stream = try await connectionManager.subscribe(to: topic, type: SecurityEventMessage.self)

        return AsyncStream { continuation in
            Task {
                for await message in stream {
                    if let event = VaultSecurityEvent.parse(from: message) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Request/Response Pattern

    /// Send a request and wait for a response with timeout (legacy subscription-based)
    func request<Request: Encodable, Response: Decodable>(
        _ request: Request,
        topic: String,
        responseType: Response.Type,
        timeout: TimeInterval = 30
    ) async throws -> Response {
        // Subscribe to response topic first
        let responseTopic = "\(forAppPrefix).\(topic).response"
        let responseStream = try await connectionManager.subscribe(to: responseTopic, type: Response.self)

        // Send the request
        try await sendToVault(request, topic: topic)

        // Wait for response with timeout
        return try await withThrowingTaskGroup(of: Response.self) { group in
            // Response listener task
            group.addTask {
                for await response in responseStream {
                    return response
                }
                throw OwnerSpaceError.noResponse
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw OwnerSpaceError.timeout
            }

            // Return first result (response or timeout)
            guard let result = try await group.next() else {
                throw OwnerSpaceError.noResponse
            }

            group.cancelAll()
            return result
        }
    }

    // MARK: - JetStream Request/Response (event_id correlation)

    /// Send a message to the vault and await the response via JetStream.
    ///
    /// Uses JetStreamHelper to create an ephemeral consumer for reliable
    /// response delivery with event_id correlation. This avoids race conditions
    /// that occur with regular NATS subscriptions.
    ///
    /// - Parameters:
    ///   - messageType: The message type/action (e.g., "profile.get", "feed.sync")
    ///   - payload: The message payload as dictionary
    ///   - timeout: Timeout in seconds (default 30)
    /// - Returns: The parsed vault response, or nil if timeout
    func sendAndAwaitResponse(
        _ messageType: String,
        payload: [String: AnyCodableValue] = [:],
        timeout: TimeInterval = 30
    ) async throws -> VaultHandlerResponse {
        let requestId = UUID().uuidString
        let requestSubject = "\(forVaultPrefix).\(messageType)"
        let responseSubject = "\(forAppPrefix).\(messageType).response"

        let message = VaultEventMessage(
            id: requestId,
            type: messageType,
            payload: payload,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        let requestPayload = try JSONEncoder().encode(message)

        let responseData = try await JetStreamHelper.sendAndFetchResponse(
            connectionManager: connectionManager,
            requestSubject: requestSubject,
            responseSubject: responseSubject,
            requestPayload: requestPayload,
            expectedEventId: requestId,
            timeoutSeconds: timeout
        )

        // Parse response
        let response = try parseVaultResponse(requestId: requestId, data: responseData)

        // Detect vault_locked error and emit event for PIN re-entry
        if !response.success && response.errorCode == "vault_locked" {
            emitVaultLockedEvent(VaultLockedEvent(
                reason: response.error ?? "DEK unavailable",
                messageType: messageType
            ))
        }

        return response
    }

    /// Parse vault response data into a VaultHandlerResponse
    private func parseVaultResponse(requestId: String, data: Data) throws -> VaultHandlerResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OwnerSpaceError.invalidResponse
        }

        let success = json["success"] as? Bool ?? (json["error"] == nil)
        let error = json["error"] as? String
        let errorCode = json["error_code"] as? String

        // Extract result object
        var result: [String: Any]?
        if let resultDict = json["result"] as? [String: Any] {
            result = resultDict
        } else if success {
            // Some responses put data at the top level
            result = json
        }

        return VaultHandlerResponse(
            requestId: json["event_id"] as? String ?? json["id"] as? String ?? requestId,
            success: success,
            result: result,
            error: error,
            errorCode: errorCode
        )
    }

    // MARK: - Agent Events

    /// Publisher for agent approval requests
    private var agentApprovalContinuation: AsyncStream<AgentApprovalRequest>.Continuation?
    private var _agentApprovalStream: AsyncStream<AgentApprovalRequest>?

    /// Stream of agent approval requests from vault
    var agentApprovalRequests: AsyncStream<AgentApprovalRequest> {
        if let stream = _agentApprovalStream {
            return stream
        }
        let stream = AsyncStream<AgentApprovalRequest> { continuation in
            self.agentApprovalContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.agentApprovalContinuation = nil
                self?._agentApprovalStream = nil
            }
        }
        _agentApprovalStream = stream
        return stream
    }

    /// Emit an agent approval request (called from message handler)
    func emitAgentApprovalRequest(_ request: AgentApprovalRequest) {
        agentApprovalContinuation?.yield(request)
    }

    // MARK: - Device Events

    /// Publisher for device approval requests
    private var deviceApprovalContinuation: AsyncStream<DeviceApprovalRequest>.Continuation?
    private var _deviceApprovalStream: AsyncStream<DeviceApprovalRequest>?

    /// Stream of device approval requests from vault
    var deviceApprovalRequests: AsyncStream<DeviceApprovalRequest> {
        if let stream = _deviceApprovalStream {
            return stream
        }
        let stream = AsyncStream<DeviceApprovalRequest> { continuation in
            self.deviceApprovalContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.deviceApprovalContinuation = nil
                self?._deviceApprovalStream = nil
            }
        }
        _deviceApprovalStream = stream
        return stream
    }

    /// Emit a device approval request (called from message handler)
    func emitDeviceApprovalRequest(_ request: DeviceApprovalRequest) {
        deviceApprovalContinuation?.yield(request)
    }

    // MARK: - Connection Events

    /// Publisher for connection acceptance notifications
    private var connectionAcceptanceContinuation: AsyncStream<ConnectionPeerAccepted>.Continuation?
    private var _connectionAcceptanceStream: AsyncStream<ConnectionPeerAccepted>?

    var connectionAcceptances: AsyncStream<ConnectionPeerAccepted> {
        if let stream = _connectionAcceptanceStream {
            return stream
        }
        let stream = AsyncStream<ConnectionPeerAccepted> { continuation in
            self.connectionAcceptanceContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.connectionAcceptanceContinuation = nil
                self?._connectionAcceptanceStream = nil
            }
        }
        _connectionAcceptanceStream = stream
        return stream
    }

    func emitConnectionAcceptance(_ acceptance: ConnectionPeerAccepted) {
        connectionAcceptanceContinuation?.yield(acceptance)
    }

    /// Publisher for connection status updates
    private var connectionStatusContinuation: AsyncStream<ConnectionStatusUpdate>.Continuation?
    private var _connectionStatusStream: AsyncStream<ConnectionStatusUpdate>?

    var connectionStatusUpdates: AsyncStream<ConnectionStatusUpdate> {
        if let stream = _connectionStatusStream {
            return stream
        }
        let stream = AsyncStream<ConnectionStatusUpdate> { continuation in
            self.connectionStatusContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.connectionStatusContinuation = nil
                self?._connectionStatusStream = nil
            }
        }
        _connectionStatusStream = stream
        return stream
    }

    func emitConnectionStatusUpdate(_ update: ConnectionStatusUpdate) {
        connectionStatusContinuation?.yield(update)
    }

    // MARK: - Feed Events

    /// Publisher for feed notifications
    private var feedNotificationContinuation: AsyncStream<FeedNotification>.Continuation?
    private var _feedNotificationStream: AsyncStream<FeedNotification>?

    var feedNotifications: AsyncStream<FeedNotification> {
        if let stream = _feedNotificationStream {
            return stream
        }
        let stream = AsyncStream<FeedNotification> { continuation in
            self.feedNotificationContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.feedNotificationContinuation = nil
                self?._feedNotificationStream = nil
            }
        }
        _feedNotificationStream = stream
        return stream
    }

    func emitFeedNotification(_ notification: FeedNotification) {
        feedNotificationContinuation?.yield(notification)
    }

    // MARK: - Vault Locked Events

    /// Publisher for vault locked events (DEK unavailable after enclave refresh)
    private var vaultLockedContinuation: AsyncStream<VaultLockedEvent>.Continuation?
    private var _vaultLockedStream: AsyncStream<VaultLockedEvent>?

    /// Stream of vault locked events — triggers PIN re-entry
    var vaultLockedEvents: AsyncStream<VaultLockedEvent> {
        if let stream = _vaultLockedStream {
            return stream
        }
        let stream = AsyncStream<VaultLockedEvent> { continuation in
            self.vaultLockedContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.vaultLockedContinuation = nil
                self?._vaultLockedStream = nil
            }
        }
        _vaultLockedStream = stream
        return stream
    }

    func emitVaultLockedEvent(_ event: VaultLockedEvent) {
        vaultLockedContinuation?.yield(event)
    }

    // MARK: - Wallet Events

    /// Publisher for wallet notifications (balance changes, incoming payments)
    private var walletNotificationContinuation: AsyncStream<WalletNotification>.Continuation?
    private var _walletNotificationStream: AsyncStream<WalletNotification>?

    var walletNotifications: AsyncStream<WalletNotification> {
        if let stream = _walletNotificationStream {
            return stream
        }
        let stream = AsyncStream<WalletNotification> { continuation in
            self.walletNotificationContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.walletNotificationContinuation = nil
                self?._walletNotificationStream = nil
            }
        }
        _walletNotificationStream = stream
        return stream
    }

    func emitWalletNotification(_ notification: WalletNotification) {
        walletNotificationContinuation?.yield(notification)
    }

    // MARK: - Migration Events

    /// Publisher for vault migration events
    private var migrationEventContinuation: AsyncStream<MigrationEvent>.Continuation?
    private var _migrationEventStream: AsyncStream<MigrationEvent>?

    var migrationEvents: AsyncStream<MigrationEvent> {
        if let stream = _migrationEventStream {
            return stream
        }
        let stream = AsyncStream<MigrationEvent> { continuation in
            self.migrationEventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.migrationEventContinuation = nil
                self?._migrationEventStream = nil
            }
        }
        _migrationEventStream = stream
        return stream
    }

    func emitMigrationEvent(_ event: MigrationEvent) {
        migrationEventContinuation?.yield(event)
    }

    // MARK: - Event Types

    /// Get available event types from the vault
    func getEventTypes() async throws -> [EventTypeInfo] {
        return []
    }
}

// MARK: - Vault Handler Response

/// Parsed response from a vault handler via sendAndAwaitResponse
struct VaultHandlerResponse {
    let requestId: String
    let success: Bool
    let result: [String: Any]?
    let error: String?
    let errorCode: String?

    /// Get a string value from the result
    func getString(_ key: String) -> String? {
        result?[key] as? String
    }

    /// Get an int value from the result
    func getInt(_ key: String) -> Int? {
        result?[key] as? Int
    }

    /// Get a bool value from the result
    func getBool(_ key: String) -> Bool? {
        result?[key] as? Bool
    }

    /// Get a dictionary from the result
    func getObject(_ key: String) -> [String: Any]? {
        result?[key] as? [String: Any]
    }

    /// Get an array from the result
    func getArray(_ key: String) -> [[String: Any]]? {
        result?[key] as? [[String: Any]]
    }
}

// MARK: - Event Models

/// Agent approval request from vault
struct AgentApprovalRequest: Codable {
    let requestId: String
    let agentName: String
    let agentType: String?
    let operation: String?
    let secretCategory: String?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case agentName = "agent_name"
        case agentType = "agent_type"
        case operation
        case secretCategory = "secret_category"
        case timestamp
    }
}

/// Device approval request from vault
struct DeviceApprovalRequest: Codable {
    let requestId: String
    let connectionId: String
    let deviceName: String
    let operation: String?
    let secretCategory: String?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case connectionId = "connection_id"
        case deviceName = "device_name"
        case operation
        case secretCategory = "secret_category"
        case timestamp
    }
}

/// Connection peer accepted notification
struct ConnectionPeerAccepted: Codable {
    let connectionId: String
    let peerGuid: String
    let peerAlias: String?
    let peerProfile: [String: String]?

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case peerGuid = "peer_guid"
        case peerAlias = "peer_alias"
        case peerProfile = "peer_profile"
    }
}

/// Connection status update from vault
struct ConnectionStatusUpdate: Codable {
    let type: String
    let connectionId: String
    let peerGuid: String?
    let peerAlias: String?

    enum CodingKeys: String, CodingKey {
        case type
        case connectionId = "connection_id"
        case peerGuid = "peer_guid"
        case peerAlias = "peer_alias"
    }
}

/// Feed notification from vault
struct FeedNotification: Codable {
    let type: String
    let eventId: String?
    let eventType: String?
    let title: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case eventType = "event_type"
        case title
        case message
    }
}

// MARK: - Request Types

struct ExecuteHandlerRequest: Encodable {
    let id: String
    let handlerId: String
    let payload: [String: Any]

    enum CodingKeys: String, CodingKey {
        case id
        case handlerId = "handler_id"
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(handlerId, forKey: .handlerId)
        // Encode payload as JSON string for simplicity
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            try container.encode(jsonString, forKey: .payload)
        }
    }
}

struct StatusRequest: Encodable {
    let id: String

    // No CodingKeys needed - field name matches JSON directly
}

// MARK: - Response Types

enum VaultResponse: Decodable {
    case handlerResult(HandlerResultResponse)
    case status(StatusResponse)
    case event(VaultEvent)
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let type = try? container.decode(String.self, forKey: .type) {
            switch type {
            case "handler_result":
                let result = try HandlerResultResponse(from: decoder)
                self = .handlerResult(result)
            case "status":
                let status = try StatusResponse(from: decoder)
                self = .status(status)
            case "event":
                let event = try VaultEvent(from: decoder)
                self = .event(event)
            default:
                self = .unknown
            }
        } else {
            self = .unknown
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
    }
}

struct HandlerResultResponse: Decodable {
    let id: String
    let success: Bool
    let result: [String: String]?
    let error: String?

    // No CodingKeys needed for id - matches JSON directly
    enum CodingKeys: String, CodingKey {
        case id
        case success
        case result
        case error
    }
}

struct StatusResponse: Decodable {
    let id: String
    let vaultStatus: String
    let health: String
    let activeHandlers: Int
    let lastActivity: String?

    enum CodingKeys: String, CodingKey {
        case id
        case vaultStatus = "vault_status"
        case health
        case activeHandlers = "active_handlers"
        case lastActivity = "last_activity"
    }
}

struct VaultEvent: Decodable {
    let eventId: String
    let eventType: String
    let timestamp: String
    let data: [String: String]?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventType = "event_type"
        case timestamp
        case data
    }
}

struct EventTypeInfo: Decodable {
    let id: String
    let name: String
    let description: String
}

// MARK: - Errors

/// Vault locked event — DEK is unavailable, requires PIN re-entry
struct VaultLockedEvent {
    let reason: String
    let messageType: String
}

/// Wallet notification from vault (balance update, incoming payment, etc.)
struct WalletNotification: Codable {
    let type: String
    let walletId: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case walletId = "wallet_id"
        case message
    }
}

/// Migration event from vault
struct MigrationEvent: Codable {
    let type: String
    let version: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case message
    }
}

// MARK: - Errors

enum OwnerSpaceError: LocalizedError {
    case notConnected
    case timeout
    case noResponse
    case invalidResponse
    case handlerError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to NATS"
        case .timeout:
            return "Request timed out"
        case .noResponse:
            return "No response received"
        case .invalidResponse:
            return "Invalid response format"
        case .handlerError(let message):
            return "Handler error: \(message)"
        }
    }
}
