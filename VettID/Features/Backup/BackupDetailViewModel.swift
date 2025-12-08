import Foundation

/// ViewModel for backup detail screen
@MainActor
final class BackupDetailViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var backup: Backup?
    @Published private(set) var backupContents: BackupContents?
    @Published private(set) var isLoading = true
    @Published private(set) var isRestoring = false
    @Published private(set) var isDeleting = false
    @Published var errorMessage: String?
    @Published var restoreResult: RestoreResult?

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

    /// Load backup details
    func loadBackup(_ backupId: String) async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await apiClient.getBackup(backupId: backupId, authToken: authToken)
            backup = response.backup
            backupContents = response.contents
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Restore from this backup
    func restoreBackup() async {
        guard let backup = backup,
              let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isRestoring = true
        errorMessage = nil

        do {
            let result = try await apiClient.restoreBackup(backupId: backup.id, authToken: authToken)
            restoreResult = result
            isRestoring = false
        } catch {
            errorMessage = error.localizedDescription
            isRestoring = false
        }
    }

    /// Delete this backup
    func deleteBackup() async -> Bool {
        guard let backup = backup,
              let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return false
        }

        isDeleting = true
        errorMessage = nil

        do {
            try await apiClient.deleteBackup(backupId: backup.id, authToken: authToken)
            isDeleting = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isDeleting = false
            return false
        }
    }

    /// Clear error message
    func clearError() {
        errorMessage = nil
    }

    /// Clear restore result
    func clearRestoreResult() {
        restoreResult = nil
    }
}
