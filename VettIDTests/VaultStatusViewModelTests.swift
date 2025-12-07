import XCTest
@testable import VettID

/// Tests for VaultStatusViewModel state machine and vault lifecycle management
@MainActor
final class VaultStatusViewModelTests: XCTestCase {

    var viewModel: VaultStatusViewModel!

    override func setUp() {
        super.setUp()
        viewModel = VaultStatusViewModel()
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialStateWithoutCredential() {
        // Without a stored credential, should show not enrolled
        // Note: This depends on CredentialStore having no stored credential
        // In a real test environment, we would mock the credential store
        XCTAssertNotNil(viewModel.state)
    }

    // MARK: - View State Tests

    func testViewStateTitles() {
        XCTAssertEqual(VaultStatusViewModel.VaultViewState.loading.title, "Loading...")
        XCTAssertEqual(VaultStatusViewModel.VaultViewState.notEnrolled.title, "Set Up Your Vault")
        XCTAssertEqual(VaultStatusViewModel.VaultViewState.error(message: "test", retryable: true).title, "Error")
    }

    func testEnrolledViewStateTitle() {
        let statusInfo = VaultStatusViewModel.VaultStatusInfo(
            status: .running,
            instanceId: "test-instance",
            health: .healthy
        )
        let enrolledState = VaultStatusViewModel.VaultViewState.enrolled(statusInfo)
        XCTAssertEqual(enrolledState.title, "Running")
    }

    // MARK: - Vault Lifecycle Status Tests

    func testVaultLifecycleStatusDisplayNames() {
        XCTAssertEqual(VaultLifecycleStatus.pendingEnrollment.displayName, "Pending Enrollment")
        XCTAssertEqual(VaultLifecycleStatus.enrolled.displayName, "Enrolled")
        XCTAssertEqual(VaultLifecycleStatus.provisioning.displayName, "Starting...")
        XCTAssertEqual(VaultLifecycleStatus.running.displayName, "Running")
        XCTAssertEqual(VaultLifecycleStatus.stopped.displayName, "Stopped")
        XCTAssertEqual(VaultLifecycleStatus.terminated.displayName, "Terminated")
    }

    func testVaultLifecycleStatusSystemImages() {
        XCTAssertEqual(VaultLifecycleStatus.pendingEnrollment.systemImage, "hourglass")
        XCTAssertEqual(VaultLifecycleStatus.enrolled.systemImage, "checkmark.seal")
        XCTAssertEqual(VaultLifecycleStatus.provisioning.systemImage, "arrow.clockwise")
        XCTAssertEqual(VaultLifecycleStatus.running.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(VaultLifecycleStatus.stopped.systemImage, "stop.circle.fill")
        XCTAssertEqual(VaultLifecycleStatus.terminated.systemImage, "xmark.circle.fill")
    }

    func testVaultLifecycleStatusColors() {
        XCTAssertEqual(VaultLifecycleStatus.pendingEnrollment.statusColor, .orange)
        XCTAssertEqual(VaultLifecycleStatus.enrolled.statusColor, .blue)
        XCTAssertEqual(VaultLifecycleStatus.provisioning.statusColor, .yellow)
        XCTAssertEqual(VaultLifecycleStatus.running.statusColor, .green)
        XCTAssertEqual(VaultLifecycleStatus.stopped.statusColor, .gray)
        XCTAssertEqual(VaultLifecycleStatus.terminated.statusColor, .red)
    }

    func testVaultLifecycleStatusCanStart() {
        // Can start from enrolled or stopped
        XCTAssertTrue(VaultLifecycleStatus.enrolled.canStart)
        XCTAssertTrue(VaultLifecycleStatus.stopped.canStart)

        // Cannot start from other states
        XCTAssertFalse(VaultLifecycleStatus.pendingEnrollment.canStart)
        XCTAssertFalse(VaultLifecycleStatus.provisioning.canStart)
        XCTAssertFalse(VaultLifecycleStatus.running.canStart)
        XCTAssertFalse(VaultLifecycleStatus.terminated.canStart)
    }

    func testVaultLifecycleStatusCanStop() {
        // Can only stop from running
        XCTAssertTrue(VaultLifecycleStatus.running.canStop)

        // Cannot stop from other states
        XCTAssertFalse(VaultLifecycleStatus.pendingEnrollment.canStop)
        XCTAssertFalse(VaultLifecycleStatus.enrolled.canStop)
        XCTAssertFalse(VaultLifecycleStatus.provisioning.canStop)
        XCTAssertFalse(VaultLifecycleStatus.stopped.canStop)
        XCTAssertFalse(VaultLifecycleStatus.terminated.canStop)
    }

    // MARK: - Vault Health Status Tests

    func testVaultHealthStatusDisplayNames() {
        XCTAssertEqual(VaultHealthStatus.healthy.displayName, "Healthy")
        XCTAssertEqual(VaultHealthStatus.warning.displayName, "Warning")
        XCTAssertEqual(VaultHealthStatus.critical.displayName, "Critical")
        XCTAssertEqual(VaultHealthStatus.unknown.displayName, "Unknown")
    }

    func testVaultHealthStatusSystemImages() {
        XCTAssertEqual(VaultHealthStatus.healthy.systemImage, "heart.fill")
        XCTAssertEqual(VaultHealthStatus.warning.systemImage, "exclamationmark.triangle.fill")
        XCTAssertEqual(VaultHealthStatus.critical.systemImage, "exclamationmark.octagon.fill")
        XCTAssertEqual(VaultHealthStatus.unknown.systemImage, "questionmark.circle")
    }

    func testVaultHealthStatusColors() {
        XCTAssertEqual(VaultHealthStatus.healthy.color, .green)
        XCTAssertEqual(VaultHealthStatus.warning.color, .yellow)
        XCTAssertEqual(VaultHealthStatus.critical.color, .red)
        XCTAssertEqual(VaultHealthStatus.unknown.color, .gray)
    }

    // MARK: - Reset Tests

    func testReset() {
        // Set some state
        viewModel.errorMessage = "Test error"
        viewModel.showError = true
        viewModel.unusedKeyCount = 10
        viewModel.healthStatus = .healthy

        // Reset
        viewModel.reset()

        // Verify reset
        XCTAssertEqual(viewModel.state, .loading)
        XCTAssertNil(viewModel.vaultInfo)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.showError)
        XCTAssertNil(viewModel.lastSyncAt)
        XCTAssertNil(viewModel.lastBackupAt)
        XCTAssertEqual(viewModel.unusedKeyCount, 0)
        XCTAssertEqual(viewModel.healthStatus, .unknown)
    }

    // MARK: - State Equality Tests

    func testViewStateEquality() {
        XCTAssertEqual(VaultStatusViewModel.VaultViewState.loading, .loading)
        XCTAssertEqual(VaultStatusViewModel.VaultViewState.notEnrolled, .notEnrolled)

        XCTAssertNotEqual(VaultStatusViewModel.VaultViewState.loading, .notEnrolled)
    }

    func testViewStateEqualityWithAssociatedValues() {
        let statusInfo1 = VaultStatusViewModel.VaultStatusInfo(
            status: .running,
            instanceId: "test-1",
            health: .healthy
        )
        let statusInfo2 = VaultStatusViewModel.VaultStatusInfo(
            status: .running,
            instanceId: "test-1",
            health: .healthy
        )
        let statusInfo3 = VaultStatusViewModel.VaultStatusInfo(
            status: .stopped,
            instanceId: "test-1",
            health: .healthy
        )

        let enrolled1 = VaultStatusViewModel.VaultViewState.enrolled(statusInfo1)
        let enrolled2 = VaultStatusViewModel.VaultViewState.enrolled(statusInfo2)
        let enrolled3 = VaultStatusViewModel.VaultViewState.enrolled(statusInfo3)

        XCTAssertEqual(enrolled1, enrolled2)
        XCTAssertNotEqual(enrolled1, enrolled3)

        let error1 = VaultStatusViewModel.VaultViewState.error(message: "test", retryable: true)
        let error2 = VaultStatusViewModel.VaultViewState.error(message: "test", retryable: true)
        let error3 = VaultStatusViewModel.VaultViewState.error(message: "different", retryable: true)

        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }

    // MARK: - Auto Refresh Tests

    func testStopAutoRefresh() {
        // Start and immediately stop auto refresh
        viewModel.startAutoRefresh(authToken: "test-token", interval: 60)
        viewModel.stopAutoRefresh()

        // Just verify it doesn't crash - the task should be cancelled
        XCTAssertTrue(true)
    }

    // MARK: - Vault Info Tests

    func testVaultInfoEquality() {
        let info1 = VaultStatusViewModel.VaultInfo(
            userGuid: "user-123",
            status: .running,
            enrolledAt: Date(timeIntervalSince1970: 1000),
            instanceId: "inst-1",
            region: "us-east-1",
            lastBackup: nil,
            health: .healthy
        )

        let info2 = VaultStatusViewModel.VaultInfo(
            userGuid: "user-123",
            status: .running,
            enrolledAt: Date(timeIntervalSince1970: 1000),
            instanceId: "inst-1",
            region: "us-east-1",
            lastBackup: nil,
            health: .healthy
        )

        let info3 = VaultStatusViewModel.VaultInfo(
            userGuid: "user-456",
            status: .running,
            enrolledAt: Date(timeIntervalSince1970: 1000),
            instanceId: "inst-1",
            region: "us-east-1",
            lastBackup: nil,
            health: .healthy
        )

        XCTAssertEqual(info1, info2)
        XCTAssertNotEqual(info1, info3)
    }

    // MARK: - Vault Status Info Tests

    func testVaultStatusInfoEquality() {
        let statusInfo1 = VaultStatusViewModel.VaultStatusInfo(
            status: .running,
            instanceId: "test-instance",
            health: .healthy
        )

        let statusInfo2 = VaultStatusViewModel.VaultStatusInfo(
            status: .running,
            instanceId: "test-instance",
            health: .healthy
        )

        let statusInfo3 = VaultStatusViewModel.VaultStatusInfo(
            status: .stopped,
            instanceId: "test-instance",
            health: .healthy
        )

        XCTAssertEqual(statusInfo1, statusInfo2)
        XCTAssertNotEqual(statusInfo1, statusInfo3)
    }

    // MARK: - All Status Cases Tests

    func testAllVaultLifecycleStatusCases() {
        let allCases = VaultLifecycleStatus.allCases
        XCTAssertEqual(allCases.count, 6)
        XCTAssertTrue(allCases.contains(.pendingEnrollment))
        XCTAssertTrue(allCases.contains(.enrolled))
        XCTAssertTrue(allCases.contains(.provisioning))
        XCTAssertTrue(allCases.contains(.running))
        XCTAssertTrue(allCases.contains(.stopped))
        XCTAssertTrue(allCases.contains(.terminated))
    }

    func testVaultLifecycleStatusRawValues() {
        XCTAssertEqual(VaultLifecycleStatus.pendingEnrollment.rawValue, "pending_enrollment")
        XCTAssertEqual(VaultLifecycleStatus.enrolled.rawValue, "enrolled")
        XCTAssertEqual(VaultLifecycleStatus.provisioning.rawValue, "provisioning")
        XCTAssertEqual(VaultLifecycleStatus.running.rawValue, "running")
        XCTAssertEqual(VaultLifecycleStatus.stopped.rawValue, "stopped")
        XCTAssertEqual(VaultLifecycleStatus.terminated.rawValue, "terminated")
    }

    func testVaultHealthStatusRawValues() {
        XCTAssertEqual(VaultHealthStatus.healthy.rawValue, "healthy")
        XCTAssertEqual(VaultHealthStatus.warning.rawValue, "warning")
        XCTAssertEqual(VaultHealthStatus.critical.rawValue, "critical")
        XCTAssertEqual(VaultHealthStatus.unknown.rawValue, "unknown")
    }
}
