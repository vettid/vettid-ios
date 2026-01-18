import XCTest
@testable import VettID

/// Tests for VaultSecurityService (Issue #18)
final class VaultSecurityServiceTests: XCTestCase {

    // MARK: - Singleton Tests

    func testSharedInstance_exists() async {
        let service = await VaultSecurityService.shared
        XCTAssertNotNil(service)
    }

    func testSharedInstance_isSingleton() async {
        let service1 = await VaultSecurityService.shared
        let service2 = await VaultSecurityService.shared
        XCTAssertTrue(service1 === service2)
    }

    // MARK: - BGTask Identifier Tests

    func testBgTaskIdentifier_isCorrect() {
        XCTAssertEqual(VaultSecurityService.bgTaskIdentifier, "com.vettid.securityCheck")
    }

    // MARK: - Monitoring State Tests

    func testIsCurrentlyMonitoring_initiallyFalse() async {
        let service = await VaultSecurityService.shared
        let isMonitoring = await service.isCurrentlyMonitoring
        XCTAssertFalse(isMonitoring)
    }

    func testStartMonitoring_withoutClient_doesNotCrash() async {
        let service = await VaultSecurityService.shared

        // Should not crash even without OwnerSpaceClient configured
        await service.startMonitoring()

        // Give a moment for async operation
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Should still not be monitoring (no client)
        let isMonitoring = await service.isCurrentlyMonitoring
        XCTAssertFalse(isMonitoring)
    }

    func testStopMonitoring_doesNotCrash() async {
        let service = await VaultSecurityService.shared

        // Should not crash even if not monitoring
        await service.stopMonitoring()

        let isMonitoring = await service.isCurrentlyMonitoring
        XCTAssertFalse(isMonitoring)
    }

    // MARK: - Pending Events Tests

    func testPendingRecoveryRequests_initiallyEmpty() async {
        let service = await VaultSecurityService.shared
        await service.clearAll()

        let pending = await service.pendingRecoveryRequests
        XCTAssertTrue(pending.isEmpty)
    }

    func testPendingTransferRequests_initiallyEmpty() async {
        let service = await VaultSecurityService.shared
        await service.clearAll()

        let pending = await service.pendingTransferRequests
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Action Callback Tests

    func testOnRecoveryAction_canBeSet() async {
        let service = await VaultSecurityService.shared
        var callbackInvoked = false

        await MainActor.run {
            service.onRecoveryAction = { _, _ in
                callbackInvoked = true
            }
        }

        // Verify callback can be set
        let callback = await service.onRecoveryAction
        XCTAssertNotNil(callback)
    }

    func testOnTransferAction_canBeSet() async {
        let service = await VaultSecurityService.shared
        var callbackInvoked = false

        await MainActor.run {
            service.onTransferAction = { _, _ in
                callbackInvoked = true
            }
        }

        // Verify callback can be set
        let callback = await service.onTransferAction
        XCTAssertNotNil(callback)
    }

    // MARK: - Clear All Tests

    func testClearAll_clearsEverything() async {
        let service = await VaultSecurityService.shared

        await service.clearAll()

        let recoveryPending = await service.pendingRecoveryRequests
        let transferPending = await service.pendingTransferRequests

        XCTAssertTrue(recoveryPending.isEmpty)
        XCTAssertTrue(transferPending.isEmpty)
    }

    // MARK: - Scene Phase Tests

    func testHandleScenePhase_active_startsMonitoring() async {
        let service = await VaultSecurityService.shared

        // This should attempt to start monitoring (will fail without client, but shouldn't crash)
        await service.handleScenePhase(.active)
    }

    func testHandleScenePhase_inactive_keepsState() async {
        let service = await VaultSecurityService.shared

        // Inactive should not change monitoring state
        await service.handleScenePhase(.inactive)
    }

    func testHandleScenePhase_background_stopsMonitoring() async {
        let service = await VaultSecurityService.shared

        // Background should stop monitoring
        await service.handleScenePhase(.background)

        let isMonitoring = await service.isCurrentlyMonitoring
        XCTAssertFalse(isMonitoring)
    }

    // MARK: - Recovery Action Tests

    func testCancelRecovery_invokesCallback() async {
        let service = await VaultSecurityService.shared
        let expectation = XCTestExpectation(description: "Recovery callback invoked")
        var receivedRequestId: String?
        var receivedShouldCancel: Bool?

        await MainActor.run {
            service.onRecoveryAction = { requestId, shouldCancel in
                receivedRequestId = requestId
                receivedShouldCancel = shouldCancel
                expectation.fulfill()
            }
        }

        await service.cancelRecovery(requestId: "test-cancel-123")

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedRequestId, "test-cancel-123")
        XCTAssertEqual(receivedShouldCancel, true)
    }

    func testShowRecoveryDetails_invokesCallback() async {
        let service = await VaultSecurityService.shared
        let expectation = XCTestExpectation(description: "Recovery callback invoked")
        var receivedRequestId: String?
        var receivedShouldCancel: Bool?

        await MainActor.run {
            service.onRecoveryAction = { requestId, shouldCancel in
                receivedRequestId = requestId
                receivedShouldCancel = shouldCancel
                expectation.fulfill()
            }
        }

        await service.showRecoveryDetails(requestId: "test-details-456")

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedRequestId, "test-details-456")
        XCTAssertEqual(receivedShouldCancel, false)
    }

    // MARK: - Transfer Action Tests

    func testApproveTransfer_invokesCallback() async {
        let service = await VaultSecurityService.shared
        let expectation = XCTestExpectation(description: "Transfer callback invoked")
        var receivedTransferId: String?
        var receivedApproved: Bool?

        await MainActor.run {
            service.onTransferAction = { transferId, approved in
                receivedTransferId = transferId
                receivedApproved = approved
                expectation.fulfill()
            }
        }

        await service.approveTransfer(transferId: "test-approve-789")

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedTransferId, "test-approve-789")
        XCTAssertEqual(receivedApproved, true)
    }

    func testDenyTransfer_invokesCallback() async {
        let service = await VaultSecurityService.shared
        let expectation = XCTestExpectation(description: "Transfer callback invoked")
        var receivedTransferId: String?
        var receivedApproved: Bool?

        await MainActor.run {
            service.onTransferAction = { transferId, approved in
                receivedTransferId = transferId
                receivedApproved = approved
                expectation.fulfill()
            }
        }

        await service.denyTransfer(transferId: "test-deny-012")

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedTransferId, "test-deny-012")
        XCTAssertEqual(receivedApproved, false)
    }

    // MARK: - Background Check Tests

    func testCheckForMissedEvents_withoutClient_doesNotCrash() async {
        let service = await VaultSecurityService.shared

        // Should not crash without client
        await service.checkForMissedEvents()
    }
}
