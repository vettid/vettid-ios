import SwiftUI

// MARK: - Main Navigation View

struct MainNavigationView: View {
    @EnvironmentObject var appState: AppState

    @State private var isDrawerOpen = false
    @State private var currentSection: AppSection = .vault
    @State private var selectedNavItem = 0

    // More menu sheet (only Vault section has More)
    @State private var showVaultMoreMenu = false

    // Search state
    @State private var searchText = ""
    @State private var isSearching = false

    // Action sheets
    @State private var showAddConnection = false
    @State private var showAddBackup = false

    // Navigation for Vault More menu items
    @State private var showProfile = false
    @State private var showSecrets = false
    @State private var showPersonalData = false
    @State private var showArchive = false
    @State private var showPreferences = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                currentHeader

                // Content
                currentSectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom Nav
                ContextualBottomNav(
                    section: currentSection,
                    selectedItem: $selectedNavItem,
                    onMoreTap: handleMoreTap
                )
            }

            // Drawer overlay
            DrawerView(
                isOpen: $isDrawerOpen,
                currentSection: $currentSection,
                onSignOut: { } // Sign out is handled by drawer's sheet
            )
        }
        .gesture(edgeSwipeGesture)
        .onChange(of: currentSection) { _ in
            selectedNavItem = 0
            searchText = ""
            isSearching = false
        }
        .sheet(isPresented: $showVaultMoreMenu) {
            VaultMoreMenuSheet(onSelect: handleVaultMoreSelection)
        }
        .sheet(isPresented: $showAddConnection) {
            AddConnectionSheet()
        }
        .sheet(isPresented: $showAddBackup) {
            CreateBackupSheet()
        }
        .sheet(isPresented: $showProfile) {
            NavigationView {
                ProfileView(authTokenProvider: { nil })
            }
        }
        .sheet(isPresented: $showSecrets) {
            NavigationView {
                SecretsView(searchText: "")
            }
        }
        .sheet(isPresented: $showPersonalData) {
            NavigationView {
                PersonalDataView()
            }
        }
        .sheet(isPresented: $showArchive) {
            NavigationView {
                ArchiveView()
            }
        }
        .sheet(isPresented: $showPreferences) {
            NavigationView {
                VaultPreferencesView()
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var currentHeader: some View {
        switch currentSection {
        case .vault:
            vaultHeader
        case .vaultServices:
            vaultServicesHeader
        case .appSettings:
            appSettingsHeader
        }
    }

    @ViewBuilder
    private var vaultHeader: some View {
        switch VaultNavItem(rawValue: selectedNavItem) ?? .connections {
        case .connections:
            SearchableHeaderView(
                title: "Connections",
                onProfileTap: openDrawer,
                searchText: $searchText,
                isSearching: $isSearching,
                actionIcon: "plus",
                onActionTap: { showAddConnection = true }
            )
        case .feed:
            HeaderView(
                title: "Feed",
                onProfileTap: openDrawer
            )
        case .more:
            HeaderView(
                title: "Vault",
                onProfileTap: openDrawer
            )
        }
    }

    @ViewBuilder
    private var vaultServicesHeader: some View {
        switch VaultServicesNavItem(rawValue: selectedNavItem) ?? .status {
        case .status:
            HeaderView(
                title: "Status",
                onProfileTap: openDrawer
            )
        case .backups:
            HeaderView(
                title: "Backups",
                onProfileTap: openDrawer,
                actionIcon: "plus",
                onActionTap: { showAddBackup = true }
            )
        case .manage:
            HeaderView(
                title: "Manage",
                onProfileTap: openDrawer
            )
        }
    }

    @ViewBuilder
    private var appSettingsHeader: some View {
        switch AppSettingsNavItem(rawValue: selectedNavItem) ?? .theme {
        case .theme:
            HeaderView(
                title: "Theme",
                onProfileTap: openDrawer
            )
        case .security:
            HeaderView(
                title: "Security",
                onProfileTap: openDrawer
            )
        case .about:
            HeaderView(
                title: "About",
                onProfileTap: openDrawer
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var currentSectionContent: some View {
        switch currentSection {
        case .vault:
            vaultContent
        case .vaultServices:
            vaultServicesContent
        case .appSettings:
            appSettingsContent
        }
    }

    @ViewBuilder
    private var vaultContent: some View {
        switch VaultNavItem(rawValue: selectedNavItem) ?? .connections {
        case .connections:
            NavigationStack {
                ConnectionsContentView(
                    searchText: searchText,
                    authTokenProvider: { nil }
                )
            }
        case .feed:
            NavigationStack {
                FeedView()
            }
        case .more:
            EmptyView()
        }
    }

    @ViewBuilder
    private var vaultServicesContent: some View {
        switch VaultServicesNavItem(rawValue: selectedNavItem) ?? .status {
        case .status:
            NavigationStack {
                VaultServicesStatusView()
            }
        case .backups:
            NavigationStack {
                BackupListView(authTokenProvider: { nil })
            }
        case .manage:
            NavigationStack {
                ManageVaultView()
            }
        }
    }

    @ViewBuilder
    private var appSettingsContent: some View {
        switch AppSettingsNavItem(rawValue: selectedNavItem) ?? .theme {
        case .theme:
            NavigationStack {
                ThemeSettingsView()
            }
        case .security:
            NavigationStack {
                SecuritySettingsView()
            }
        case .about:
            NavigationStack {
                AboutView()
            }
        }
    }

    // MARK: - Gestures

    private var edgeSwipeGesture: some Gesture {
        DragGesture()
            .onEnded { value in
                // Only trigger if swipe started near left edge and moved right
                if value.startLocation.x < 50 && value.translation.width > 100 {
                    withAnimation(.spring(response: 0.3)) {
                        isDrawerOpen = true
                    }
                }
            }
    }

    // MARK: - Actions

    private func openDrawer() {
        withAnimation(.spring(response: 0.3)) {
            isDrawerOpen = true
        }
    }

    private func handleMoreTap() {
        // Only Vault section has More now
        if currentSection == .vault {
            showVaultMoreMenu = true
        }
    }

    private func handleVaultMoreSelection(_ selection: String) {
        switch selection {
        case "profile":
            showProfile = true
        case "secrets":
            showSecrets = true
        case "personalData":
            showPersonalData = true
        case "archive":
            showArchive = true
        case "preferences":
            showPreferences = true
        default:
            print("Vault more selection: \(selection)")
        }
    }
}

// MARK: - Connections Content View (without NavigationView)

struct ConnectionsContentView: View {
    let searchText: String
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: ConnectionsViewModel
    @State private var showCreateInvitation = false
    @State private var showScanInvitation = false

    init(searchText: String, authTokenProvider: @escaping @Sendable () -> String?) {
        self.searchText = searchText
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: ConnectionsViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingView

            case .empty:
                emptyView

            case .loaded(let connections):
                connectionsList(filteredConnections(connections))

            case .error(let message):
                errorView(message)
            }
        }
        .sheet(isPresented: $showCreateInvitation) {
            CreateInvitationView(authTokenProvider: authTokenProvider)
        }
        .sheet(isPresented: $showScanInvitation) {
            ScanInvitationView(authTokenProvider: authTokenProvider)
        }
        .task {
            await viewModel.loadConnections()
        }
    }

    private func filteredConnections(_ connections: [Connection]) -> [Connection] {
        if searchText.isEmpty {
            return connections
        }
        return connections.filter { connection in
            connection.peerDisplayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading connections...")
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
    }

    private var emptyView: some View {
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
                Button(action: { showCreateInvitation = true }) {
                    Label("Create Invitation", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: { showScanInvitation = true }) {
                    Label("Scan Invitation", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    private func connectionsList(_ connections: [Connection]) -> some View {
        List(connections) { connection in
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
        .listStyle(.plain)
        .refreshable {
            await viewModel.refresh()
        }
    }

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

// MARK: - Placeholder Sheets

struct AddConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Text("Add Connection")
                    .font(.title2)
                    .fontWeight(.semibold)

                VStack(spacing: 12) {
                    NavigationLink(destination: CreateInvitationView(authTokenProvider: { nil })) {
                        Label("Create Invitation", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    NavigationLink(destination: ScanInvitationView(authTokenProvider: { nil })) {
                        Label("Scan Invitation", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 40)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct AddSecretSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Text("Add Secret - Coming Soon")
                .navigationTitle("Add Secret")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

struct CreateBackupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            CredentialBackupView(authTokenProvider: { nil })
                .navigationTitle("Create Backup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Placeholder Views

struct HandlersListView: View {
    let authTokenProvider: @Sendable () -> String?

    var body: some View {
        HandlerDiscoveryView(viewModel: HandlerDiscoveryViewModel(authTokenProvider: authTokenProvider))
    }
}

struct MessagingView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "message.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Messaging")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select a connection to start messaging")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    MainNavigationView()
        .environmentObject(AppState())
}
