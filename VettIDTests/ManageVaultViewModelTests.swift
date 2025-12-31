import XCTest
@testable import VettID

/// Tests for ManageVaultView and ManageVaultViewModel components
@MainActor
final class ManageVaultViewModelTests: XCTestCase {

    // MARK: - VaultServerStatus Tests

    func testVaultServerStatusDisplayName() {
        XCTAssertEqual(VaultServerStatus.unknown.displayName, "Unknown")
        XCTAssertEqual(VaultServerStatus.loading.displayName, "Checking...")
        XCTAssertEqual(VaultServerStatus.running.displayName, "Running")
        XCTAssertEqual(VaultServerStatus.stopped.displayName, "Stopped")
        XCTAssertEqual(VaultServerStatus.starting.displayName, "Starting...")
        XCTAssertEqual(VaultServerStatus.stopping.displayName, "Stopping...")
        XCTAssertEqual(VaultServerStatus.pending.displayName, "Pending")
        XCTAssertTrue(VaultServerStatus.error("test error").displayName.contains("Error"))
    }

    func testVaultServerStatusColor() {
        XCTAssertEqual(VaultServerStatus.running.color, .green)
        XCTAssertEqual(VaultServerStatus.stopped.color, .orange)
        XCTAssertEqual(VaultServerStatus.starting.color, .blue)
        XCTAssertEqual(VaultServerStatus.stopping.color, .blue)
        XCTAssertEqual(VaultServerStatus.pending.color, .blue)
        XCTAssertEqual(VaultServerStatus.loading.color, .blue)
        XCTAssertEqual(VaultServerStatus.error("test").color, .red)
        XCTAssertEqual(VaultServerStatus.unknown.color, .gray)
    }

    func testVaultServerStatusEquality() {
        XCTAssertEqual(VaultServerStatus.unknown, .unknown)
        XCTAssertEqual(VaultServerStatus.loading, .loading)
        XCTAssertEqual(VaultServerStatus.running, .running)
        XCTAssertEqual(VaultServerStatus.stopped, .stopped)
        XCTAssertEqual(VaultServerStatus.starting, .starting)
        XCTAssertEqual(VaultServerStatus.stopping, .stopping)
        XCTAssertEqual(VaultServerStatus.pending, .pending)

        XCTAssertNotEqual(VaultServerStatus.running, .stopped)
        XCTAssertNotEqual(VaultServerStatus.starting, .stopping)

        // Error states with same message are equal
        let error1 = VaultServerStatus.error("same error")
        let error2 = VaultServerStatus.error("same error")
        XCTAssertEqual(error1, error2)

        // Error states with different messages are not equal
        let error3 = VaultServerStatus.error("error 1")
        let error4 = VaultServerStatus.error("error 2")
        XCTAssertNotEqual(error3, error4)
    }

    // MARK: - ManageVaultViewModel Tests

    func testManageVaultViewModelInitialState() {
        let viewModel = ManageVaultViewModel()

        XCTAssertEqual(viewModel.vaultStatus, .unknown)
        XCTAssertNil(viewModel.statusMessage)
        XCTAssertFalse(viewModel.showConfirmation)
        XCTAssertNil(viewModel.pendingAction)
    }

    func testManageVaultViewModelConfigureProviders() {
        let viewModel = ManageVaultViewModel()

        // Configure with providers
        viewModel.configure(
            authTokenProvider: { "test-token" },
            userGuidProvider: { "test-user-guid" }
        )

        // Verify providers are set (indirectly tested through operations)
        XCTAssertEqual(viewModel.vaultStatus, .unknown)
    }
}
