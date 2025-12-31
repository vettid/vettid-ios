import XCTest
@testable import VettID

/// Unit tests for MessageHandler
final class MessageHandlerTests: XCTestCase {

    // MARK: - SentMessage Tests

    func testSentMessage_initialization() {
        let message = SentMessage(
            messageId: "msg-12345",
            connectionId: "conn-abc",
            timestamp: "2025-12-31T10:30:00Z",
            status: "sent"
        )

        XCTAssertEqual(message.messageId, "msg-12345")
        XCTAssertEqual(message.connectionId, "conn-abc")
        XCTAssertEqual(message.timestamp, "2025-12-31T10:30:00Z")
        XCTAssertEqual(message.status, "sent")
    }

    func testSentMessage_differentStatuses() {
        let statuses = ["sent", "delivered", "read", "failed"]

        for status in statuses {
            let message = SentMessage(
                messageId: "msg",
                connectionId: "conn",
                timestamp: "",
                status: status
            )
            XCTAssertEqual(message.status, status)
        }
    }

    // MARK: - ReadReceiptResult Tests

    func testReadReceiptResult_fullInitialization() {
        let result = ReadReceiptResult(
            messageId: "msg-receipt",
            readAt: "2025-12-31T11:00:00Z",
            sent: true
        )

        XCTAssertEqual(result.messageId, "msg-receipt")
        XCTAssertEqual(result.readAt, "2025-12-31T11:00:00Z")
        XCTAssertTrue(result.sent)
    }

    func testReadReceiptResult_withoutTimestamp() {
        let result = ReadReceiptResult(
            messageId: "msg-no-time",
            readAt: nil,
            sent: true
        )

        XCTAssertEqual(result.messageId, "msg-no-time")
        XCTAssertNil(result.readAt)
        XCTAssertTrue(result.sent)
    }

    func testReadReceiptResult_failed() {
        let result = ReadReceiptResult(
            messageId: "msg-failed",
            readAt: nil,
            sent: false
        )

        XCTAssertFalse(result.sent)
    }

    // MARK: - ProfileBroadcastResult Tests

    func testProfileBroadcastResult_fullSuccess() {
        let result = ProfileBroadcastResult(
            connectionsCount: 10,
            successCount: 10,
            failedConnectionIds: [],
            broadcastAt: "2025-12-31T12:00:00Z"
        )

        XCTAssertEqual(result.connectionsCount, 10)
        XCTAssertEqual(result.successCount, 10)
        XCTAssertTrue(result.failedConnectionIds.isEmpty)
        XCTAssertNotNil(result.broadcastAt)
    }

    func testProfileBroadcastResult_partialSuccess() {
        let result = ProfileBroadcastResult(
            connectionsCount: 5,
            successCount: 3,
            failedConnectionIds: ["conn-1", "conn-2"],
            broadcastAt: "2025-12-31T12:00:00Z"
        )

        XCTAssertEqual(result.connectionsCount, 5)
        XCTAssertEqual(result.successCount, 3)
        XCTAssertEqual(result.failedConnectionIds.count, 2)
        XCTAssertTrue(result.failedConnectionIds.contains("conn-1"))
        XCTAssertTrue(result.failedConnectionIds.contains("conn-2"))
    }

    func testProfileBroadcastResult_noConnections() {
        let result = ProfileBroadcastResult(
            connectionsCount: 0,
            successCount: 0,
            failedConnectionIds: [],
            broadcastAt: nil
        )

        XCTAssertEqual(result.connectionsCount, 0)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertNil(result.broadcastAt)
    }

    // MARK: - IncomingReadReceipt Tests

