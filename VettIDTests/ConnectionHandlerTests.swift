import XCTest
@testable import VettID

/// Unit tests for ConnectionHandler
final class ConnectionHandlerTests: XCTestCase {

    // MARK: - ConnectionStatus Tests

    func testConnectionStatus_rawValues() {
        XCTAssertEqual(ConnectionStatus.pending.rawValue, "pending")
        XCTAssertEqual(ConnectionStatus.active.rawValue, "active")
        XCTAssertEqual(ConnectionStatus.revoked.rawValue, "revoked")
    }

    func testConnectionStatus_initFromRawValue() {
        XCTAssertEqual(ConnectionStatus(rawValue: "pending"), .pending)
        XCTAssertEqual(ConnectionStatus(rawValue: "active"), .active)
        XCTAssertEqual(ConnectionStatus(rawValue: "revoked"), .revoked)
        XCTAssertNil(ConnectionStatus(rawValue: "unknown"))
        XCTAssertNil(ConnectionStatus(rawValue: ""))
    }

    func testConnectionStatus_codable() throws {
        let status = ConnectionStatus.active

        let encoder = JSONEncoder()
        let data = try encoder.encode(status)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ConnectionStatus.self, from: data)

        XCTAssertEqual(decoded, status)
    }

    // MARK: - ConnectionInviteResult Tests

    func testConnectionInviteResult_fullInitialization() {
        let expiryDate = Date().addingTimeInterval(3600) // 1 hour from now
        let result = ConnectionInviteResult(
            code: "INV-ABC123",
            publicKey: "base64EncodedKey==",
            expiresAt: expiryDate
        )

        XCTAssertEqual(result.code, "INV-ABC123")
        XCTAssertEqual(result.publicKey, "base64EncodedKey==")
        XCTAssertNotNil(result.expiresAt)
    }

    func testConnectionInviteResult_minimalInitialization() {
        let result = ConnectionInviteResult(
            code: "INV-XYZ",
            publicKey: nil,
            expiresAt: nil
        )

        XCTAssertEqual(result.code, "INV-XYZ")
        XCTAssertNil(result.publicKey)
        XCTAssertNil(result.expiresAt)
    }

    // MARK: - ConnectionCredentials Tests

    func testConnectionCredentials_fullInitialization() {
        let sharedSecret = "secret-data".data(using: .utf8)!
        let credentials = ConnectionCredentials(
            peerId: "peer-123",
            publicKey: "peerPublicKey==",
            sharedSecret: sharedSecret,
            createdAt: Date()
        )

        XCTAssertEqual(credentials.peerId, "peer-123")
        XCTAssertEqual(credentials.publicKey, "peerPublicKey==")
        XCTAssertEqual(credentials.sharedSecret, sharedSecret)
        XCTAssertNotNil(credentials.createdAt)
    }

    func testConnectionCredentials_minimalInitialization() {
        let credentials = ConnectionCredentials(
            peerId: "peer-456",
            publicKey: nil,
            sharedSecret: nil,
            createdAt: nil
        )

        XCTAssertEqual(credentials.peerId, "peer-456")
        XCTAssertNil(credentials.publicKey)
        XCTAssertNil(credentials.sharedSecret)
        XCTAssertNil(credentials.createdAt)
    }

    // MARK: - ConnectionRotationResult Tests

    func testConnectionRotationResult_initialization() {
        let rotatedAt = Date()
        let result = ConnectionRotationResult(
            connectionId: "conn-789",
            newPublicKey: "newKey==",
            rotatedAt: rotatedAt
        )

        XCTAssertEqual(result.connectionId, "conn-789")
        XCTAssertEqual(result.newPublicKey, "newKey==")
        XCTAssertEqual(result.rotatedAt, rotatedAt)
    }

    func testConnectionRotationResult_withoutNewKey() {
        let result = ConnectionRotationResult(
            connectionId: "conn-abc",
            newPublicKey: nil,
            rotatedAt: Date()
        )

        XCTAssertEqual(result.connectionId, "conn-abc")
        XCTAssertNil(result.newPublicKey)
    }

    // MARK: - VaultConnectionInfo Tests

    func testVaultConnectionInfo_fullInitialization() {
        let createdAt = Date()
        let lastActivityAt = Date()
        let info = VaultConnectionInfo(
            id: "conn-full",
            label: "Work Connection",
            peerDisplayName: "John Doe",
            status: .active,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt
        )

        XCTAssertEqual(info.id, "conn-full")
        XCTAssertEqual(info.label, "Work Connection")
        XCTAssertEqual(info.peerDisplayName, "John Doe")
        XCTAssertEqual(info.status, .active)
        XCTAssertEqual(info.createdAt, createdAt)
        XCTAssertEqual(info.lastActivityAt, lastActivityAt)
    }

    func testVaultConnectionInfo_identifiable() {
        let info1 = VaultConnectionInfo(
            id: "conn-1",
            label: nil,
            peerDisplayName: nil,
            status: .pending,
            createdAt: nil,
            lastActivityAt: nil
        )

        let info2 = VaultConnectionInfo(
            id: "conn-2",
            label: nil,
            peerDisplayName: nil,
            status: .pending,
            createdAt: nil,
            lastActivityAt: nil
        )

        XCTAssertNotEqual(info1.id, info2.id)
    }

    func testVaultConnectionInfo_allStatuses() {
        let statuses: [ConnectionStatus] = [.pending, .active, .revoked]

        for status in statuses {
            let info = VaultConnectionInfo(
                id: "conn-\(status.rawValue)",
                label: nil,
                peerDisplayName: nil,
                status: status,
                createdAt: nil,
                lastActivityAt: nil
            )
            XCTAssertEqual(info.status, status)
        }
    }

    // MARK: - VaultConnectionDetails Tests

    func testVaultConnectionDetails_fullInitialization() {
        let details = VaultConnectionDetails(
            id: "conn-details",
            label: "Primary Connection",
            peerDisplayName: "Jane Smith",
            peerPublicKey: "publicKey123==",
            status: .active,
            createdAt: Date(),
            lastActivityAt: Date(),
            messageCount: 42,
            sharedData: ["email": "jane@example.com", "phone": "+1234567890"]
        )

        XCTAssertEqual(details.id, "conn-details")
        XCTAssertEqual(details.label, "Primary Connection")
        XCTAssertEqual(details.peerDisplayName, "Jane Smith")
        XCTAssertEqual(details.peerPublicKey, "publicKey123==")
        XCTAssertEqual(details.status, .active)
        XCTAssertNotNil(details.createdAt)
        XCTAssertNotNil(details.lastActivityAt)
        XCTAssertEqual(details.messageCount, 42)
        XCTAssertEqual(details.sharedData["email"], "jane@example.com")
        XCTAssertEqual(details.sharedData["phone"], "+1234567890")
    }

    func testVaultConnectionDetails_emptySharedData() {
        let details = VaultConnectionDetails(
            id: "conn-empty",
            label: nil,
            peerDisplayName: nil,
            peerPublicKey: nil,
            status: .pending,
            createdAt: nil,
            lastActivityAt: nil,
            messageCount: 0,
            sharedData: [:]
        )

        XCTAssertEqual(details.messageCount, 0)
        XCTAssertTrue(details.sharedData.isEmpty)
    }

    // MARK: - ConnectionAcceptResult Tests

    func testConnectionAcceptResult_fullInitialization() {
        let result = ConnectionAcceptResult(
            connectionId: "new-conn-123",
            peerDisplayName: "New Friend",
            peerPublicKey: "friendPublicKey=="
        )

        XCTAssertEqual(result.connectionId, "new-conn-123")
        XCTAssertEqual(result.peerDisplayName, "New Friend")
        XCTAssertEqual(result.peerPublicKey, "friendPublicKey==")
    }

    func testConnectionAcceptResult_minimalInitialization() {
        let result = ConnectionAcceptResult(
            connectionId: "conn-only",
            peerDisplayName: nil,
            peerPublicKey: nil
        )

        XCTAssertEqual(result.connectionId, "conn-only")
        XCTAssertNil(result.peerDisplayName)
        XCTAssertNil(result.peerPublicKey)
    }

    // MARK: - ConnectionHandlerError Tests

    func testConnectionHandlerError_inviteCreationFailedDescription() {
        let error = ConnectionHandlerError.inviteCreationFailed("Rate limited")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invitation"))
        XCTAssertTrue(error.errorDescription!.contains("Rate limited"))
    }

    func testConnectionHandlerError_credentialRetrievalFailedDescription() {
        let error = ConnectionHandlerError.credentialRetrievalFailed("Not found")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("credentials"))
        XCTAssertTrue(error.errorDescription!.contains("Not found"))
    }

    func testConnectionHandlerError_rotationFailedDescription() {
        let error = ConnectionHandlerError.rotationFailed("Connection inactive")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("rotate"))
        XCTAssertTrue(error.errorDescription!.contains("Connection inactive"))
    }

    func testConnectionHandlerError_revocationFailedDescription() {
        let error = ConnectionHandlerError.revocationFailed("Already revoked")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("revoke"))
        XCTAssertTrue(error.errorDescription!.contains("Already revoked"))
    }

    func testConnectionHandlerError_listFailedDescription() {
        let error = ConnectionHandlerError.listFailed("Database error")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("list"))
        XCTAssertTrue(error.errorDescription!.contains("Database error"))
    }

    func testConnectionHandlerError_getFailedDescription() {
        let error = ConnectionHandlerError.getFailed("Connection not found")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("get"))
        XCTAssertTrue(error.errorDescription!.contains("Connection not found"))
    }

    func testConnectionHandlerError_acceptFailedDescription() {
        let error = ConnectionHandlerError.acceptFailed("Invitation expired")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("accept"))
        XCTAssertTrue(error.errorDescription!.contains("Invitation expired"))
    }

    func testConnectionHandlerError_invalidResponseDescription() {
        let error = ConnectionHandlerError.invalidResponse

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("invalid"))
    }

    func testConnectionHandlerError_switchCoverage() {
        let errors: [ConnectionHandlerError] = [
            .inviteCreationFailed("test"),
            .credentialRetrievalFailed("test"),
            .rotationFailed("test"),
            .revocationFailed("test"),
            .listFailed("test"),
            .getFailed("test"),
            .acceptFailed("test"),
            .invalidResponse
        ]

        for error in errors {
            switch error {
            case .inviteCreationFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .credentialRetrievalFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .rotationFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .revocationFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .listFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .getFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .acceptFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .invalidResponse:
                XCTAssertTrue(true)
            }
        }
    }

    // MARK: - Invitation Code Format Tests

    func testInvitationCode_format() {
        let validCodes = ["INV-ABC123", "invite-xyz", "CODE123456"]

        for code in validCodes {
            XCTAssertFalse(code.isEmpty, "Invitation code should not be empty")
            XCTAssertGreaterThan(code.count, 5, "Invitation code should have reasonable length")
        }
    }

    // MARK: - Date Handling Tests

    func testISO8601DateParsing() {
        let dateString = "2025-12-31T10:30:00Z"
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: dateString)

        XCTAssertNotNil(date)

        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 31)
    }
}
