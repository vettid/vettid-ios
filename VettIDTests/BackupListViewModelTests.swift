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
        XCTAssertNil(viewModel.deletingBackupId)
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

    func testBackupType_icon() {
        XCTAssertEqual(BackupType.auto.icon, "arrow.clockwise.circle.fill")
        XCTAssertEqual(BackupType.manual.icon, "hand.tap.fill")
    }

    func testBackupType_displayName() {
        XCTAssertEqual(BackupType.auto.displayName, "Automatic")
        XCTAssertEqual(BackupType.manual.displayName, "Manual")
    }

    // MARK: - Backup Status Tests

    func testBackupStatus_icon() {
        XCTAssertEqual(BackupStatus.complete.icon, "checkmark.circle.fill")
        XCTAssertEqual(BackupStatus.partial.icon, "exclamationmark.circle.fill")
        XCTAssertEqual(BackupStatus.failed.icon, "xmark.circle.fill")
    }

    func testBackupStatus_color() {
        // Just verify colors are set (can't easily compare SwiftUI Colors)
        _ = BackupStatus.complete.color
        _ = BackupStatus.partial.color
        _ = BackupStatus.failed.color
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
