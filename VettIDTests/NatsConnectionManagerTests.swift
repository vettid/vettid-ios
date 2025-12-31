import XCTest
@testable import VettID

/// Tests for NatsConnectionManager and related components
@MainActor
final class NatsConnectionManagerTests: XCTestCase {

    // MARK: - NatsConnectionState Tests

    func testConnectionStateIsConnected() {
        XCTAssertTrue(NatsConnectionState.connected.isConnected)
        XCTAssertFalse(NatsConnectionState.disconnected.isConnected)
        XCTAssertFalse(NatsConnectionState.connecting.isConnected)
        XCTAssertFalse(NatsConnectionState.reconnecting.isConnected)
        XCTAssertFalse(NatsConnectionState.startingVault.isConnected)
        XCTAssertFalse(NatsConnectionState.waitingForVault.isConnected)
        XCTAssertFalse(NatsConnectionState.error(NatsConnectionError.notConnected).isConnected)
    }

    func testConnectionStateIsTransitioning() {
        XCTAssertTrue(NatsConnectionState.connecting.isTransitioning)
        XCTAssertTrue(NatsConnectionState.reconnecting.isTransitioning)
        XCTAssertTrue(NatsConnectionState.startingVault.isTransitioning)
        XCTAssertTrue(NatsConnectionState.waitingForVault.isTransitioning)

        XCTAssertFalse(NatsConnectionState.disconnected.isTransitioning)
        XCTAssertFalse(NatsConnectionState.connected.isTransitioning)
        XCTAssertFalse(NatsConnectionState.error(NatsConnectionError.notConnected).isTransitioning)
    }

    func testConnectionStateDisplayName() {
        XCTAssertEqual(NatsConnectionState.disconnected.displayName, "Disconnected")
        XCTAssertEqual(NatsConnectionState.connecting.displayName, "Connecting...")
        XCTAssertEqual(NatsConnectionState.connected.displayName, "Connected")
        XCTAssertEqual(NatsConnectionState.reconnecting.displayName, "Reconnecting...")
        XCTAssertEqual(NatsConnectionState.startingVault.displayName, "Starting Vault...")
        XCTAssertEqual(NatsConnectionState.waitingForVault.displayName, "Waiting for Vault...")
        XCTAssertEqual(NatsConnectionState.error(NatsConnectionError.notConnected).displayName, "Error")
    }

    func testConnectionStateEquality() {
        XCTAssertEqual(NatsConnectionState.disconnected, .disconnected)
        XCTAssertEqual(NatsConnectionState.connecting, .connecting)
        XCTAssertEqual(NatsConnectionState.connected, .connected)
        XCTAssertEqual(NatsConnectionState.reconnecting, .reconnecting)
        XCTAssertEqual(NatsConnectionState.startingVault, .startingVault)
        XCTAssertEqual(NatsConnectionState.waitingForVault, .waitingForVault)

        XCTAssertNotEqual(NatsConnectionState.disconnected, .connecting)
        XCTAssertNotEqual(NatsConnectionState.connected, .disconnected)
        XCTAssertNotEqual(NatsConnectionState.startingVault, .waitingForVault)
        XCTAssertNotEqual(NatsConnectionState.connecting, .startingVault)

        // Error states are equal regardless of the specific error
        let error1 = NatsConnectionState.error(NatsConnectionError.notConnected)
        let error2 = NatsConnectionState.error(NatsConnectionError.noCredentials)
        XCTAssertEqual(error1, error2)
    }

    // MARK: - NatsConnectionError Tests

    func testConnectionErrorDescriptions() {
        XCTAssertNotNil(NatsConnectionError.noCredentials.errorDescription)
        XCTAssertTrue(NatsConnectionError.noCredentials.errorDescription!.contains("credentials"))

        XCTAssertNotNil(NatsConnectionError.notConnected.errorDescription)
        XCTAssertTrue(NatsConnectionError.notConnected.errorDescription!.contains("connected"))

        XCTAssertNotNil(NatsConnectionError.connectionFailed("test").errorDescription)
        XCTAssertTrue(NatsConnectionError.connectionFailed("test").errorDescription!.contains("test"))

        XCTAssertNotNil(NatsConnectionError.publishFailed("pub error").errorDescription)
        XCTAssertTrue(NatsConnectionError.publishFailed("pub error").errorDescription!.contains("pub error"))

        XCTAssertNotNil(NatsConnectionError.subscribeFailed("sub error").errorDescription)
        XCTAssertTrue(NatsConnectionError.subscribeFailed("sub error").errorDescription!.contains("sub error"))
    }

    // MARK: - NatsMessage Tests

