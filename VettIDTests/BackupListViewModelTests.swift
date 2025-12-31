import XCTest
@testable import VettID

/// Tests for BackupListViewModel
@MainActor
final class BackupListViewModelTests: XCTestCase {

    // MARK: - Initial State Tests

    func testInitialState() {
        let viewModel = BackupListViewModel(authTokenProvider: { "test-token" })

        if case .loading = viewModel.state {
            // Expected
        } else {
            XCTFail("Expected loading state, got \(viewModel.state)")
        }
        XCTAssertFalse(viewModel.isCreatingBackup)
    }

    // MARK: - State Tests

    func testBackupListState_equatable() {
        // Test loading state equality
        XCTAssertEqual(BackupListState.loading, BackupListState.loading)

        // Test empty state equality
        XCTAssertEqual(BackupListState.empty, BackupListState.empty)

        // Test error state equality
        XCTAssertEqual(BackupListState.error("test"), BackupListState.error("test"))
        XCTAssertNotEqual(BackupListState.error("test1"), BackupListState.error("test2"))

        // Test loaded state equality
        let backup1 = createTestBackup(id: "1")
        let backup2 = createTestBackup(id: "2")
        XCTAssertEqual(BackupListState.loaded([backup1]), BackupListState.loaded([backup1]))
        XCTAssertNotEqual(BackupListState.loaded([backup1]), BackupListState.loaded([backup2]))

        // Test different states are not equal
        XCTAssertNotEqual(BackupListState.loading, BackupListState.empty)
    }

    // MARK: - Backup Type Tests

    func testBackupType_rawValues() {
        XCTAssertEqual(BackupType.auto.rawValue, "auto")
        XCTAssertEqual(BackupType.manual.rawValue, "manual")
    }

    // MARK: - Backup Status Tests

    func testBackupStatus_rawValues() {
        XCTAssertEqual(BackupStatus.complete.rawValue, "complete")
        XCTAssertEqual(BackupStatus.partial.rawValue, "partial")
        XCTAssertEqual(BackupStatus.failed.rawValue, "failed")
    }

    // MARK: - Helpers

    private func createTestBackup(id: String) -> Backup {
        Backup(
            id: id,
            createdAt: Date(),
            sizeBytes: 1024,
            type: .manual,
            status: .complete,
            encryptionMethod: "ChaCha20-Poly1305"
        )
    }
}
