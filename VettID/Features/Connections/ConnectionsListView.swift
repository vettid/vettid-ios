import SwiftUI

/// Main connections list view
struct ConnectionsListView: View {
    let authTokenProvider: @Sendable () -> String?
    let serviceConnectionHandler: ServiceConnectionHandler?

    @StateObject private var viewModel: ConnectionsViewModel
    @State private var showCreateInvitation = false
    @State private var showScanInvitation = false
    @State private var showServiceDiscovery = false

    init(
        authTokenProvider: @escaping @Sendable () -> String?,
        serviceConnectionHandler: ServiceConnectionHandler? = nil
    ) {
        self.authTokenProvider = authTokenProvider
        self.serviceConnectionHandler = serviceConnectionHandler
        self._viewModel = StateObject(wrappedValue: ConnectionsViewModel(
            authTokenProvider: authTokenProvider,
            serviceConnectionHandler: serviceConnectionHandler
        ))
    }

    var body: some View {
        NavigationView {
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
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("People") {
                            Button(action: { showCreateInvitation = true }) {
                                Label("Create Invitation", systemImage: "qrcode")
                            }
                            Button(action: { showScanInvitation = true }) {
                                Label("Scan Invitation", systemImage: "qrcode.viewfinder")
                            }
                        }

                        Section("Services") {
                            Button(action: { showServiceDiscovery = true }) {
                                Label("Connect to Service", systemImage: "building.2")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search connections")
            .onChange(of: viewModel.searchQuery) { newValue in
                viewModel.updateSearch(newValue)
            }
        }
        .sheet(isPresented: $showCreateInvitation) {
            CreateInvitationView(authTokenProvider: authTokenProvider)
        }
        .sheet(isPresented: $showScanInvitation) {
            ScanInvitationView(authTokenProvider: authTokenProvider)
        }
        .sheet(isPresented: $showServiceDiscovery) {
            if let handler = serviceConnectionHandler {
                ServiceDiscoveryView(serviceConnectionHandler: handler)
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
            Text("Loading connections...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        EmptyConnectionsView(
            onCreateInvitation: { showCreateInvitation = true },
            onScanInvitation: { showScanInvitation = true }
        )
    }

    // MARK: - Connections List

    private func connectionsList(_ connections: [Connection]) -> some View {
        List {
            // Services Section
            if !viewModel.filteredServiceConnections.isEmpty {
                Section {
                    // Pending Updates Banner
                    if viewModel.pendingServiceUpdatesCount > 0 {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                            Text("\(viewModel.pendingServiceUpdatesCount) contract update\(viewModel.pendingServiceUpdatesCount == 1 ? "" : "s") available")
                                .font(.caption)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }

                    ForEach(viewModel.filteredServiceConnections) { serviceConnection in
                        if let handler = serviceConnectionHandler {
                            NavigationLink(destination: ServiceConnectionDetailView(
                                connectionId: serviceConnection.id,
                                serviceConnectionHandler: handler
                            )) {
                                ServiceConnectionListRow(connection: serviceConnection)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await viewModel.toggleServiceFavorite(serviceConnection.id) }
                                } label: {
                                    Label(
                                        serviceConnection.isFavorite ? "Unfavorite" : "Favorite",
                                        systemImage: serviceConnection.isFavorite ? "star.slash" : "star"
                                    )
                                }
                                .tint(.yellow)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "building.2")
                        Text("Services")
                    }
                }
            }

            // People Section
            if !connections.isEmpty {
                Section {
                    ForEach(connections) { connection in
                        NavigationLink(destination: ConnectionDetailView(
                            connectionId: connection.id,
                            authTokenProvider: authTokenProvider
                        )) {
                            ConnectionListRow(
                                connection: connection,
                                lastMessage: viewModel.lastMessage(for: connection.id)
                            )
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "person.2")
                        Text("People")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refresh()
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

// MARK: - Empty Connections View

struct EmptyConnectionsView: View {
    let onCreateInvitation: () -> Void
    let onScanInvitation: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Connections Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Create an invitation or scan someone else's to get started")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 12) {
                Button(action: onCreateInvitation) {
                    Label("Create Invitation", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onScanInvitation) {
                    Label("Scan Invitation", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }
}

// MARK: - Connection List Row

struct ConnectionListRow: View {
    let connection: Connection
    let lastMessage: Message?

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            AsyncImage(url: URL(string: connection.peerAvatarUrl ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundColor(.secondary)
            }
            .frame(width: 50, height: 50)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(connection.peerDisplayName)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    if let lastMessageAt = connection.lastMessageAt {
                        Text(lastMessageAt, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let lastMessage = lastMessage {
                        Text(lastMessage.content)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Unread badge
                    if connection.unreadCount > 0 {
                        Text("\(connection.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch connection.status {
        case .pending:
            return "Pending..."
        case .active:
            return "Connected"
        case .revoked:
            return "Revoked"
        }
    }
}

// MARK: - Service Connection List Row

struct ServiceConnectionListRow: View {
    let connection: ServiceConnectionRecord

    var body: some View {
        HStack(spacing: 12) {
            // Service Logo
            ServiceLogoView(url: connection.serviceProfile.serviceLogoUrl, size: 50)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(connection.serviceProfile.serviceName)
                        .font(.headline)
                        .lineLimit(1)

                    if connection.serviceProfile.organization.verified {
                        VerificationBadge(type: connection.serviceProfile.organization.verificationType)
                    }

                    if connection.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }

                    Spacer()

                    if connection.pendingContractVersion != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }

                HStack {
                    Text(connection.serviceProfile.organization.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    ServiceConnectionStatusBadge(status: connection.status)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Connection Status Badge

struct ConnectionStatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .cornerRadius(4)
    }

    private var textColor: Color {
        switch status {
        case .pending: return .orange
        case .active: return .green
        case .revoked: return .red
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .pending: return .orange.opacity(0.2)
        case .active: return .green.opacity(0.2)
        case .revoked: return .red.opacity(0.2)
        }
    }
}

#if DEBUG
struct ConnectionsListView_Previews: PreviewProvider {
    static var previews: some View {
        ConnectionsListView(
            authTokenProvider: { "test-token" },
            serviceConnectionHandler: nil
        )
    }
}
#endif
