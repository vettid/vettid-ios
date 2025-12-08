import Foundation

/// ViewModel for connection detail screen
@MainActor
final class ConnectionDetailViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var connection: Connection?
    @Published private(set) var peerProfile: Profile?
    @Published private(set) var connectionStats: ConnectionStats?
    @Published private(set) var isLoading = true
    @Published private(set) var isRevoking = false
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let cryptoManager: ConnectionCryptoManager
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        cryptoManager: ConnectionCryptoManager = ConnectionCryptoManager(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.cryptoManager = cryptoManager
        self.authTokenProvider = authTokenProvider
    }

    // MARK: - Loading

    /// Load connection details
    func loadConnection(_ connectionId: String) async {
        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Load connection details
            connection = try await apiClient.getConnection(id: connectionId, authToken: authToken)

            // Load peer profile
            peerProfile = try await apiClient.getConnectionProfile(connectionId: connectionId, authToken: authToken)

            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Revoke Connection

    /// Revoke the connection
    func revokeConnection() async {
        guard let connectionId = connection?.id else { return }

        guard let authToken = authTokenProvider() else {
            errorMessage = "Not authenticated"
            return
        }

        isRevoking = true
        errorMessage = nil

        do {
            try await apiClient.revokeConnection(connectionId: connectionId, authToken: authToken)

            // Delete connection key from Keychain
            try? cryptoManager.deleteConnectionKey(connectionId: connectionId)

            // Update local state
            if var updated = connection {
                updated = Connection(
                    id: updated.id,
                    peerGuid: updated.peerGuid,
                    peerDisplayName: updated.peerDisplayName,
                    peerAvatarUrl: updated.peerAvatarUrl,
                    status: .revoked,
                    createdAt: updated.createdAt,
                    lastMessageAt: updated.lastMessageAt,
                    unreadCount: updated.unreadCount
                )
                connection = updated
            }

            isRevoking = false
        } catch {
            errorMessage = error.localizedDescription
            isRevoking = false
        }
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }
}
