import Foundation

/// Client for submitting events to the vault via NATS
///
/// This provides a higher-level interface for event submission
/// with automatic request ID generation and response subscription.
final class VaultEventClient {

    // MARK: - Properties

    private let ownerSpaceClient: OwnerSpaceClient

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Event Submission

    /// Submit an event to the vault for processing
    func submitEvent(_ event: VaultEventType) async throws -> String {
        let id = UUID().uuidString
        let message = VaultEventMessage(
            id: id,
            type: event.type,
            payload: event.payload,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Topic is just the event type (no "events." prefix per Android/backend alignment)
        try await ownerSpaceClient.sendToVault(message, topic: event.type)

        return id
    }

    /// Submit raw event data
    func submitRawEvent(
        type: String,
        payload: [String: AnyCodableValue]
    ) async throws -> String {
        let id = UUID().uuidString
        let message = VaultEventMessage(
            id: id,
            type: type,
            payload: payload,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Topic is just the event type (no "events." prefix per Android/backend alignment)
        try await ownerSpaceClient.sendToVault(message, topic: type)

        return id
    }

    // MARK: - Response Subscription

    /// Subscribe to event responses from vault
    func subscribeToResponses() async throws -> AsyncStream<VaultEventResponse> {
        try await ownerSpaceClient.subscribeToVault(
            topic: "responses.>",
            type: VaultEventResponse.self
        )
    }

    /// Subscribe to responses for a specific event type
    func subscribeToResponses(forEventType type: String) async throws -> AsyncStream<VaultEventResponse> {
        try await ownerSpaceClient.subscribeToVault(
            topic: "responses.\(type)",
            type: VaultEventResponse.self
        )
    }
}

// MARK: - Event Types

/// Predefined vault event types
enum VaultEventType {
    case sendMessage(recipient: String, content: String)
    case updateProfile(updates: [String: Any])
    case createConnection(inviteCode: String)
    case acceptConnection(requestId: String)
    case declineConnection(requestId: String)
    case approveAuth(requestId: String)
    case denyAuth(requestId: String)
    case retrieveSecret(secretId: String)
    case storeSecret(secretId: String, data: Data)
    case custom(type: String, payload: [String: AnyCodableValue])

    var type: String {
        switch self {
        case .sendMessage: return "messaging.send"
        case .updateProfile: return "profile.update"
        case .createConnection: return "connection.create"
        case .acceptConnection: return "connection.accept"
        case .declineConnection: return "connection.decline"
        case .approveAuth: return "auth.approve"
        case .denyAuth: return "auth.deny"
        case .retrieveSecret: return "secret.retrieve"
        case .storeSecret: return "secret.store"
        case .custom(let type, _): return type
        }
    }

    var payload: [String: AnyCodableValue] {
        switch self {
        case .sendMessage(let recipient, let content):
            return [
                "recipient": AnyCodableValue(recipient),
                "content": AnyCodableValue(content)
            ]
        case .updateProfile(let updates):
            return updates.compactMapValues { AnyCodableValue($0) }
        case .createConnection(let inviteCode):
            return ["invite_code": AnyCodableValue(inviteCode)]
        case .acceptConnection(let requestId):
            return ["request_id": AnyCodableValue(requestId)]
        case .declineConnection(let requestId):
            return ["request_id": AnyCodableValue(requestId)]
        case .approveAuth(let requestId):
            return ["request_id": AnyCodableValue(requestId)]
        case .denyAuth(let requestId):
            return ["request_id": AnyCodableValue(requestId)]
        case .retrieveSecret(let secretId):
            return ["secret_id": AnyCodableValue(secretId)]
        case .storeSecret(let secretId, let data):
            return [
                "secret_id": AnyCodableValue(secretId),
                "data": AnyCodableValue(data.base64EncodedString())
            ]
        case .custom(_, let payload):
            return payload
        }
    }
}

// MARK: - Message Types

struct VaultEventMessage: Encodable {
    let id: String
    let type: String
    let payload: [String: AnyCodableValue]
    let timestamp: String

    // No CodingKeys needed - field names match JSON directly
}

struct VaultEventResponse: Decodable {
    let eventId: String?      // Primary field name from vault
    let id: String?           // Fallback field name
    let success: Bool
    let timestamp: String
    let result: [String: AnyCodableValue]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case id
        case success
        case timestamp
        case result
        case error
    }

    /// Get the response ID (prefers eventId, falls back to id)
    var responseId: String {
        eventId ?? id ?? ""
    }

    var isSuccess: Bool {
        success
    }
}

// MARK: - AnyCodableValue

/// A type-erased codable value for flexible payload handling
struct AnyCodableValue: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodableValue].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodableValue($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodableValue($0) })
        default:
            try container.encodeNil()
        }
    }
}
