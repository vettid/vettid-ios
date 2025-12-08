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
    @Published var searchQuery = ""
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let authTokenProvider: @Sendable () -> String?

    // MARK: - Private State

    private var allConnections: [Connection] = []
    private var lastMessages: [String: Message] = [:]

    // MARK: - Initialization

    init(
        apiClient: APIClient = APIClient(),
        authTokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiClient = apiClient
        self.authTokenProvider = authTokenProvider
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

    /// Load connections from API
    func loadConnections() async {
        guard let authToken = authTokenProvider() else {
            state = .error("Not authenticated")
            return
        }

        state = .loading

        do {
            let connections = try await apiClient.listConnections(authToken: authToken)
            allConnections = connections.sorted {
                ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt)
            }

            if allConnections.isEmpty {
                state = .empty
            } else {
                state = .loaded(filteredConnections)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Refresh connections
    func refresh() async {
        await loadConnections()
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
