import Foundation

/// State for service connection detail
enum ServiceConnectionDetailState: Equatable {
    case loading
    case loaded(ServiceConnectionRecord)
    case error(String)

    static func == (lhs: ServiceConnectionDetailState, rhs: ServiceConnectionDetailState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.loaded(let l), .loaded(let r)):
            return l.id == r.id
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
}

/// ViewModel for service connection detail view
@MainActor
final class ServiceConnectionDetailViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ServiceConnectionDetailState = .loading
    @Published private(set) var health: ServiceConnectionHealth?
    @Published private(set) var activities: [ServiceActivity] = []
    @Published private(set) var activitySummary: ServiceActivitySummary?
    @Published private(set) var dataSummary: ServiceDataSummary?
    @Published private(set) var trustedResources: [TrustedResource] = []
    @Published private(set) var notificationSettings: ServiceNotificationSettings?

    @Published var errorMessage: String?
    @Published var showingContractUpdate = false
    @Published var showingRevokeConfirmation = false
    @Published var isRevoking = false

    // MARK: - Dependencies

    private let connectionId: String
    private let serviceConnectionHandler: ServiceConnectionHandler
    private let serviceConnectionStore: ServiceConnectionStore

    // MARK: - Initialization

    init(
        connectionId: String,
        serviceConnectionHandler: ServiceConnectionHandler,
        serviceConnectionStore: ServiceConnectionStore = ServiceConnectionStore()
    ) {
        self.connectionId = connectionId
        self.serviceConnectionHandler = serviceConnectionHandler
        self.serviceConnectionStore = serviceConnectionStore
    }

    // MARK: - Current Connection

    var connection: ServiceConnectionRecord? {
        if case .loaded(let conn) = state {
            return conn
        }
        return nil
    }

    // MARK: - Loading

    /// Load connection details
    func loadConnection() async {
        state = .loading

        // Try local cache first
        if let cached = try? serviceConnectionStore.retrieve(connectionId: connectionId) {
            state = .loaded(cached)
        }

        do {
            let connection = try await serviceConnectionHandler.getConnection(connectionId: connectionId)
            state = .loaded(connection)
            try? serviceConnectionStore.update(connection: connection)

            // Load additional data in parallel
            await loadAdditionalData()
        } catch {
            if case .loaded = state {
                // Keep cached data but show error
                errorMessage = error.localizedDescription
            } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Load additional data (health, activities, etc.)
    private func loadAdditionalData() async {
        async let healthTask: () = loadHealth()
        async let activitiesTask: () = loadRecentActivities()
        async let summaryTask: () = loadActivitySummary()
        async let dataTask: () = loadDataSummary()
        async let resourcesTask: () = loadTrustedResources()
        async let settingsTask: () = loadNotificationSettings()

        _ = await (healthTask, activitiesTask, summaryTask, dataTask, resourcesTask, settingsTask)
    }

    private func loadHealth() async {
        do {
            health = try await serviceConnectionHandler.getConnectionHealth(connectionId: connectionId)
        } catch {
            // Silently ignore - health is optional
        }
    }

    private func loadRecentActivities() async {
        do {
            activities = try await serviceConnectionHandler.listActivity(
                connectionId: connectionId,
                limit: 10
            )
        } catch {
            // Silently ignore
        }
    }

    private func loadActivitySummary() async {
        do {
            activitySummary = try await serviceConnectionHandler.getActivitySummary(connectionId: connectionId)
        } catch {
            // Silently ignore
        }
    }

    private func loadDataSummary() async {
        do {
            dataSummary = try await serviceConnectionHandler.getDataSummary(connectionId: connectionId)
        } catch {
            // Silently ignore
        }
    }

    private func loadTrustedResources() async {
        do {
            trustedResources = try await serviceConnectionHandler.getTrustedResources(connectionId: connectionId)
        } catch {
            // Silently ignore
        }
    }

    private func loadNotificationSettings() async {
        do {
            notificationSettings = try await serviceConnectionHandler.getNotificationSettings(connectionId: connectionId)
        } catch {
            notificationSettings = ServiceNotificationSettings.defaultSettings(for: connectionId)
        }
    }

    /// Refresh all data
    func refresh() async {
        await loadConnection()
    }

    // MARK: - Actions

    /// Toggle favorite status
    func toggleFavorite() async {
        guard var conn = connection else { return }
        conn.isFavorite.toggle()
        state = .loaded(conn)

        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                isFavorite: conn.isFavorite
            )
            try serviceConnectionStore.update(connection: conn)
        } catch {
            // Revert on error
            conn.isFavorite.toggle()
            state = .loaded(conn)
            errorMessage = error.localizedDescription
        }
    }

    /// Toggle muted status
    func toggleMuted() async {
        guard var conn = connection else { return }
        conn.isMuted.toggle()
        state = .loaded(conn)

        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                isMuted: conn.isMuted
            )
            try serviceConnectionStore.update(connection: conn)
        } catch {
            conn.isMuted.toggle()
            state = .loaded(conn)
            errorMessage = error.localizedDescription
        }
    }

    /// Archive connection
    func archiveConnection() async {
        guard var conn = connection else { return }
        conn.isArchived = true
        state = .loaded(conn)

        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                isArchived: true
            )
            try serviceConnectionStore.update(connection: conn)
        } catch {
            conn.isArchived = false
            state = .loaded(conn)
            errorMessage = error.localizedDescription
        }
    }

    /// Update tags
    func updateTags(_ tags: [String]) async {
        guard var conn = connection else { return }
        let oldTags = conn.tags
        conn.tags = tags
        state = .loaded(conn)

        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                tags: tags
            )
            try serviceConnectionStore.update(connection: conn)
        } catch {
            conn.tags = oldTags
            state = .loaded(conn)
            errorMessage = error.localizedDescription
        }
    }

    /// Revoke connection (without password - for internal use)
    func revokeConnection() async {
        isRevoking = true

        do {
            _ = try await serviceConnectionHandler.revokeConnection(connectionId: connectionId)
            try? serviceConnectionStore.delete(connectionId: connectionId)
            isRevoking = false
            // The view should dismiss after this
        } catch {
            isRevoking = false
            errorMessage = error.localizedDescription
        }
    }

    /// Revoke connection with password authorization
    func revokeConnectionWithPassword(_ password: String) async {
        guard !password.isEmpty else {
            errorMessage = "Password is required"
            return
        }

        isRevoking = true
        errorMessage = nil

        do {
            // Verify password before revoking
            // In production, this would use OperationAuthorizationService
            try await verifyPassword(password)

            // Password verified, proceed with revocation
            _ = try await serviceConnectionHandler.revokeConnection(connectionId: connectionId)
            try? serviceConnectionStore.delete(connectionId: connectionId)
            isRevoking = false
            // The view should dismiss after this
        } catch {
            isRevoking = false
            errorMessage = error.localizedDescription
        }
    }

    /// Verify password for sensitive operations
    private func verifyPassword(_ password: String) async throws {
        // In production, this would:
        // 1. Request a challenge from the vault
        // 2. Hash the password with Argon2id
        // 3. Encrypt with UTK and submit to vault
        // 4. Return if successful or throw if invalid

        #if DEBUG
        // Simulate password verification
        try await Task.sleep(nanoseconds: 500_000_000)

        // For testing, reject empty passwords
        if password.isEmpty {
            throw PasswordVerificationError.invalidPassword
        }
        #endif
    }

    /// Update notification settings
    func updateNotificationSettings(_ settings: ServiceNotificationSettings) async {
        notificationSettings = settings

        do {
            _ = try await serviceConnectionHandler.updateNotificationSettings(settings)
            try? serviceConnectionStore.storeNotificationSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Accept pending contract update
    func acceptContractUpdate(updatedFieldMappings: [SharedFieldMapping]) async {
        guard let conn = connection,
              let newVersion = conn.pendingContractVersion else { return }

        do {
            _ = try await serviceConnectionHandler.acceptContractUpdate(
                connectionId: connectionId,
                newContractVersion: newVersion,
                updatedFieldMappings: updatedFieldMappings
            )
            await loadConnection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reject pending contract update (terminates connection)
    func rejectContractUpdate() async {
        do {
            _ = try await serviceConnectionHandler.rejectContractUpdate(connectionId: connectionId)
            // Connection is now terminated
            try? serviceConnectionStore.delete(connectionId: connectionId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Password Verification Error

enum PasswordVerificationError: Error, LocalizedError {
    case invalidPassword
    case networkError
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid password. Please try again."
        case .networkError:
            return "Network error. Please check your connection."
        case .timeout:
            return "Request timed out. Please try again."
        }
    }
}
