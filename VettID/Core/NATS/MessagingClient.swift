import Foundation

// MARK: - Messaging Client

/// Client for vault-to-vault messaging via NATS
///
/// Uses OwnerSpaceClient.sendAndAwaitResponse() for reliable request-response
/// correlation by event_id.
///
/// Handlers:
/// - `message.get-transport-key` - Get transport key for encrypted messaging
/// - `message.list` - List message history for a connection
/// - `message.send` - Send encrypted message to peer vault
/// - `message.read-receipt` - Send read receipt to sender vault
/// - `profile.broadcast` - Broadcast profile updates to all connections
/// - `connection.notify-revoke` - Notify peer of connection revocation
final class MessagingClient {

    // MARK: - Properties

    private let ownerSpaceClient: OwnerSpaceClient
    private let defaultTimeout: TimeInterval = 30

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Transport Key

    /// Get the transport key for app-vault encrypted messaging.
    /// The vault derives this from the connection's shared secret.
    /// - Parameter connectionId: The connection ID
    /// - Returns: Raw key bytes (base64 decoded from vault response)
    func getTransportKey(connectionId: String) async throws -> Data {
        let response = try await sendAndAwait("message.get-transport-key", payload: [
            "connection_id": AnyCodableValue(connectionId)
        ])

        guard let keyBase64 = response.getString("transport_key") else {
            throw MessagingClientError.missingField("transport_key")
        }

        guard let keyData = Data(base64Encoded: keyBase64) else {
            throw MessagingClientError.invalidBase64("transport_key")
        }

        return keyData
    }

    // MARK: - Message History

    /// Load message history for a connection from the vault.
    /// - Parameters:
    ///   - connectionId: The connection ID
    ///   - limit: Maximum number of messages to return (default 50)
    /// - Returns: Array of stored messages
    func listMessages(connectionId: String, limit: Int = 50) async throws -> [StoredMessage] {
        let response = try await sendAndAwait("message.list", payload: [
            "connection_id": AnyCodableValue(connectionId),
            "limit": AnyCodableValue(limit)
        ])

        guard let messagesArray = response.getArray("messages") else {
            return []
        }

        return messagesArray.map { msg in
            StoredMessage(
                messageId: msg["message_id"] as? String ?? "",
                connectionId: connectionId,
                direction: msg["direction"] as? String ?? "",
                content: msg["content"] as? String ?? "",
                contentType: msg["content_type"] as? String ?? "text",
                status: msg["status"] as? String ?? "",
                sentAt: msg["sent_at"] as? String ?? "",
                senderGuid: msg["sender_guid"] as? String ?? ""
            )
        }
    }

    // MARK: - Send Message

    /// Send an encrypted message to a peer via their vault.
    /// - Parameters:
    ///   - connectionId: The connection ID (peer relationship)
    ///   - content: Plaintext content (optional, if vault handles encryption)
    ///   - encryptedContent: Base64-encoded encrypted message content (optional)
    ///   - nonce: Base64-encoded encryption nonce (optional)
    ///   - contentType: Message content type (default: "text")
    /// - Returns: Sent message result with server-assigned ID and timestamp
    func sendMessage(
        connectionId: String,
        content: String? = nil,
        encryptedContent: String? = nil,
        nonce: String? = nil,
        contentType: String = "text"
    ) async throws -> SentMessageResult {
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "content_type": AnyCodableValue(contentType)
        ]

        if let content = content {
            payload["content"] = AnyCodableValue(content)
        }
        if let encryptedContent = encryptedContent {
            payload["encrypted_content"] = AnyCodableValue(encryptedContent)
        }
        if let nonce = nonce {
            payload["nonce"] = AnyCodableValue(nonce)
        }

        #if DEBUG
        print("[MessagingClient] Sending message to connection: \(connectionId)")
        #endif

        let response = try await sendAndAwait("message.send", payload: payload)

