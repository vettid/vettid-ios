import XCTest
@testable import VettID

/// Tests for Backup-related types
final class BackupTypesTests: XCTestCase {

    // MARK: - Backup Tests

    func testBackup_decoding() throws {
        let json = """
        {
            "id": "backup-123",
            "created_at": "2025-01-01T12:00:00Z",
            "size_bytes": 1048576,
            "type": "manual",
            "status": "complete",
            "encryption_method": "ChaCha20-Poly1305"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(backup.id, "backup-123")
        XCTAssertEqual(backup.sizeBytes, 1048576)
        XCTAssertEqual(backup.type, .manual)
        XCTAssertEqual(backup.status, .complete)
        XCTAssertEqual(backup.encryptionMethod, "ChaCha20-Poly1305")
    }

    func testBackupType_allCases() {
        XCTAssertEqual(BackupType.auto.rawValue, "auto")
        XCTAssertEqual(BackupType.manual.rawValue, "manual")
    }

    func testBackupStatus_allCases() {
        XCTAssertEqual(BackupStatus.complete.rawValue, "complete")
        XCTAssertEqual(BackupStatus.partial.rawValue, "partial")
        XCTAssertEqual(BackupStatus.failed.rawValue, "failed")
    }

    // MARK: - BackupSettings Tests

    func testBackupSettings_defaultValues() {
        let settings = BackupSettings()

        XCTAssertFalse(settings.autoBackupEnabled)
        XCTAssertEqual(settings.backupFrequency, .daily)
        XCTAssertEqual(settings.backupTimeUtc, "03:00")
        XCTAssertEqual(settings.retentionDays, 30)
        XCTAssertTrue(settings.includeMessages)
        XCTAssertTrue(settings.wifiOnly)
    }

    func testBackupSettings_decoding() throws {
        let json = """
        {
            "auto_backup_enabled": true,
            "backup_frequency": "weekly",
            "backup_time_utc": "02:30",
            "retention_days": 60,
            "include_messages": false,
            "wifi_only": false
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let settings = try decoder.decode(BackupSettings.self, from: json.data(using: .utf8)!)

        XCTAssertTrue(settings.autoBackupEnabled)
        XCTAssertEqual(settings.backupFrequency, .weekly)
        XCTAssertEqual(settings.backupTimeUtc, "02:30")
        XCTAssertEqual(settings.retentionDays, 60)
        XCTAssertFalse(settings.includeMessages)
        XCTAssertFalse(settings.wifiOnly)
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

    // MARK: - CredentialBackupStatus Tests

    func testCredentialBackupStatus_decoding() throws {
        let json = """
        {
            "exists": true,
            "created_at": "2025-01-01T12:00:00Z",
            "last_verified_at": "2025-01-02T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(CredentialBackupStatus.self, from: json.data(using: .utf8)!)

        XCTAssertTrue(status.exists)
        XCTAssertNotNil(status.createdAt)
        XCTAssertNotNil(status.lastVerifiedAt)
    }

    func testCredentialBackupStatus_decodingWithNulls() throws {
        let json = """
        {
            "exists": false,
            "created_at": null,
            "last_verified_at": null
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(CredentialBackupStatus.self, from: json.data(using: .utf8)!)

        XCTAssertFalse(status.exists)
        XCTAssertNil(status.createdAt)
        XCTAssertNil(status.lastVerifiedAt)
    }

    // MARK: - RestoreResult Tests

    func testRestoreResult_decoding() throws {
        let json = """
        {
            "success": true,
            "restored_items": 42,
            "conflicts": ["item1", "item2"],
            "requires_reauth": false
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(RestoreResult.self, from: json.data(using: .utf8)!)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.restoredItems, 42)
        XCTAssertEqual(result.conflicts.count, 2)
        XCTAssertFalse(result.requiresReauth)
    }

    // MARK: - BackupContents Tests

    func testBackupContents_decoding() throws {
        let json = """
        {
            "credentials_count": 5,
            "connections_count": 10,
            "messages_count": 100,
            "handlers_count": 3,
            "profile_included": true
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let contents = try decoder.decode(BackupContents.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(contents.credentialsCount, 5)
        XCTAssertEqual(contents.connectionsCount, 10)
        XCTAssertEqual(contents.messagesCount, 100)
        XCTAssertEqual(contents.handlersCount, 3)
        XCTAssertTrue(contents.profileIncluded)
    }
}