    func testNatsMessageStringValue() {
        let message = NatsMessage(
            topic: "test.topic",
            data: "Hello World".data(using: .utf8)!,
            headers: nil
        )

        XCTAssertEqual(message.stringValue, "Hello World")
    }

    func testNatsMessageDecode() throws {
        struct TestPayload: Codable, Equatable {
            let name: String
            let value: Int
        }

        let payload = TestPayload(name: "test", value: 42)
        let data = try JSONEncoder().encode(payload)

        let message = NatsMessage(topic: "test.topic", data: data, headers: nil)
        let decoded: TestPayload = try message.decode(TestPayload.self)

        XCTAssertEqual(decoded, payload)
    }

    func testNatsMessageDecodeInvalidData() {
        let message = NatsMessage(
            topic: "test.topic",
            data: "not json".data(using: .utf8)!,
            headers: nil
        )

        struct TestPayload: Codable {
            let name: String
        }

        XCTAssertThrowsError(try message.decode(TestPayload.self))
    }

    // MARK: - NatsConnectionManager Initialization Tests

    func testConnectionManagerInitialState() {
        let manager = NatsConnectionManager()

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertNil(manager.lastError)
    }

    func testCredentialsNeedRefresh_withNoCredentials() {
        let manager = NatsConnectionManager()

        // With no stored credentials, should return true
        XCTAssertTrue(manager.credentialsNeedRefresh())
    }
}

// MARK: - OwnerSpaceClient Tests

final class OwnerSpaceClientTests: XCTestCase {

    func testOwnerSpaceErrorDescriptions() {
        XCTAssertNotNil(OwnerSpaceError.notConnected.errorDescription)
        XCTAssertNotNil(OwnerSpaceError.timeout.errorDescription)
        XCTAssertNotNil(OwnerSpaceError.noResponse.errorDescription)
        XCTAssertNotNil(OwnerSpaceError.invalidResponse.errorDescription)
        XCTAssertNotNil(OwnerSpaceError.handlerError("test").errorDescription)

        XCTAssertTrue(OwnerSpaceError.handlerError("test error").errorDescription!.contains("test error"))
    }

    func testHandlerResultResponseDecoding() throws {
        let json = """
        {
            "id": "req-123",
            "success": true,
            "result": {"key": "value"},
            "error": null
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(HandlerResultResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.id, "req-123")
        XCTAssertTrue(response.success)
        XCTAssertNotNil(response.result)
        XCTAssertNil(response.error)
    }

    func testHandlerResultResponseDecoding_withError() throws {
        let json = """
        {
            "id": "req-456",
            "success": false,
            "result": null,
            "error": "Handler execution failed"
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(HandlerResultResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.id, "req-456")
        XCTAssertFalse(response.success)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error, "Handler execution failed")
    }

