import SwiftUI

/// List view for service connections
struct ServiceConnectionsListView: View {
    @StateObject private var viewModel: ServiceConnectionsViewModel
    @State private var showingDiscovery = false
    @State private var showingFilters = false

    private let serviceConnectionHandler: ServiceConnectionHandler

    init(serviceConnectionHandler: ServiceConnectionHandler) {
        self.serviceConnectionHandler = serviceConnectionHandler
        self._viewModel = StateObject(wrappedValue: ServiceConnectionsViewModel(
            serviceConnectionHandler: serviceConnectionHandler
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingView

            case .empty:
                emptyView

            case .loaded(let connections):
                connectionsList(connections)

            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("Services")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingDiscovery = true }) {
                    Image(systemName: "plus")
                }
            }

            ToolbarItem(placement: .secondaryAction) {
                Button(action: { showingFilters = true }) {
                    Image(systemName: viewModel.filterState.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .searchable(text: $viewModel.searchQuery, prompt: "Search services")
        .onChange(of: viewModel.searchQuery) { newValue in
            viewModel.updateSearch(newValue)
        }
        .sheet(isPresented: $showingDiscovery) {
            ServiceDiscoveryView(serviceConnectionHandler: serviceConnectionHandler)
        }
        .sheet(isPresented: $showingFilters) {
            ServiceConnectionsFilterSheet(
                filterState: $viewModel.filterState,
                allTags: viewModel.allTags,
                onApply: { viewModel.applyFilters() },
                onReset: { viewModel.resetFilters() }
            )
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .task {
            await viewModel.loadConnections()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading services...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "building.2")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Service Connections")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Connect to services to securely share your data with businesses and organizations")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: { showingDiscovery = true }) {
                Label("Connect to a Service", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Connections List

    private func connectionsList(_ connections: [ServiceConnectionRecord]) -> some View {
        List {
            // Pending Updates Section
            if viewModel.pendingUpdatesCount > 0 {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                        Text("\(viewModel.pendingUpdatesCount) contract update\(viewModel.pendingUpdatesCount == 1 ? "" : "s") available")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Navigate to pending updates
                    }
                }
            }

            // Active Filters Banner
            if viewModel.filterState.hasActiveFilters {
                Section {
                    HStack {
                        Text("Filters active")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Clear") {
                            viewModel.resetFilters()
                        }
                        .font(.caption)
                    }
                }
            }

            // Favorites Section
            let favorites = connections.filter { $0.isFavorite }
            if !favorites.isEmpty {
                Section(header: Text("Favorites")) {
                    ForEach(favorites) { connection in
                        connectionRow(connection)
                    }
                }
            }

            // All Services Section
            let nonFavorites = connections.filter { !$0.isFavorite }
            if !nonFavorites.isEmpty {
                Section(header: Text(favorites.isEmpty ? "Services" : "Other Services")) {
                    ForEach(nonFavorites) { connection in
                        connectionRow(connection)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refresh()
        }
    }

    private func connectionRow(_ connection: ServiceConnectionRecord) -> some View {
        NavigationLink(destination: ServiceConnectionDetailView(
            connectionId: connection.id,
            serviceConnectionHandler: serviceConnectionHandler
        )) {
            ServiceConnectionRow(connection: connection)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await viewModel.revokeConnection(connection.id) }
            } label: {
                Label("Revoke", systemImage: "xmark.circle")
            }

            Button {
                Task { await viewModel.archiveConnection(connection.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await viewModel.toggleFavorite(connection.id) }
            } label: {
                Label(
                    connection.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: connection.isFavorite ? "star.slash" : "star"
                )
            }
            .tint(.yellow)

            Button {
                Task { await viewModel.toggleMuted(connection.id) }
            } label: {
                Label(
                    connection.isMuted ? "Unmute" : "Mute",
                    systemImage: connection.isMuted ? "bell" : "bell.slash"
                )
            }
            .tint(.gray)
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Service Connections Filter Sheet

struct ServiceConnectionsFilterSheet: View {
    @Binding var filterState: ServiceConnectionFilterState
    let allTags: [String]
    let onApply: () -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                // Status Filter
                Section("Status") {
                    ForEach(ServiceConnectionStatus.allCases, id: \.self) { status in
                        Toggle(status.displayName, isOn: Binding(
                            get: { filterState.statusFilter.contains(status) },
                            set: { isOn in
                                if isOn {
                                    filterState.statusFilter.insert(status)
                                } else {
                                    filterState.statusFilter.remove(status)
                                }
                            }
                        ))
                    }
                }

                // Category Filter
                Section("Category") {
                    ForEach(ServiceCategory.allCases, id: \.self) { category in
                        Toggle(category.displayName, isOn: Binding(
                            get: { filterState.categoryFilter.contains(category) },
                            set: { isOn in
                                if isOn {
                                    filterState.categoryFilter.insert(category)
                                } else {
                                    filterState.categoryFilter.remove(category)
                                }
                            }
                        ))
                    }
                }

                // Quick Filters
                Section("Quick Filters") {
                    Toggle("Favorites Only", isOn: $filterState.showFavoritesOnly)
                    Toggle("Show Archived", isOn: $filterState.showArchivedOnly)
                }

                // Tags
                if !allTags.isEmpty {
                    Section("Tags") {
                        ForEach(allTags, id: \.self) { tag in
                            Toggle(tag, isOn: Binding(
                                get: { filterState.selectedTags.contains(tag) },
                                set: { isOn in
                                    if isOn {
                                        filterState.selectedTags.insert(tag)
                                    } else {
                                        filterState.selectedTags.remove(tag)
                                    }
                                }
                            ))
                        }
                    }
                }

                // Sort Options
                Section("Sort By") {
                    Picker("Sort By", selection: $filterState.sortBy) {
                        ForEach(ServiceConnectionSortOption.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Ascending", isOn: $filterState.sortAscending)
                }
            }
            .navigationTitle("Filter Services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        onReset()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Service Connection Status Extension

extension ServiceConnectionStatus: CaseIterable {
    static var allCases: [ServiceConnectionStatus] {
        [.pending, .active, .suspended, .revoked, .expired]
    }
}

#if DEBUG
struct ServiceConnectionsListView_Previews: PreviewProvider {
    static var previews: some View {
        Text("ServiceConnectionsListView Preview")
    }
}
#endif
