import XCTest
@testable import VettID

/// Tests for Connection-related types
final class ConnectionTypesTests: XCTestCase {

    // MARK: - Connection Tests

    func testConnection_decoding() throws {
        let json = """
        {
            "id": "conn-123",
            "peer_guid": "guid-456",
            "peer_display_name": "Test User",
            "peer_avatar_url": "https://example.com/avatar.png",
            "status": "active",
            "created_at": "2025-01-01T12:00:00Z",
            "last_message_at": "2025-01-02T15:30:00Z",
            "unread_count": 5
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let connection = try decoder.decode(Connection.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(connection.id, "conn-123")
        XCTAssertEqual(connection.peerGuid, "guid-456")
        XCTAssertEqual(connection.peerDisplayName, "Test User")
        XCTAssertEqual(connection.peerAvatarUrl, "https://example.com/avatar.png")
        XCTAssertEqual(connection.status, .active)
        XCTAssertEqual(connection.unreadCount, 5)
        XCTAssertNotNil(connection.lastMessageAt)
    }

    func testConnectionStatus_allCases() {
        XCTAssertEqual(ConnectionStatus.pending.rawValue, "pending")
        XCTAssertEqual(ConnectionStatus.active.rawValue, "active")
        XCTAssertEqual(ConnectionStatus.revoked.rawValue, "revoked")
    }

    // MARK: - ConnectionInvitation Tests

    func testConnectionInvitation_decoding() throws {
        let json = """
        {
            "invitation_id": "inv-123",
            "invitation_code": "ABC123",
            "qr_code_data": "vettid://invite/ABC123",
            "deep_link_url": "https://vettid.com/invite/ABC123",
            "expires_at": "2025-01-01T13:00:00Z",
            "creator_display_name": "Test Creator"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let invitation = try decoder.decode(ConnectionInvitation.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(invitation.invitationId, "inv-123")
        XCTAssertEqual(invitation.invitationCode, "ABC123")
        XCTAssertEqual(invitation.qrCodeData, "vettid://invite/ABC123")
        XCTAssertEqual(invitation.deepLinkUrl, "https://vettid.com/invite/ABC123")
        XCTAssertEqual(invitation.creatorDisplayName, "Test Creator")
    }

    // MARK: - Message Tests

    func testMessage_decoding() throws {
        let json = """
        {
            "id": "msg-123",
            "connection_id": "conn-456",
            "sender_id": "user-789",
            "content": "Hello world",
            "content_type": "text",
            "sent_at": "2025-01-01T12:00:00Z",
            "received_at": "2025-01-01T12:00:01Z",
            "read_at": null,
            "status": "delivered"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(Message.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(message.id, "msg-123")
        XCTAssertEqual(message.connectionId, "conn-456")
        XCTAssertEqual(message.senderId, "user-789")
        XCTAssertEqual(message.content, "Hello world")
        XCTAssertEqual(message.contentType, .text)
        XCTAssertEqual(message.status, .delivered)
        XCTAssertNotNil(message.receivedAt)
        XCTAssertNil(message.readAt)
    }

    func testMessageContentType_allCases() {
        XCTAssertEqual(MessageContentType.text.rawValue, "text")
        XCTAssertEqual(MessageContentType.image.rawValue, "image")
        XCTAssertEqual(MessageContentType.file.rawValue, "file")
    }

    func testMessageStatus_allCases() {
        XCTAssertEqual(MessageStatus.sending.rawValue, "sending")
        XCTAssertEqual(MessageStatus.sent.rawValue, "sent")
        XCTAssertEqual(MessageStatus.delivered.rawValue, "delivered")
        XCTAssertEqual(MessageStatus.read.rawValue, "read")
        XCTAssertEqual(MessageStatus.failed.rawValue, "failed")
    }

    // MARK: - Profile Tests

    func testProfile_decoding() throws {
        let json = """
        {
            "guid": "user-123",
            "display_name": "Test User",
            "avatar_url": "https://example.com/avatar.png",
            "bio": "Hello world",
            "location": "San Francisco",
            "last_updated": "2025-01-01T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(Profile.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(profile.guid, "user-123")
        XCTAssertEqual(profile.displayName, "Test User")
        XCTAssertEqual(profile.avatarUrl, "https://example.com/avatar.png")
        XCTAssertEqual(profile.bio, "Hello world")
        XCTAssertEqual(profile.location, "San Francisco")
    }

    func testProfile_decodingWithNulls() throws {
        let json = """
        {
            "guid": "user-123",
            "display_name": "Test User",
            "avatar_url": null,
            "bio": null,
            "location": null,
            "last_updated": "2025-01-01T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(Profile.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(profile.guid, "user-123")
        XCTAssertEqual(profile.displayName, "Test User")
        XCTAssertNil(profile.avatarUrl)
        XCTAssertNil(profile.bio)
        XCTAssertNil(profile.location)
    }

    // MARK: - MessageGroup Tests

    func testMessageGroup_initialization() {
        let date = Date()
        let messages = [
            Message(
                id: "1",
                connectionId: "conn",
                senderId: "user",
                content: "Hello",
                contentType: .text,
                sentAt: date,
                receivedAt: nil,
                readAt: nil,
                status: .sent
            )
        ]

        let group = MessageGroup(date: date, messages: messages)

        XCTAssertEqual(group.messages.count, 1)
        XCTAssertEqual(group.date, date)
    }
}
