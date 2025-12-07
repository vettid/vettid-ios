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
        let requestId = UUID().uuidString
        let message = ExecuteHandlerRequest(
            requestId: requestId,
            handlerId: handlerId,
            payload: payload
        )

        try await sendToVault(message, topic: "execute")
        return requestId
    }

    /// Request vault status
    func requestStatus() async throws -> String {
        let requestId = UUID().uuidString
        let message = StatusRequest(requestId: requestId)

        try await sendToVault(message, topic: "status")
        return requestId
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

    /// Subscribe to vault events
    func subscribeToEvents() async throws -> AsyncStream<VaultEvent> {
        return try await subscribeToVault(topic: "events", type: VaultEvent.self)
    }

    // MARK: - Request/Response Pattern

    /// Send a request and wait for a response with timeout
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

    // MARK: - Event Types

    /// Get available event types from the vault
    func getEventTypes() async throws -> [EventTypeInfo] {
        // This would typically use request/reply or fetch from a stream
        // For now, return empty array
        return []
    }
}

// MARK: - Request Types

struct ExecuteHandlerRequest: Encodable {
    let requestId: String
    let handlerId: String
    let payload: [String: Any]

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case handlerId = "handler_id"
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(handlerId, forKey: .handlerId)
        // Encode payload as JSON string for simplicity
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            try container.encode(jsonString, forKey: .payload)
        }
    }
}

struct StatusRequest: Encodable {
    let requestId: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
    }
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
    let requestId: String
    let success: Bool
    let result: [String: String]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case success
        case result
        case error
    }
}

struct StatusResponse: Decodable {
    let requestId: String
    let vaultStatus: String
    let health: String
    let activeHandlers: Int
    let lastActivity: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
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
