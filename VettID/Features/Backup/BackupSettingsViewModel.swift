import Foundation

/// ViewModel for backup settings screen
@MainActor
final class BackupSettingsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var settings: BackupSettings = BackupSettings()
    @Published var backupTime: Date = Date()
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var isBackingUp = false
    @Published private(set) var lastBackupDate: Date?
    @Published private(set) var credentialBackupExists = false
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Public Methods

    /// Load settings from server
    func loadSettings() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Load backup settings
            settings = try await apiClient.getBackupSettings(authToken: authToken)
            backupTime = parseTimeString(settings.backupTimeUtc)

            // Load credential backup status
            let status = try await apiClient.getCredentialBackupStatus(authToken: authToken)
            credentialBackupExists = status.exists

            // Load last backup date from backup list
            let backups = try await apiClient.listBackups(authToken: authToken)
            lastBackupDate = backups.first?.createdAt

            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Save settings to server
    func saveSettings() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isSaving = true
        errorMessage = nil

        // Update time string from Date
        settings.backupTimeUtc = formatTimeString(backupTime)

        do {
            settings = try await apiClient.updateBackupSettings(settings, authToken: authToken)
            isSaving = false
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    /// Trigger immediate backup
    func backupNow() async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isBackingUp = true
        errorMessage = nil

        do {
            let backup = try await apiClient.triggerBackup(
                includeMessages: settings.includeMessages,
                authToken: authToken
            )
            lastBackupDate = backup.createdAt
            isBackingUp = false
        } catch {
            errorMessage = error.localizedDescription
            isBackingUp = false
        }
    }

    /// Clear error message
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private Helpers

    /// Parse HH:mm string to Date
    private func parseTimeString(_ timeString: String) -> Date {
        let components = timeString.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else {
            return Date()
        }

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        return Calendar.current.date(from: dateComponents) ?? Date()
    }

    /// Format Date to HH:mm string
    private func formatTimeString(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }
}
