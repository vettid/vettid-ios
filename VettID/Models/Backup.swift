import Foundation

// MARK: - Backup

/// Represents a vault backup
struct Backup: Codable, Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let sizeBytes: Int64
    let type: BackupType
    let status: BackupStatus
    let encryptionMethod: String
}

/// Type of backup
enum BackupType: String, Codable {
    case auto
    case manual
}

/// Status of a backup
enum BackupStatus: String, Codable {
    case complete
    case partial
    case failed
}

// MARK: - Backup Settings

/// Backup configuration settings
struct BackupSettings: Codable, Equatable {
    var autoBackupEnabled: Bool
    var backupFrequency: BackupFrequency
    var backupTimeUtc: String  // HH:mm format
    var retentionDays: Int
    var includeMessages: Bool
    var wifiOnly: Bool

    init(
        autoBackupEnabled: Bool = false,
        backupFrequency: BackupFrequency = .daily,
        backupTimeUtc: String = "03:00",
        retentionDays: Int = 30,
        includeMessages: Bool = true,
        wifiOnly: Bool = true
    ) {
        self.autoBackupEnabled = autoBackupEnabled
        self.backupFrequency = backupFrequency
        self.backupTimeUtc = backupTimeUtc
        self.retentionDays = retentionDays
        self.includeMessages = includeMessages
        self.wifiOnly = wifiOnly
    }
}

/// Backup frequency options
enum BackupFrequency: String, Codable, CaseIterable {
    case daily
    case weekly
    case monthly

    var displayName: String {
        rawValue.capitalized
    }

    var intervalDays: Int {
        switch self {
        case .daily: return 1
        case .weekly: return 7
        case .monthly: return 30
        }
    }
}

// MARK: - Credential Backup Status

/// Status of credential backup
struct CredentialBackupStatus: Codable, Equatable {
    let exists: Bool
    let createdAt: Date?
    let lastVerifiedAt: Date?
}

// MARK: - Restore Result

/// Result of a backup restore operation
struct RestoreResult: Codable, Equatable {
    let success: Bool
    let restoredItems: Int
    let conflicts: [String]
    let requiresReauth: Bool
}

// MARK: - Backup Contents

/// Contents of a backup for preview
struct BackupContents: Codable, Equatable {
    let credentialsCount: Int
    let connectionsCount: Int
    let messagesCount: Int
    let handlersCount: Int
    let profileIncluded: Bool
}

// MARK: - API Requests/Responses

/// Request to trigger a backup
struct TriggerBackupRequest: Codable {
    let includeMessages: Bool

    init(includeMessages: Bool = true) {
        self.includeMessages = includeMessages
    }
}

/// Request to restore from backup
struct RestoreBackupRequest: Codable {
    let backupId: String
}

/// Encrypted credential backup data
struct EncryptedCredentialBackup: Codable {
    let ciphertext: Data
    let salt: Data
    let nonce: Data
}

/// Request to create credential backup
struct CreateCredentialBackupRequest: Codable {
    let encryptedBlob: String  // Base64 encoded
    let salt: String           // Base64 encoded
    let nonce: String          // Base64 encoded
}

/// Request to recover credentials
struct RecoverCredentialsRequest: Codable {
    let deviceId: String
    let devicePublicKey: String  // Base64 encoded
}

/// Response from credential recovery
struct RecoverCredentialsResponse: Codable {
    let encryptedBlob: String  // Base64 encoded
    let salt: String           // Base64 encoded
    let nonce: String          // Base64 encoded
}

// MARK: - Backup List State

/// State for backup list view
enum BackupListState: Equatable {
    case loading
    case empty
    case loaded([Backup])
    case error(String)
}

