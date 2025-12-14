import SwiftUI

// MARK: - Main Navigation View

struct MainNavigationView: View {
    @EnvironmentObject var appState: AppState

    @State private var isDrawerOpen = false
    @State private var currentSection: AppSection = .vault
    @State private var selectedNavItem = 0

    // More menu sheets
    @State private var showVaultMoreMenu = false
    @State private var showServicesMoreMenu = false
    @State private var showSettingsMoreMenu = false

    // Search state
    @State private var searchText = ""
    @State private var isSearching = false

    // Action sheets
    @State private var showAddConnection = false
    @State private var showAddSecret = false
    @State private var showAddPersonalData = false
    @State private var showAddBackup = false
    @State private var showEditProfile = false
    @State private var showHandlerDiscovery = false
    @State private var showSignOutConfirmation = false

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
                onSignOut: { showSignOutConfirmation = true }
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
        .sheet(isPresented: $showServicesMoreMenu) {
            VaultServicesMoreMenuSheet(onSelect: handleServicesMoreSelection)
        }
        .sheet(isPresented: $showSettingsMoreMenu) {
            AppSettingsMoreMenuSheet(onSelect: handleSettingsMoreSelection)
        }
        .sheet(isPresented: $showAddConnection) {
            AddConnectionSheet()
        }
        .sheet(isPresented: $showAddSecret) {
            AddSecretSheet()
        }
        .sheet(isPresented: $showAddBackup) {
            CreateBackupSheet()
        }
        .sheet(isPresented: $showHandlerDiscovery) {
            NavigationView {
                HandlerDiscoveryView(viewModel: HandlerDiscoveryViewModel(authTokenProvider: { nil }))
            }
        }
        .sheet(isPresented: $showEditProfile) {
            // TODO: Get actual profile from storage
            EditProfileView(
                profile: Profile(guid: "", displayName: "", avatarUrl: nil, bio: nil, location: nil, lastUpdated: Date()),
                onSave: { _ in }
            )
        }
        .confirmationDialog(
            "Sign Out",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                handleSignOut()
            }
            Button("Lock App") {
                handleLockApp()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose an option")
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
        switch VaultServicesNavItem(rawValue: selectedNavItem) ?? .handlers {
        case .handlers:
            HeaderView(
                title: "Handlers",
                onProfileTap: openDrawer,
                actionIcon: "magnifyingglass",
                onActionTap: { showHandlerDiscovery = true }
            )
        case .backups:
            HeaderView(
                title: "Backups",
                onProfileTap: openDrawer,
                actionIcon: "plus",
                onActionTap: { showAddBackup = true }
            )
        case .messaging:
            HeaderView(
                title: "Messaging",
                onProfileTap: openDrawer
            )
        case .more:
            HeaderView(
                title: "Services",
                onProfileTap: openDrawer
            )
        }
    }

    @ViewBuilder
    private var appSettingsHeader: some View {
        switch AppSettingsNavItem(rawValue: selectedNavItem) ?? .profile {
        case .profile:
            HeaderView(
                title: "Profile",
                onProfileTap: openDrawer,
                actionIcon: "pencil",
                onActionTap: { showEditProfile = true }
            )
        case .secrets:
            SearchableHeaderView(
                title: "Secrets",
                onProfileTap: openDrawer,
                searchText: $searchText,
                isSearching: $isSearching,
                actionIcon: "plus",
                onActionTap: { showAddSecret = true }
            )
        case .personalData:
            HeaderView(
                title: "Personal Data",
                onProfileTap: openDrawer,
                actionIcon: "plus",
                onActionTap: { showAddPersonalData = true }
            )
        case .more:
            HeaderView(
                title: "Settings",
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
        switch VaultServicesNavItem(rawValue: selectedNavItem) ?? .handlers {
        case .handlers:
            NavigationStack {
                HandlersListView(authTokenProvider: { nil })
            }
        case .backups:
            NavigationStack {
                BackupListView(authTokenProvider: { nil })
            }
        case .messaging:
            NavigationStack {
                MessagingView()
            }
        case .more:
            EmptyView()
        }
    }

    @ViewBuilder
    private var appSettingsContent: some View {
        switch AppSettingsNavItem(rawValue: selectedNavItem) ?? .profile {
        case .profile:
            NavigationStack {
                ProfileView(authTokenProvider: { nil })
            }
        case .secrets:
            NavigationStack {
                SecretsView(searchText: searchText)
            }
        case .personalData:
            NavigationStack {
                PersonalDataView()
            }
        case .more:
            EmptyView()
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
        switch currentSection {
        case .vault:
            showVaultMoreMenu = true
        case .vaultServices:
            showServicesMoreMenu = true
        case .appSettings:
            showSettingsMoreMenu = true
        }
    }

    private func handleVaultMoreSelection(_ selection: String) {
        // Handle vault more menu selections
        print("Vault more selection: \(selection)")
    }

    private func handleServicesMoreSelection(_ selection: String) {
        // Handle services more menu selections
        print("Services more selection: \(selection)")
    }

    private func handleSettingsMoreSelection(_ selection: String) {
        // Handle settings more menu selections
        print("Settings more selection: \(selection)")
    }

    private func handleSignOut() {
        appState.signOut()
    }

    private func handleLockApp() {
        appState.lock()
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
