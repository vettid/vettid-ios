import Foundation

/// State for service connections list
enum ServiceConnectionsListState: Equatable {
    case loading
    case empty
    case loaded([ServiceConnectionRecord])
    case error(String)

    var connections: [ServiceConnectionRecord] {
        if case .loaded(let connections) = self {
            return connections
        }
        return []
    }
}

/// Filter state for service connections
struct ServiceConnectionFilterState: Equatable {
    var statusFilter: Set<ServiceConnectionStatus> = []
    var categoryFilter: Set<ServiceCategory> = []
    var showFavoritesOnly: Bool = false
    var showArchivedOnly: Bool = false
    var selectedTags: Set<String> = []
    var sortBy: ServiceConnectionSortOption = .recentActivity
    var sortAscending: Bool = false

    var hasActiveFilters: Bool {
        !statusFilter.isEmpty ||
        !categoryFilter.isEmpty ||
        showFavoritesOnly ||
        showArchivedOnly ||
        !selectedTags.isEmpty
    }

    mutating func reset() {
        statusFilter = []
        categoryFilter = []
        showFavoritesOnly = false
        showArchivedOnly = false
        selectedTags = []
        sortBy = .recentActivity
        sortAscending = false
    }
}

/// Sort options for service connections
enum ServiceConnectionSortOption: String, CaseIterable {
    case recentActivity
    case name
    case dateConnected
    case category

    var displayName: String {
        switch self {
        case .recentActivity: return "Recent Activity"
        case .name: return "Name"
        case .dateConnected: return "Date Connected"
        case .category: return "Category"
        }
    }
}

