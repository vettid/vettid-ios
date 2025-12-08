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
        let requestId = UUID().uuidString
        let message = VaultEventMessage(
            requestId: requestId,
            eventType: event.type,
            payload: event.payload,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        try await ownerSpaceClient.sendToVault(message, topic: "events.\(event.type)")

        return requestId
    }

    /// Submit raw event data
    func submitRawEvent(
        type: String,
        payload: [String: AnyCodableValue]
    ) async throws -> String {
        let requestId = UUID().uuidString
        let message = VaultEventMessage(
            requestId: requestId,
            eventType: type,
            payload: payload,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        try await ownerSpaceClient.sendToVault(message, topic: "events.\(type)")

        return requestId
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
    case retrieveSecret(secretId: String)
    case storeSecret(secretId: String, data: Data)
    case custom(type: String, payload: [String: AnyCodableValue])

    var type: String {
        switch self {
        case .sendMessage: return "messaging.send"
        case .updateProfile: return "profile.update"
        case .createConnection: return "connection.create"
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
    let requestId: String
    let eventType: String
    let payload: [String: AnyCodableValue]
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case eventType = "event_type"
        case payload
        case timestamp
    }
}

struct VaultEventResponse: Decodable {
    let requestId: String
    let status: String  // "success", "error"
    let result: [String: AnyCodableValue]?
    let error: String?
    let processedAt: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case status
        case result
        case error
        case processedAt = "processed_at"
    }

    var isSuccess: Bool {
        status == "success"
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
