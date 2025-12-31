import Foundation

/// Handler for vault-to-vault messaging via NATS
///
/// Messages flow: App → Vault (OwnerSpace.forVault) → Peer Vault (MessageSpace.forOwner) → Peer App
///
/// NATS Topics (App → Vault):
/// - `message.send` - Send encrypted message to peer vault
/// - `message.read-receipt` - Send read receipt to sender vault
/// - `profile.broadcast` - Broadcast profile updates to all connections
/// - `connection.notify-revoke` - Notify peer of connection revocation
///
/// Incoming Notifications (Vault → App on forApp.*):
/// - `forApp.new-message` - New message from peer
/// - `forApp.read-receipt` - Peer read your message
/// - `forApp.profile-update` - Profile update from peer
/// - `forApp.connection-revoked` - Connection revoked by peer
actor MessageHandler {

    // MARK: - Dependencies

    private let vaultResponseHandler: VaultResponseHandler

    // MARK: - Configuration

    private let defaultTimeout: TimeInterval = 30

    // MARK: - Initialization

    init(vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    // MARK: - Sending Messages

    /// Send an encrypted message to a peer via their vault
    /// - Parameters:
    ///   - connectionId: The connection ID (peer relationship)
    ///   - encryptedContent: Base64-encoded encrypted message content
    ///   - nonce: Base64-encoded encryption nonce
    ///   - contentType: Message content type (default: "text")
    /// - Returns: Sent message info with server-assigned ID and timestamp
    func sendMessage(
        connectionId: String,
        encryptedContent: String,
        nonce: String,
        contentType: String = "text"
    ) async throws -> SentMessage {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "encrypted_content": AnyCodableValue(encryptedContent),
            "nonce": AnyCodableValue(nonce),
            "content_type": AnyCodableValue(contentType)
        ]

        #if DEBUG
        print("[MessageHandler] Sending message to connection: \(connectionId)")
        #endif

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "message.send",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw MessageHandlerError.sendFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw MessageHandlerError.invalidResponse
        }

        return SentMessage(
            messageId: result["message_id"]?.value as? String ?? "",
            connectionId: connectionId,
            timestamp: result["sent_at"]?.value as? String ?? result["timestamp"]?.value as? String ?? "",
            status: result["status"]?.value as? String ?? "sent"
        )
    }

    // MARK: - Read Receipts

    /// Send a read receipt to the sender vault
    /// - Parameters:
    ///   - connectionId: The connection ID
    ///   - messageId: The message ID that was read
    /// - Returns: Read receipt confirmation
    func sendReadReceipt(
        connectionId: String,
        messageId: String
    ) async throws -> ReadReceiptResult {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "message_id": AnyCodableValue(messageId)
        ]

        #if DEBUG
        print("[MessageHandler] Sending read receipt for message: \(messageId)")
        #endif

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "message.read-receipt",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw MessageHandlerError.readReceiptFailed(response.error ?? "Unknown error")
        }

        let result = response.result
        return ReadReceiptResult(
            messageId: result?["message_id"]?.value as? String ?? messageId,
            readAt: result?["read_at"]?.value as? String,
            sent: result?["sent"]?.value as? Bool ?? true
        )
    }

    // MARK: - Profile Broadcasting

    /// Broadcast a profile update to all active connections
    /// - Parameters:
    ///   - fields: Optional list of field names to broadcast (empty = all fields)
    /// - Returns: Broadcast result with count of notified connections
    func broadcastProfileUpdate(fields: [String]? = nil) async throws -> ProfileBroadcastResult {
        var payload: [String: AnyCodableValue] = [:]

        if let fields = fields, !fields.isEmpty {
            payload["fields"] = AnyCodableValue(fields)
        }

        #if DEBUG
        print("[MessageHandler] Broadcasting profile update")
        #endif

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "profile.broadcast",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw MessageHandlerError.broadcastFailed(response.error ?? "Unknown error")
        }

        guard let result = response.result else {
            throw MessageHandlerError.invalidResponse
        }

        return ProfileBroadcastResult(
            connectionsCount: result["connections_count"]?.value as? Int ?? 0,
            successCount: result["success_count"]?.value as? Int ?? 0,
            failedConnectionIds: result["failed_connection_ids"]?.value as? [String] ?? [],
            broadcastAt: result["broadcast_at"]?.value as? String
        )
    }

    // MARK: - Connection Revocation

    /// Notify a peer that the connection has been revoked
    /// - Parameters:
    ///   - connectionId: The connection ID being revoked
    /// - Returns: Success indicator
    func notifyConnectionRevoked(connectionId: String) async throws -> Bool {
        let payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId)
        ]

        #if DEBUG
        print("[MessageHandler] Notifying connection revocation: \(connectionId)")
        #endif

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "connection.notify-revoke",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw MessageHandlerError.revocationNotifyFailed(response.error ?? "Unknown error")
        }

        return response.result?["success"]?.value as? Bool ?? true
    }
}