    func testIncomingReadReceipt_decoding() throws {
        let json = """
        {
            "message_id": "msg-123",
            "connection_id": "conn-abc",
            "read_at": "2025-12-31T14:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        let receipt = try decoder.decode(IncomingReadReceipt.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(receipt.messageId, "msg-123")
        XCTAssertEqual(receipt.connectionId, "conn-abc")
        XCTAssertEqual(receipt.readAt, "2025-12-31T14:00:00Z")
    }

    func testIncomingReadReceipt_codingKeys() throws {
        // Verify snake_case to camelCase mapping
        let json = """
        {
            "message_id": "test-msg",
            "connection_id": "test-conn",
            "read_at": "2025-12-31T15:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        let receipt = try decoder.decode(IncomingReadReceipt.self, from: json.data(using: .utf8)!)

        // Verify CodingKeys mapped correctly
        XCTAssertEqual(receipt.messageId, "test-msg")
        XCTAssertEqual(receipt.connectionId, "test-conn")
    }

    // MARK: - IncomingProfileUpdate Tests

    func testIncomingProfileUpdate_decoding() throws {
        let json = """
        {
            "connection_id": "conn-profile",
            "fields": {
                "display_name": "New Name",
                "bio": "Updated bio"
            },
            "updated_at": "2025-12-31T16:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        let update = try decoder.decode(IncomingProfileUpdate.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(update.connectionId, "conn-profile")
        XCTAssertEqual(update.fields["display_name"], "New Name")
        XCTAssertEqual(update.fields["bio"], "Updated bio")
        XCTAssertEqual(update.updatedAt, "2025-12-31T16:00:00Z")
    }

    func testIncomingProfileUpdate_emptyFields() throws {
        let json = """
        {
            "connection_id": "conn-empty",
            "fields": {},
            "updated_at": "2025-12-31T17:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        let update = try decoder.decode(IncomingProfileUpdate.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(update.connectionId, "conn-empty")
        XCTAssertTrue(update.fields.isEmpty)
    }

    // MARK: - IncomingConnectionRevoked Tests

    func testIncomingConnectionRevoked_withReason() throws {
        let json = """
        {
            "connection_id": "conn-revoked",
            "revoked_at": "2025-12-31T18:00:00Z",
            "reason": "User requested"
        }
        """

        let decoder = JSONDecoder()
        let revoked = try decoder.decode(IncomingConnectionRevoked.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(revoked.connectionId, "conn-revoked")
        XCTAssertEqual(revoked.revokedAt, "2025-12-31T18:00:00Z")
        XCTAssertEqual(revoked.reason, "User requested")
    }

    func testIncomingConnectionRevoked_withoutReason() throws {
        let json = """
        {
            "connection_id": "conn-no-reason",
            "revoked_at": "2025-12-31T19:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        let revoked = try decoder.decode(IncomingConnectionRevoked.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(revoked.connectionId, "conn-no-reason")
        XCTAssertNil(revoked.reason)
    }

    // MARK: - VaultNotification Tests

    func testVaultNotification_decoding() throws {
        let json = """
        {
            "type": "profile-update",
            "timestamp": "2025-12-31T20:00:00Z",
            "data": {
                "connection_id": "conn-notif",
                "fields": {"bio": "Hello"},
                "updated_at": "2025-12-31T20:00:00Z"
            }
        }
        """

        let decoder = JSONDecoder()
        let notification = try decoder.decode(VaultNotification<IncomingProfileUpdate>.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(notification.type, "profile-update")
        XCTAssertEqual(notification.timestamp, "2025-12-31T20:00:00Z")
        XCTAssertEqual(notification.data.connectionId, "conn-notif")
        XCTAssertEqual(notification.data.fields["bio"], "Hello")
    }

    func testVaultNotification_readReceiptData() throws {
        let json = """
        {
            "type": "read-receipt",
            "timestamp": "2025-12-31T21:00:00Z",
            "data": {
                "message_id": "msg-xyz",
                "connection_id": "conn-xyz",
                "read_at": "2025-12-31T21:00:00Z"
            }
        }
        """

        let decoder = JSONDecoder()
        let notification = try decoder.decode(VaultNotification<IncomingReadReceipt>.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(notification.type, "read-receipt")
        XCTAssertEqual(notification.data.messageId, "msg-xyz")
    }

    // MARK: - MessageHandlerError Tests

    func testMessageHandlerError_sendFailedDescription() {
        let error = MessageHandlerError.sendFailed("Network error")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("send"))
        XCTAssertTrue(error.errorDescription!.contains("Network error"))
    }

    func testMessageHandlerError_readReceiptFailedDescription() {
        let error = MessageHandlerError.readReceiptFailed("Connection closed")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("read receipt"))
        XCTAssertTrue(error.errorDescription!.contains("Connection closed"))
    }

    func testMessageHandlerError_broadcastFailedDescription() {
        let error = MessageHandlerError.broadcastFailed("Timeout")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("broadcast"))
        XCTAssertTrue(error.errorDescription!.contains("Timeout"))
    }

    func testMessageHandlerError_revocationNotifyFailedDescription() {
        let error = MessageHandlerError.revocationNotifyFailed("Peer offline")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("revocation"))
        XCTAssertTrue(error.errorDescription!.contains("Peer offline"))
    }

    func testMessageHandlerError_invalidResponseDescription() {
        let error = MessageHandlerError.invalidResponse

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }

    func testMessageHandlerError_decryptionFailedDescription() {
        let error = MessageHandlerError.decryptionFailed("Invalid key")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("decrypt"))
        XCTAssertTrue(error.errorDescription!.contains("Invalid key"))
    }

    func testMessageHandlerError_switchCoverage() {
        let errors: [MessageHandlerError] = [
            .sendFailed("test"),
            .readReceiptFailed("test"),
            .broadcastFailed("test"),
            .revocationNotifyFailed("test"),
            .invalidResponse,
            .decryptionFailed("test")
        ]

        for error in errors {
            switch error {
            case .sendFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .readReceiptFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .broadcastFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .revocationNotifyFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .invalidResponse:
                XCTAssertTrue(true)
            case .decryptionFailed(let reason):
                XCTAssertEqual(reason, "test")
            }
        }
    }

    // MARK: - Message Content Type Tests

    func testContentType_values() {
        let contentTypes = ["text", "image", "file", "audio", "video"]

        for contentType in contentTypes {
            XCTAssertFalse(contentType.isEmpty)
        }
    }

    // MARK: - Base64 Encryption Data Tests

    func testEncryptedContent_base64Format() {
        let plaintext = "Hello, World!"
        let plaintextData = plaintext.data(using: .utf8)!
        let base64Content = plaintextData.base64EncodedString()

        // Verify base64 encoding is valid
        XCTAssertNotNil(Data(base64Encoded: base64Content))

        // Verify decoded matches original
        let decodedData = Data(base64Encoded: base64Content)!
        let decodedString = String(data: decodedData, encoding: .utf8)
        XCTAssertEqual(decodedString, plaintext)
    }

    func testNonce_base64Format() {
        // Create a 12-byte nonce (typical for ChaCha20-Poly1305)
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 {
            nonceBytes[i] = UInt8.random(in: 0...255)
        }
        let nonce = Data(nonceBytes)
        let base64Nonce = nonce.base64EncodedString()

        // Verify base64 encoding is valid
        XCTAssertNotNil(Data(base64Encoded: base64Nonce))

        // Verify decoded has correct length
        let decodedNonce = Data(base64Encoded: base64Nonce)!
        XCTAssertEqual(decodedNonce.count, 12)
    }

    // MARK: - Timestamp Format Tests

    func testTimestamp_ISO8601Format() {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let timestamp = formatter.string(from: now)

        // Verify format
        XCTAssertTrue(timestamp.contains("T"))
        XCTAssertTrue(timestamp.hasSuffix("Z") || timestamp.contains("+") || timestamp.contains("-"))

        // Verify parsing
        let parsedDate = formatter.date(from: timestamp)
        XCTAssertNotNil(parsedDate)
    }
}