    func testStatusResponseDecoding() throws {
        let json = """
        {
            "id": "status-123",
            "vault_status": "running",
            "health": "healthy",
            "active_handlers": 5,
            "last_activity": "2025-12-07T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(StatusResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.id, "status-123")
        XCTAssertEqual(response.vaultStatus, "running")
        XCTAssertEqual(response.health, "healthy")
        XCTAssertEqual(response.activeHandlers, 5)
        XCTAssertNotNil(response.lastActivity)
    }

    func testVaultEventDecoding() throws {
        let json = """
        {
            "event_id": "evt-123",
            "event_type": "secret_accessed",
            "timestamp": "2025-12-07T12:00:00Z",
            "data": {"secret_id": "sec-456"}
        }
        """

        let decoder = JSONDecoder()
        let event = try decoder.decode(VaultEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.eventId, "evt-123")
        XCTAssertEqual(event.eventType, "secret_accessed")
        XCTAssertNotNil(event.data)
    }
}

// MARK: - NatsSetupViewModel Tests

@MainActor
final class NatsSetupViewModelTests: XCTestCase {

    func testInitialState() {
        let viewModel = NatsSetupViewModel()

        XCTAssertEqual(viewModel.setupState, .initial)
        XCTAssertNil(viewModel.accountInfo)
        XCTAssertFalse(viewModel.showError)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSetupStateTitles() {
        XCTAssertEqual(NatsSetupViewModel.SetupState.initial.title, "NATS Setup")
        XCTAssertEqual(NatsSetupViewModel.SetupState.checkingStatus.title, "Checking Status...")
        XCTAssertEqual(NatsSetupViewModel.SetupState.creatingAccount.title, "Creating Account...")
        XCTAssertEqual(NatsSetupViewModel.SetupState.generatingToken.title, "Generating Token...")
        XCTAssertEqual(NatsSetupViewModel.SetupState.connecting.title, "Connecting...")
        XCTAssertEqual(NatsSetupViewModel.SetupState.startingVault.title, "Starting Vault...")
        XCTAssertEqual(NatsSetupViewModel.SetupState.waitingForVault.title, "Waiting for Vault...")
        XCTAssertEqual(NatsSetupViewModel.SetupState.connected(NatsAccountStatus(ownerSpaceId: "", messageSpaceId: "", isConnected: true)).title, "Connected")
        XCTAssertEqual(NatsSetupViewModel.SetupState.error("test").title, "Error")
    }

    func testSetupStateIsProcessing() {
        XCTAssertFalse(NatsSetupViewModel.SetupState.initial.isProcessing)
        XCTAssertTrue(NatsSetupViewModel.SetupState.checkingStatus.isProcessing)
        XCTAssertTrue(NatsSetupViewModel.SetupState.creatingAccount.isProcessing)
        XCTAssertTrue(NatsSetupViewModel.SetupState.generatingToken.isProcessing)
        XCTAssertTrue(NatsSetupViewModel.SetupState.connecting.isProcessing)
        XCTAssertTrue(NatsSetupViewModel.SetupState.startingVault.isProcessing)
        XCTAssertTrue(NatsSetupViewModel.SetupState.waitingForVault.isProcessing)
        XCTAssertFalse(NatsSetupViewModel.SetupState.connected(NatsAccountStatus(ownerSpaceId: "", messageSpaceId: "", isConnected: true)).isProcessing)
        XCTAssertFalse(NatsSetupViewModel.SetupState.error("test").isProcessing)
    }

    func testSetupStateEquality() {
        XCTAssertEqual(NatsSetupViewModel.SetupState.initial, .initial)
        XCTAssertEqual(NatsSetupViewModel.SetupState.checkingStatus, .checkingStatus)
        XCTAssertEqual(NatsSetupViewModel.SetupState.creatingAccount, .creatingAccount)
        XCTAssertEqual(NatsSetupViewModel.SetupState.generatingToken, .generatingToken)
        XCTAssertEqual(NatsSetupViewModel.SetupState.connecting, .connecting)
        XCTAssertEqual(NatsSetupViewModel.SetupState.startingVault, .startingVault)
        XCTAssertEqual(NatsSetupViewModel.SetupState.waitingForVault, .waitingForVault)

        XCTAssertNotEqual(NatsSetupViewModel.SetupState.initial, .connecting)
        XCTAssertNotEqual(NatsSetupViewModel.SetupState.startingVault, .waitingForVault)
        XCTAssertNotEqual(NatsSetupViewModel.SetupState.connecting, .startingVault)

        let status1 = NatsAccountStatus(ownerSpaceId: "os1", messageSpaceId: "ms1", isConnected: true)
        let status2 = NatsAccountStatus(ownerSpaceId: "os1", messageSpaceId: "ms1", isConnected: true)
        let status3 = NatsAccountStatus(ownerSpaceId: "os2", messageSpaceId: "ms2", isConnected: true)

        XCTAssertEqual(NatsSetupViewModel.SetupState.connected(status1), .connected(status2))
        XCTAssertNotEqual(NatsSetupViewModel.SetupState.connected(status1), .connected(status3))

        XCTAssertEqual(NatsSetupViewModel.SetupState.error("test"), .error("test"))
        XCTAssertNotEqual(NatsSetupViewModel.SetupState.error("test1"), .error("test2"))
    }

    func testReset() {
        let viewModel = NatsSetupViewModel()

        // Simulate some state changes
        viewModel.showError = true
        viewModel.errorMessage = "Test error"

        // Reset
        viewModel.reset()

        XCTAssertEqual(viewModel.setupState, .initial)
        XCTAssertNil(viewModel.accountInfo)
        XCTAssertFalse(viewModel.showError)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - NatsAccountStatus Tests

    func testNatsAccountStatusShortId() {
        let status = NatsAccountStatus(
            ownerSpaceId: "OwnerSpace.user-guid-1234567890",
            messageSpaceId: "MessageSpace.user-guid-1234567890",
            isConnected: true
        )

        XCTAssertTrue(status.ownerSpaceShortId.hasSuffix("..."))
        XCTAssertEqual(status.ownerSpaceShortId.count, 23) // 20 chars + "..."
    }

    func testNatsAccountStatusEquality() {
        let status1 = NatsAccountStatus(ownerSpaceId: "os1", messageSpaceId: "ms1", isConnected: true)
        let status2 = NatsAccountStatus(ownerSpaceId: "os1", messageSpaceId: "ms1", isConnected: true)
        let status3 = NatsAccountStatus(ownerSpaceId: "os2", messageSpaceId: "ms1", isConnected: true)

        XCTAssertEqual(status1, status2)
        XCTAssertNotEqual(status1, status3)
    }
}
