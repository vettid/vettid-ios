import Foundation

/// ViewModel for connection detail screen
@MainActor
final class ConnectionDetailViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var connection: Connection?
    @Published private(set) var peerProfile: Profile?
    @Published private(set) var peerProfileData: PeerProfileData?
    @Published private(set) var connectionStats: ConnectionStats?
    @Published private(set) var isLoading = true
    @Published private(set) var isRevoking = false
    @Published private(set) var isRotatingKeys = false
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let cryptoManager: ConnectionCryptoManager
    private let authTokenProvider: @Sendable () -> String?
    var connectionsClient: ConnectionsClient?
    /// Phase 1.9: injected by ConnectionDetailView via .task — used to
    /// initiate identity-verify challenges from the persistent verify
    /// row in the Them tab. Optional so the screen still works if the
    /// vault isn't warm yet.
    var grantsClient: GrantsClient?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        cryptoManager: ConnectionCryptoManager = ConnectionCryptoManager(),
        authTokenProvider: @escaping @Sendable () -> String?,
        connectionsClient: ConnectionsClient? = nil
    ) {
        self.apiClient = apiClient
        self.cryptoManager = cryptoManager
        self.authTokenProvider = authTokenProvider
        self.connectionsClient = connectionsClient
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

    // MARK: - NATS Connection Actions

    /// Respond to a pending connection (accept or reject) via NATS
    /// - Parameters:
    ///   - connectionId: The connection to respond to
    ///   - response: "accept" or "reject"
    func respondToConnection(connectionId: String, response: String) async {
        guard let client = connectionsClient else {
            errorMessage = "Connections client not configured"
            return
        }

        do {
            let record = try await client.respond(connectionId: connectionId, response: response)

            // Update peer profile from response
            peerProfileData = record.peerProfile

            // Update connection status locally
            if var updated = connection {
                let newStatus: ConnectionStatus = response == "accept" ? .active : .revoked
                updated = Connection(
                    id: updated.id,
                    peerGuid: updated.peerGuid,
                    peerDisplayName: record.peerProfile?.displayName ?? updated.peerDisplayName,
                    peerAvatarUrl: record.peerProfile?.photo ?? updated.peerAvatarUrl,
                    status: newStatus,
                    createdAt: updated.createdAt,
                    lastMessageAt: updated.lastMessageAt,
                    unreadCount: updated.unreadCount,
                    direction: record.direction
                )
                connection = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Initiate an identity-verify challenge against the current
    /// connection (Phase 1.9). Fires `connection-authenticate.request`
    /// through `GrantsClient`. The peer's vault surfaces it as a
    /// pending verify request, which they approve via their own
    /// `IdentityVerifyApprovalView`. When the verdict lands on
    /// `forApp.verify.*`, `GrantsRepository.handleEvent` re-hydrates
    /// and posts `Notification.Name.verifyStateChanged`; the
    /// VerifyIdentityRow in the Them tab observes and refreshes.
    func startVerifyChallenge() async {
        guard let connectionId = connection?.id else { return }
        guard let client = grantsClient else {
            errorMessage = "Vault not warm yet — try again after unlocking."
            return
        }
        do {
            _ = try await client.requestVerify(
                connectionId: connectionId,
                challenge: "" // routine periodic verify — no custom message
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rotate credentials for a connection via NATS
    /// - Parameter connectionId: The connection to rotate keys for
    func rotateKeys(connectionId: String) async {
        guard let client = connectionsClient else {
            errorMessage = "Connections client not configured"
            return
        }

        isRotatingKeys = true
        errorMessage = nil

        do {
            let record = try await client.rotate(connectionId: connectionId)

            // Update local state with rotation timestamp
            let isoFormatter = ISO8601DateFormatter()
            let rotatedDate = record.lastRotatedAt.flatMap { isoFormatter.date(from: $0) }

            if var updated = connection {
                updated = Connection(
                    id: updated.id,
                    peerGuid: updated.peerGuid,
                    peerDisplayName: updated.peerDisplayName,
                    peerAvatarUrl: updated.peerAvatarUrl,
                    status: updated.status,
                    createdAt: updated.createdAt,
                    lastMessageAt: updated.lastMessageAt,
                    unreadCount: updated.unreadCount,
                    direction: updated.direction,
                    e2ePublicKey: record.e2ePublicKey,
                    lastRotatedAt: rotatedDate
                )
                connection = updated
            }

            isRotatingKeys = false
        } catch {
            errorMessage = error.localizedDescription
            isRotatingKeys = false
        }
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }
}