/// ViewModel for service connections list
@MainActor
final class ServiceConnectionsViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ServiceConnectionsListState = .loading
    @Published var searchQuery = ""
    @Published var filterState = ServiceConnectionFilterState()
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let serviceConnectionHandler: ServiceConnectionHandler
    private let serviceConnectionStore: ServiceConnectionStore

    // MARK: - Private State

    private var allConnections: [ServiceConnectionRecord] = []

    // MARK: - Initialization

    init(
        serviceConnectionHandler: ServiceConnectionHandler,
        serviceConnectionStore: ServiceConnectionStore = ServiceConnectionStore()
    ) {
        self.serviceConnectionHandler = serviceConnectionHandler
        self.serviceConnectionStore = serviceConnectionStore
    }

    // MARK: - Computed Properties

    /// Filtered and sorted connections
    var filteredConnections: [ServiceConnectionRecord] {
        var connections = allConnections

        // Apply search filter
        if !searchQuery.isEmpty {
            connections = connections.filter { connection in
                connection.serviceProfile.serviceName.localizedCaseInsensitiveContains(searchQuery) ||
                connection.serviceProfile.organization.name.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        // Apply status filter
        if !filterState.statusFilter.isEmpty {
            connections = connections.filter { filterState.statusFilter.contains($0.status) }
        }

        // Apply category filter
        if !filterState.categoryFilter.isEmpty {
            connections = connections.filter { filterState.categoryFilter.contains($0.serviceProfile.serviceCategory) }
        }

        // Apply favorites filter
        if filterState.showFavoritesOnly {
            connections = connections.filter { $0.isFavorite }
        }

        // Apply archived filter
        if filterState.showArchivedOnly {
            connections = connections.filter { $0.isArchived }
        } else {
            // By default, hide archived
            connections = connections.filter { !$0.isArchived }
        }

        // Apply tags filter
        if !filterState.selectedTags.isEmpty {
            connections = connections.filter { connection in
                !filterState.selectedTags.isDisjoint(with: Set(connection.tags))
            }
        }

        // Apply sorting
        connections = sortConnections(connections)

        return connections
    }

    /// All unique tags across connections
    var allTags: [String] {
        var tags = Set<String>()
        for connection in allConnections {
            tags.formUnion(connection.tags)
        }
        return Array(tags).sorted()
    }

    /// Count of pending contract updates
    var pendingUpdatesCount: Int {
        allConnections.filter { $0.pendingContractVersion != nil }.count
    }

    /// Count of active connections
    var activeConnectionsCount: Int {
        allConnections.filter { $0.status == .active && !$0.isArchived }.count
    }

    // MARK: - Loading

    /// Load connections from vault
    func loadConnections() async {
        state = .loading

        do {
            // Try to load from local store first for faster display
            let localConnections = try serviceConnectionStore.listConnections(
                includeArchived: true,
                includeRevoked: false
            )

            if !localConnections.isEmpty {
                allConnections = localConnections
                state = .loaded(filteredConnections)
            }

            // Then fetch from vault for updates
            let vaultConnections = try await serviceConnectionHandler.listConnections(
                includeArchived: true,
                includeRevoked: false
            )

            allConnections = vaultConnections

            // Update local store
            for connection in vaultConnections {
                try? serviceConnectionStore.update(connection: connection)
            }

            if allConnections.isEmpty {
                state = .empty
            } else {
                state = .loaded(filteredConnections)
            }
        } catch {
            // Fall back to local store on network error
            do {
                let localConnections = try serviceConnectionStore.listConnections(
                    includeArchived: true,
                    includeRevoked: false
                )
                allConnections = localConnections

                if allConnections.isEmpty {
                    state = .error(error.localizedDescription)
                } else {
                    state = .loaded(filteredConnections)
                    errorMessage = "Using cached data. \(error.localizedDescription)"
                }
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Refresh connections
    func refresh() async {
        await loadConnections()
    }

    // MARK: - Connection Actions

    /// Toggle favorite status
    func toggleFavorite(_ connectionId: String) async {
        guard var connection = allConnections.first(where: { $0.id == connectionId }) else { return }

        connection.isFavorite.toggle()

        // Update locally immediately for responsiveness
        if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
            allConnections[index] = connection
            state = .loaded(filteredConnections)
        }

        // Sync to vault
        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                isFavorite: connection.isFavorite
            )
            try serviceConnectionStore.update(connection: connection)
        } catch {
            // Revert on error
            if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
                allConnections[index].isFavorite.toggle()
                state = .loaded(filteredConnections)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Toggle muted status
    func toggleMuted(_ connectionId: String) async {
        guard var connection = allConnections.first(where: { $0.id == connectionId }) else { return }

        connection.isMuted.toggle()

        if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
            allConnections[index] = connection
            state = .loaded(filteredConnections)
        }

        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                isMuted: connection.isMuted
            )
            try serviceConnectionStore.update(connection: connection)
        } catch {
            if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
                allConnections[index].isMuted.toggle()
                state = .loaded(filteredConnections)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Archive a connection
    func archiveConnection(_ connectionId: String) async {
        guard var connection = allConnections.first(where: { $0.id == connectionId }) else { return }

        connection.isArchived = true

        if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
            allConnections[index] = connection
            state = .loaded(filteredConnections)
        }

        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                isArchived: true
            )
            try serviceConnectionStore.update(connection: connection)
        } catch {
            if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
                allConnections[index].isArchived = false
                state = .loaded(filteredConnections)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Unarchive a connection
    func unarchiveConnection(_ connectionId: String) async {
        guard var connection = allConnections.first(where: { $0.id == connectionId }) else { return }

        connection.isArchived = false

        if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
            allConnections[index] = connection
            state = .loaded(filteredConnections)
        }

        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                isArchived: false
            )
            try serviceConnectionStore.update(connection: connection)
        } catch {
            if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
                allConnections[index].isArchived = true
                state = .loaded(filteredConnections)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Update tags for a connection
    func updateTags(_ connectionId: String, tags: [String]) async {
        guard var connection = allConnections.first(where: { $0.id == connectionId }) else { return }

        let oldTags = connection.tags
        connection.tags = tags

        if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
            allConnections[index] = connection
            state = .loaded(filteredConnections)
        }

        do {
            _ = try await serviceConnectionHandler.updateConnection(
                connectionId: connectionId,
                tags: tags
            )
            try serviceConnectionStore.update(connection: connection)
        } catch {
            if let index = allConnections.firstIndex(where: { $0.id == connectionId }) {
                allConnections[index].tags = oldTags
                state = .loaded(filteredConnections)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Revoke a connection
    func revokeConnection(_ connectionId: String) async {
        do {
            _ = try await serviceConnectionHandler.revokeConnection(connectionId: connectionId)

            // Remove from list
            allConnections.removeAll { $0.id == connectionId }
            try? serviceConnectionStore.delete(connectionId: connectionId)

            if allConnections.isEmpty {
                state = .empty
            } else {
                state = .loaded(filteredConnections)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Search

    /// Update search query
    func updateSearch(_ query: String) {
        searchQuery = query
        if !allConnections.isEmpty {
            state = .loaded(filteredConnections)
        }
    }

    // MARK: - Filtering

    /// Apply filter changes
    func applyFilters() {
        if !allConnections.isEmpty {
            state = .loaded(filteredConnections)
        }
    }

    /// Reset all filters
    func resetFilters() {
        filterState.reset()
        applyFilters()
    }

    // MARK: - Error Handling

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private Methods

    private func sortConnections(_ connections: [ServiceConnectionRecord]) -> [ServiceConnectionRecord] {
        let sorted = connections.sorted { lhs, rhs in
            switch filterState.sortBy {
            case .recentActivity:
                let lhsDate = lhs.lastActivityAt ?? lhs.createdAt
                let rhsDate = rhs.lastActivityAt ?? rhs.createdAt
                return lhsDate > rhsDate

            case .name:
                return lhs.serviceProfile.serviceName.localizedCaseInsensitiveCompare(rhs.serviceProfile.serviceName) == .orderedAscending

            case .dateConnected:
                return lhs.createdAt > rhs.createdAt

            case .category:
                return lhs.serviceProfile.serviceCategory.displayName.localizedCaseInsensitiveCompare(rhs.serviceProfile.serviceCategory.displayName) == .orderedAscending
            }
        }

        return filterState.sortAscending ? sorted.reversed() : sorted
    }
}