        return SentMessageResult(
            messageId: response.getString("message_id") ?? "",
            timestamp: response.getString("timestamp") ?? response.getString("sent_at") ?? "",
            status: response.getString("status") ?? "sent"
        )
    }

    // MARK: - Read Receipts

    /// Send a read receipt to the sender vault.
    /// - Parameters:
    ///   - connectionId: The connection ID
    ///   - messageId: The message ID that was read
    /// - Returns: Whether the receipt was sent successfully
    func sendReadReceipt(connectionId: String, messageId: String) async throws -> Bool {
        #if DEBUG
        print("[MessagingClient] Sending read receipt for message: \(messageId)")
        #endif

        let response = try await sendAndAwait("message.read-receipt", payload: [
            "connection_id": AnyCodableValue(connectionId),
            "message_id": AnyCodableValue(messageId)
        ])

        return response.getBool("success") ?? true
    }

    // MARK: - Profile Broadcasting

    /// Broadcast a profile update to all active connections.
    /// - Parameters:
    ///   - displayName: Updated display name (optional)
    ///   - avatarUrl: Updated avatar URL (optional)
    ///   - status: Updated status message (optional)
    /// - Returns: Number of connections notified
    func broadcastProfileUpdate(
        displayName: String? = nil,
        avatarUrl: String? = nil,
        status: String? = nil
    ) async throws -> Int {
        var profileUpdates: [String: AnyCodableValue] = [:]
        if let displayName = displayName {
            profileUpdates["display_name"] = AnyCodableValue(displayName)
        }
        if let avatarUrl = avatarUrl {
            profileUpdates["avatar_url"] = AnyCodableValue(avatarUrl)
        }
        if let status = status {
            profileUpdates["status"] = AnyCodableValue(status)
        }

        let payload: [String: AnyCodableValue] = [
            "profile": AnyCodableValue(profileUpdates)
        ]

        #if DEBUG
        print("[MessagingClient] Broadcasting profile update")
        #endif

        let response = try await sendAndAwait("profile.broadcast", payload: payload)
        return response.getInt("notified_count") ?? 0
    }

    // MARK: - Connection Revocation

    /// Notify a peer that the connection has been revoked.
    /// - Parameters:
    ///   - connectionId: The connection ID being revoked
    ///   - reason: Reason for revocation (optional)
    /// - Returns: Whether the notification was sent successfully
    func notifyConnectionRevoked(connectionId: String, reason: String? = nil) async throws -> Bool {
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        if let reason = reason {
            payload["reason"] = AnyCodableValue(reason)
        }

        #if DEBUG
        print("[MessagingClient] Notifying connection revocation: \(connectionId)")
        #endif

        let response = try await sendAndAwait("connection.notify-revoke", payload: payload)
        return response.getBool("success") ?? true
    }

    // MARK: - Private Helpers

    /// Send a request via OwnerSpaceClient and await the response.
    /// Throws on failure or timeout.
    private func sendAndAwait(
        _ messageType: String,
        payload: [String: AnyCodableValue],
        timeout: TimeInterval? = nil
    ) async throws -> VaultHandlerResponse {
        #if DEBUG
        print("[MessagingClient] Sending \(messageType) request via OwnerSpaceClient")
        #endif

        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            messageType,
            payload: payload,
            timeout: timeout ?? defaultTimeout
        )

        guard response.success else {
            let errorMsg = response.error ?? "Unknown error"
            #if DEBUG
            print("[MessagingClient] \(messageType) error: \(errorMsg)")
            #endif
            throw MessagingClientError.requestFailed(messageType, errorMsg)
        }

        return response
    }
}

// MARK: - Data Models

/// Stored message from vault (decrypted)
struct StoredMessage: Codable, Identifiable {
    let messageId: String
    let connectionId: String
    let direction: String
    let content: String
    let contentType: String
    let status: String
    let sentAt: String
    let senderGuid: String

    var id: String { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case connectionId = "connection_id"
        case direction
        case content
        case contentType = "content_type"
        case status
        case sentAt = "sent_at"
        case senderGuid = "sender_guid"
    }
}

/// Result of sending a message (named to avoid conflict with SentMessage in MessageHandler)
struct SentMessageResult {
    /// Server-assigned message ID
    let messageId: String
    /// ISO 8601 timestamp when message was sent
    let timestamp: String
    /// Message status (sent, delivered, etc.)
    let status: String
}

// MARK: - Errors

enum MessagingClientError: LocalizedError {
    case requestFailed(String, String)
    case missingField(String)
    case invalidBase64(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let operation, let reason):
            return "Messaging \(operation) failed: \(reason)"
        case .missingField(let field):
            return "Missing required field in response: \(field)"
        case .invalidBase64(let field):
            return "Invalid base64 data in field: \(field)"
        }
    }
}
