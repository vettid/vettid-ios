import Foundation

/// ViewModel for backup list screen
@MainActor
final class BackupListViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: BackupListState = .loading
    @Published private(set) var isCreatingBackup = false

    // MARK: - Properties

    private var backups: [Backup] = []

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

    /// Load backups from server
    func loadBackups() async {
        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        state = .loading

        do {
            backups = try await apiClient.listBackups(authToken: authToken)

            if backups.isEmpty {
                state = .empty
            } else {
                // Sort by date, newest first
                backups.sort { $0.createdAt > $1.createdAt }
                state = .loaded(backups)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Refresh backups
    func refresh() async {
        await loadBackups()
    }

    /// Create a new backup
    func createBackup(includeMessages: Bool = true) async {
        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        isCreatingBackup = true

        do {
            let newBackup = try await apiClient.triggerBackup(
                includeMessages: includeMessages,
                authToken: authToken
            )

            // Add to list and update state
            backups.insert(newBackup, at: 0)
            state = .loaded(backups)
            isCreatingBackup = false
        } catch {
            isCreatingBackup = false
            // Keep existing state but could show an alert
        }
    }

    /// Delete backups at given indices
    func deleteBackups(at indexSet: IndexSet) {
        guard case .loaded(var currentBackups) = state else { return }

        let backupsToDelete = indexSet.map { currentBackups[$0] }

        // Remove from local list immediately
        currentBackups.remove(atOffsets: indexSet)
        backups = currentBackups

        if backups.isEmpty {
            state = .empty
        } else {
            state = .loaded(backups)
        }

        // Delete from server in background
        Task {
            guard let authToken = authTokenProvider() else { return }

            for backup in backupsToDelete {
                try? await apiClient.deleteBackup(backupId: backup.id, authToken: authToken)
            }
        }
    }

    /// Delete a single backup by ID
    func deleteBackup(_ backupId: String) async {
        guard let authToken = authTokenProvider() else { return }

        do {
            try await apiClient.deleteBackup(backupId: backupId, authToken: authToken)

            // Remove from local list
            backups.removeAll { $0.id == backupId }

            if backups.isEmpty {
                state = .empty
            } else {
                state = .loaded(backups)
            }
        } catch {
            // Reload to sync state
            await loadBackups()
        }
    }
}
