import Foundation

/// State for connections list
enum ConnectionsListState: Equatable {
    case loading
    case empty
    case loaded([Connection])
    case error(String)

    var connections: [Connection] {
        if case .loaded(let connections) = self {
            return connections
        }
        return []
    }
}

/// ViewModel for connections list
@MainActor
final class ConnectionsViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ConnectionsListState = .loading
    @Published private(set) var serviceConnections: [ServiceConnectionRecord] = []
    @Published private(set) var isLoadingServices = false
    @Published var searchQuery = ""
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?
    private let serviceConnectionHandler: ServiceConnectionHandler?
    private let serviceConnectionStore: ServiceConnectionStore
    var connectionsClient: ConnectionsClient?
    var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Private State

    private var allConnections: [Connection] = []
    private var lastMessages: [String: Message] = [:]
    private var realtimeTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?,
        serviceConnectionHandler: ServiceConnectionHandler? = nil,
        serviceConnectionStore: ServiceConnectionStore = ServiceConnectionStore(),
        connectionsClient: ConnectionsClient? = nil,
        ownerSpaceClient: OwnerSpaceClient? = nil
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
        self.serviceConnectionHandler = serviceConnectionHandler
        self.serviceConnectionStore = serviceConnectionStore
        self.connectionsClient = connectionsClient
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Service Connections

    /// Filtered service connections based on search query
    var filteredServiceConnections: [ServiceConnectionRecord] {
        guard !searchQuery.isEmpty else { return serviceConnections }
        return serviceConnections.filter { connection in
            connection.serviceProfile.serviceName.localizedCaseInsensitiveContains(searchQuery) ||
            connection.serviceProfile.organization.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    /// Count of pending contract updates
    var pendingServiceUpdatesCount: Int {
        serviceConnections.filter { $0.pendingContractVersion != nil }.count
    }

    // MARK: - Computed Properties

    /// Filtered connections based on search query
    var filteredConnections: [Connection] {
        guard !searchQuery.isEmpty else { return allConnections }
        return allConnections.filter { connection in
            connection.peerDisplayName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // MARK: - Loading

    /// Load connections, trying NATS first with HTTP fallback
    func loadConnections() async {
        state = .loading

        // Try NATS-based loading first
        if connectionsClient != nil {
            let natsSuccess = await loadFromNats()
            if natsSuccess {
                // Still load service connections in parallel
                await loadServiceConnections()
                return
            }
            // Fall through to HTTP on NATS failure
        }

        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        // Load peer connections and service connections in parallel
        async let peerConnectionsTask: () = loadPeerConnections(authToken: authToken)
        async let serviceConnectionsTask: () = loadServiceConnections()

        _ = await (peerConnectionsTask, serviceConnectionsTask)
    }

    /// Load connections from vault via NATS
    /// - Returns: true if NATS loading succeeded
    @discardableResult
    func loadFromNats() async -> Bool {
        guard let client = connectionsClient else { return false }

        do {
            let listResult = try await client.list(status: "active")
            let isoFormatter = ISO8601DateFormatter()

            let connections = listResult.items.map { record -> Connection in
                let displayName = record.peerProfile?.displayName ?? record.label
                let createdDate = isoFormatter.date(from: record.createdAt) ?? Date()
                let expiresDate = record.expiresAt.flatMap { isoFormatter.date(from: $0) }
                let rotatedDate = record.lastRotatedAt.flatMap { isoFormatter.date(from: $0) }

                let status: ConnectionStatus
                switch record.status {
                case "active": status = .active
                case "revoked": status = .revoked
                default: status = .pending
                }

                return Connection(
                    id: record.connectionId,
                    peerGuid: record.peerGuid,
                    peerDisplayName: displayName,
                    peerAvatarUrl: record.peerProfile?.photo,
                    status: status,
                    createdAt: createdDate,
                    direction: record.direction,
                    e2ePublicKey: record.e2ePublicKey,
                    peerProfile: record.peerProfile,
                    lastRotatedAt: rotatedDate,
                    expiresAt: expiresDate
                )
            }

            allConnections = connections.sorted {
                ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt)
            }

            if allConnections.isEmpty && serviceConnections.isEmpty {
                state = .empty
            } else {
                state = .loaded(filteredConnections)
            }

            return true
        } catch {
            #if DEBUG
            print("[ConnectionsViewModel] NATS loadFromNats failed, falling back to HTTP: \(error)")
            #endif
            return false
        }
    }

    /// Start listening for real-time connection status updates via OwnerSpaceClient
    func startRealtimeUpdates() {
        guard let ownerSpace = ownerSpaceClient else { return }
        realtimeTask?.cancel()

        realtimeTask = Task { [weak self] in
            // Listen for connection acceptances
            let acceptanceTask = Task {
                for await acceptance in ownerSpace.connectionAcceptances {
                    guard let self = self, !Task.isCancelled else { break }
                    await MainActor.run {
                        let displayName = acceptance.peerAlias ?? acceptance.peerGuid
                        let newConnection = Connection(
                            id: acceptance.connectionId,
                            peerGuid: acceptance.peerGuid,
                            peerDisplayName: displayName,
                            status: .active,
                            createdAt: Date()
                        )
                        if !self.allConnections.contains(where: { $0.id == acceptance.connectionId }) {
                            self.allConnections.insert(newConnection, at: 0)
                            self.state = .loaded(self.filteredConnections)
                        }
                    }
                }
            }

            // Listen for connection status updates (revocations, etc.)
            let statusTask = Task {
                for await update in ownerSpace.connectionStatusUpdates {
                    guard let self = self, !Task.isCancelled else { break }
                    await MainActor.run {
                        if let index = self.allConnections.firstIndex(where: { $0.id == update.connectionId }) {
                            let existing = self.allConnections[index]
                            let newStatus: ConnectionStatus = update.type == "revoked" ? .revoked : existing.status
                            self.allConnections[index] = Connection(
                                id: existing.id,
                                peerGuid: existing.peerGuid,
                                peerDisplayName: update.peerAlias ?? existing.peerDisplayName,
                                peerAvatarUrl: existing.peerAvatarUrl,
                                status: newStatus,
                                createdAt: existing.createdAt,
                                lastMessageAt: existing.lastMessageAt,
                                unreadCount: existing.unreadCount
                            )
                            self.state = .loaded(self.filteredConnections)
                        }
                    }
                }
            }

            // Wait for cancellation
            _ = await (acceptanceTask.value, statusTask.value)
        }
    }

    /// Stop real-time updates
    func stopRealtimeUpdates() {
        realtimeTask?.cancel()
        realtimeTask = nil
    }

    private func loadPeerConnections(authToken: String) async {
        do {
            let connections = try await apiClient.listConnections(authToken: authToken)
            allConnections = connections.sorted {
                ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt)
            }

            if allConnections.isEmpty && serviceConnections.isEmpty {
                state = .empty
            } else {
                state = .loaded(filteredConnections)
            }
        } catch {
            if serviceConnections.isEmpty {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func loadServiceConnections() async {
        isLoadingServices = true

        // Try local cache first
        if let cached = try? serviceConnectionStore.listConnections() {
            serviceConnections = cached.filter { $0.status == .active && !$0.isArchived }
        }

        // Load from network if handler available
        if let handler = serviceConnectionHandler {
            do {
                let connections = try await handler.listConnections()
                serviceConnections = connections.filter { $0.status == .active && !$0.isArchived }
                // Update cache
                for connection in connections {
                    try? serviceConnectionStore.update(connection: connection)
                }
            } catch {
                // Keep cached data on network error
            }
        }

        isLoadingServices = false

        // Update state if we have data now
        if !allConnections.isEmpty || !serviceConnections.isEmpty {
            state = .loaded(filteredConnections)
        }
    }

    /// Refresh connections
    func refresh() async {
        await loadConnections()
    }

    /// Toggle favorite status for a service connection
    func toggleServiceFavorite(_ connectionId: String) async {
        guard var connection = serviceConnections.first(where: { $0.id == connectionId }) else { return }
        connection.isFavorite.toggle()

        // Update local state immediately
        if let index = serviceConnections.firstIndex(where: { $0.id == connectionId }) {
            serviceConnections[index] = connection
        }

        if let handler = serviceConnectionHandler {
            do {
                _ = try await handler.updateConnection(
                    connectionId: connectionId,
                    isFavorite: connection.isFavorite
                )
                try? serviceConnectionStore.update(connection: connection)
            } catch {
                // Revert on error
                connection.isFavorite.toggle()
                if let index = serviceConnections.firstIndex(where: { $0.id == connectionId }) {
                    serviceConnections[index] = connection
                }
            }
        }
    }

    // MARK: - Last Message

    /// Get last message for a connection
    func lastMessage(for connectionId: String) -> Message? {
        return lastMessages[connectionId]
    }

    /// Load last messages for all connections
    func loadLastMessages() async {
        guard let authToken = authTokenProvider() else { return }

        for connection in allConnections {
            do {
                let messages = try await apiClient.getMessageHistory(
                    connectionId: connection.id,
                    limit: 1,
                    authToken: authToken
                )
                if let lastMessage = messages.first {
                    lastMessages[connection.id] = lastMessage
                }
            } catch {
                // Silently ignore errors for individual message loads
            }
        }
    }

    // MARK: - Search

    /// Update search and filter results
    func updateSearch(_ query: String) {
        searchQuery = query
        if !allConnections.isEmpty {
            state = .loaded(filteredConnections)
        }
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }
}
