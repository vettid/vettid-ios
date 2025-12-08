import XCTest
@testable import VettID

/// Tests for BackupSettingsViewModel
@MainActor
final class BackupSettingsViewModelTests: XCTestCase {

    // MARK: - Initial State Tests

    func testInitialState() {
        let viewModel = BackupSettingsViewModel(authTokenProvider: { "test-token" })

        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isSaving)
        XCTAssertFalse(viewModel.isBackingUp)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.successMessage)
    }

    func testDefaultSettings() {
        let viewModel = BackupSettingsViewModel(authTokenProvider: { "test-token" })

        // Default values should match BackupSettings defaults
        XCTAssertFalse(viewModel.autoBackupEnabled)
        XCTAssertEqual(viewModel.backupFrequency, .daily)
        XCTAssertEqual(viewModel.retentionDays, 30)
        XCTAssertTrue(viewModel.includeMessages)
        XCTAssertTrue(viewModel.wifiOnly)
    }

    // MARK: - Backup Settings Tests

    func testBackupSettingsDefault() {
        let settings = BackupSettings()

        XCTAssertFalse(settings.autoBackupEnabled)
        XCTAssertEqual(settings.backupFrequency, .daily)
        XCTAssertEqual(settings.backupTimeUtc, "03:00")
        XCTAssertEqual(settings.retentionDays, 30)
        XCTAssertTrue(settings.includeMessages)
        XCTAssertTrue(settings.wifiOnly)
    }

    func testBackupSettingsCustom() {
        let settings = BackupSettings(
            autoBackupEnabled: true,
            backupFrequency: .weekly,
            backupTimeUtc: "04:30",
            retentionDays: 60,
            includeMessages: false,
            wifiOnly: false
        )

        XCTAssertTrue(settings.autoBackupEnabled)
        XCTAssertEqual(settings.backupFrequency, .weekly)
        XCTAssertEqual(settings.backupTimeUtc, "04:30")
        XCTAssertEqual(settings.retentionDays, 60)
        XCTAssertFalse(settings.includeMessages)
        XCTAssertFalse(settings.wifiOnly)
    }

    // MARK: - Backup Frequency Tests

    func testBackupFrequency_rawValues() {
        XCTAssertEqual(BackupFrequency.daily.rawValue, "daily")
        XCTAssertEqual(BackupFrequency.weekly.rawValue, "weekly")
        XCTAssertEqual(BackupFrequency.monthly.rawValue, "monthly")
    }

    func testBackupFrequency_displayName() {
        XCTAssertEqual(BackupFrequency.daily.displayName, "Daily")
        XCTAssertEqual(BackupFrequency.weekly.displayName, "Weekly")
        XCTAssertEqual(BackupFrequency.monthly.displayName, "Monthly")
    }

    func testBackupFrequency_intervalDays() {
        XCTAssertEqual(BackupFrequency.daily.intervalDays, 1)
        XCTAssertEqual(BackupFrequency.weekly.intervalDays, 7)
        XCTAssertEqual(BackupFrequency.monthly.intervalDays, 30)
    }

    // MARK: - Time Parsing Tests

    func testTimeString_parsing() {
        // Valid times
        XCTAssertTrue(isValidTimeFormat("00:00"))
        XCTAssertTrue(isValidTimeFormat("03:00"))
        XCTAssertTrue(isValidTimeFormat("12:30"))
        XCTAssertTrue(isValidTimeFormat("23:59"))

        // Invalid times
        XCTAssertFalse(isValidTimeFormat(""))
        XCTAssertFalse(isValidTimeFormat("3:00"))
        XCTAssertFalse(isValidTimeFormat("25:00"))
        XCTAssertFalse(isValidTimeFormat("12:60"))
        XCTAssertFalse(isValidTimeFormat("invalid"))
    }

    // MARK: - Helpers

    private func isValidTimeFormat(_ time: String) -> Bool {
        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return false
        }
        return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59
    }
}