// MARK: - Outgoing Message Types

/// Result of sending a message
struct SentMessage {
    /// Server-assigned message ID
    let messageId: String
    /// Connection ID the message was sent to
    let connectionId: String
    /// ISO 8601 timestamp when message was sent
    let timestamp: String
    /// Message status (sent, delivered, etc.)
    let status: String
}

/// Result of sending a read receipt
struct ReadReceiptResult {
    /// The message ID that was marked as read
    let messageId: String
    /// ISO 8601 timestamp when the read receipt was sent
    let readAt: String?
    /// Whether the receipt was sent successfully
    let sent: Bool
}

/// Result of broadcasting profile update
struct ProfileBroadcastResult {
    /// Total number of connections
    let connectionsCount: Int
    /// Number of connections successfully notified
    let successCount: Int
    /// Connection IDs that failed to receive the broadcast
    let failedConnectionIds: [String]
    /// ISO 8601 timestamp of the broadcast
    let broadcastAt: String?
}

// MARK: - Incoming Message Types
//
// Note: IncomingMessage is defined in MessageSubscriber.swift
// These additional types are for NATS notification handling

/// Read receipt from a peer (received on forApp.read-receipt)
struct IncomingReadReceipt: Decodable {
    /// The message ID that was read
    let messageId: String
    /// Connection ID
    let connectionId: String
    /// ISO 8601 timestamp when message was read
    let readAt: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case connectionId = "connection_id"
        case readAt = "read_at"
    }
}

/// Profile update from a peer (received on forApp.profile-update)
struct IncomingProfileUpdate: Decodable {
    /// Connection ID
    let connectionId: String
    /// Updated fields
    let fields: [String: String]
    /// ISO 8601 timestamp of update
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case fields
        case updatedAt = "updated_at"
    }
}

/// Connection revocation notice from a peer (received on forApp.connection-revoked)
struct IncomingConnectionRevoked: Decodable {
    /// The connection ID that was revoked
    let connectionId: String
    /// ISO 8601 timestamp when revoked
    let revokedAt: String
    /// Reason for revocation (if provided)
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case revokedAt = "revoked_at"
        case reason
    }
}

// MARK: - Notification Envelope

/// Envelope for incoming notifications on forApp.* topics
struct VaultNotification<T: Decodable>: Decodable {
    let type: String
    let timestamp: String
    let data: T
}

// MARK: - Errors

enum MessageHandlerError: LocalizedError {
    case sendFailed(String)
    case readReceiptFailed(String)
    case broadcastFailed(String)
    case revocationNotifyFailed(String)
    case invalidResponse
    case decryptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sendFailed(let reason):
            return "Failed to send message: \(reason)"
        case .readReceiptFailed(let reason):
            return "Failed to send read receipt: \(reason)"
        case .broadcastFailed(let reason):
            return "Failed to broadcast profile: \(reason)"
        case .revocationNotifyFailed(let reason):
            return "Failed to notify connection revocation: \(reason)"
        case .invalidResponse:
            return "Invalid response from vault"
        case .decryptionFailed(let reason):
            return "Failed to decrypt message: \(reason)"
        }
    }
}
