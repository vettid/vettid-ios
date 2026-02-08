import SwiftUI

// MARK: - Main Navigation View

struct MainNavigationView: View {
    @EnvironmentObject var appState: AppState

    @State private var isDrawerOpen = false
    @State private var currentItem: DrawerItem = .feed

    // Badge counts
    @StateObject private var badgeCounts = BadgeCountsViewModel()

    // More menu
    @State private var showMoreMenu = false

    // Search state
    @State private var searchText = ""
    @State private var isSearching = false

    // Settings sheet
    @State private var showSettings = false

    // Action sheets
    @State private var showAddConnection = false
    @State private var showProfile = false
    @State private var showGuides = false

    // Deep link navigation
    @State private var showConnectSheet = false
    @State private var deepLinkConnectCode: String?
    @State private var showConversation = false
    @State private var deepLinkConnectionId: String?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                currentHeader

                // Content
                currentContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(contentSwipeGesture)

                // Bottom Nav
                BottomNavBar(
                    currentItem: $currentItem,
                    badgeCounts: badgeCounts,
                    onMoreTap: { showMoreMenu = true }
                )
            }

            // Drawer overlay
            DrawerView(
                isOpen: $isDrawerOpen,
                currentItem: $currentItem,
                onSignOut: {},
                badgeCounts: badgeCounts
            )
        }
        .gesture(edgeSwipeGesture)
        .onChange(of: currentItem) { _ in
            searchText = ""
            isSearching = false
        }
        .sheet(isPresented: $showMoreMenu) {
            MoreMenuSheet { item in
                currentItem = item
            }
        }
        .sheet(isPresented: $showAddConnection) {
            AddConnectionSheet()
        }
        .sheet(isPresented: $showProfile) {
            NavigationView {
                ProfileView(authTokenProvider: { nil })
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                SettingsListView()
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showGuides) {
            NavigationView {
                GuideListView()
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            NavigationView {
                if let code = deepLinkConnectCode {
                    ScanInvitationView(authTokenProvider: { nil }, prefilledCode: code)
                } else {
                    ScanInvitationView(authTokenProvider: { nil })
                }
            }
        }
        .sheet(isPresented: $showConversation) {
            NavigationView {
                if let connectionId = deepLinkConnectionId {
                    ConversationView(connectionId: connectionId, authTokenProvider: { nil })
                } else {
                    Text("Connection not found")
                }
            }
        }
        .onChange(of: appState.pendingNavigation) { navigation in
            handlePendingNavigation(navigation)
        }
        .onAppear {
            badgeCounts.startObserving()
        }
        .onDisappear {
            badgeCounts.stopObserving()
        }
    }

    // MARK: - Deep Link Navigation Handler

    private func handlePendingNavigation(_ navigation: PendingNavigation?) {
        guard let navigation = navigation else { return }
        appState.clearPendingNavigation()

        switch navigation {
        case .message(let connectionId):
            deepLinkConnectionId = connectionId
            showConversation = true

        case .connect(let code):
            deepLinkConnectCode = code
            showConnectSheet = true

        case .vaultStatus:
            // Navigate to feed (closest equivalent in flat nav)
            withAnimation(.easeInOut(duration: 0.2)) {
                currentItem = .feed
            }
        }
    }

    // MARK: - Header

    private var profilePhotoData: Data? {
        appState.currentProfile?.photoData
    }

    @ViewBuilder
    private var currentHeader: some View {
        switch currentItem {
        case .connections:
            SearchableHeaderView(
                title: "Connections",
                onProfileTap: openDrawer,
                searchText: $searchText,
                isSearching: $isSearching,
                actionIcon: "plus",
                onActionTap: { showAddConnection = true },
                onSettingsTap: { showSettings = true },
                profilePhotoData: profilePhotoData
            )
        case .secrets:
            SearchableHeaderView(
                title: "Secrets",
                onProfileTap: openDrawer,
                searchText: $searchText,
                isSearching: $isSearching,
                onSettingsTap: { showSettings = true },
                profilePhotoData: profilePhotoData
            )
        default:
            HeaderView(
                title: currentItem.title,
                onProfileTap: openDrawer,
                onSettingsTap: { showSettings = true },
                profilePhotoData: profilePhotoData
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var currentContent: some View {
        switch currentItem {
        case .feed:
            NavigationStack {
                FeedView()
            }
        case .connections:
            NavigationStack {
                ConnectionsContentView(
                    searchText: searchText,
                    authTokenProvider: { nil }
                )
            }
        case .voting:
            NavigationStack {
                ProposalsView(authTokenProvider: { nil })
            }
        case .secrets:
            NavigationStack {
                SecretsView(searchText: searchText)
            }
        case .personalData:
            NavigationStack {
                PersonalDataView()
            }
        case .archive:
            NavigationStack {
                ArchiveView()
            }
        }
    }

    // MARK: - Gestures

    private var edgeSwipeGesture: some Gesture {
        DragGesture()
            .onEnded { value in
                if value.startLocation.x < 50 && value.translation.width > 100 {
                    withAnimation(.spring(response: 0.3)) {
                        isDrawerOpen = true
                    }
                }
            }
    }

    private var contentSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                guard value.startLocation.x >= 50 else { return }

                let horizontalAmount = value.translation.width
                let bottomNavItems: [DrawerItem] = [.feed, .connections, .voting, .secrets]

                guard let currentIndex = bottomNavItems.firstIndex(of: currentItem) else { return }

                if horizontalAmount < -50 && currentIndex < bottomNavItems.count - 1 {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentItem = bottomNavItems[currentIndex + 1]
                    }
                } else if horizontalAmount > 50 && currentIndex > 0 {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentItem = bottomNavItems[currentIndex - 1]
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
}

// MARK: - Settings List View

struct SettingsListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section("Appearance") {
                NavigationLink(destination: ThemeSettingsView()) {
                    Label("Theme", systemImage: "paintbrush.fill")
                }
            }

            Section("Security") {
                NavigationLink(destination: SecuritySettingsView()) {
                    Label("Security", systemImage: "lock.shield.fill")
                }
            }

            Section("Vault") {
                NavigationLink(destination: LocationSettingsView().environmentObject(appState)) {
                    Label("Location", systemImage: "location.fill")
                }

                NavigationLink(destination: VaultPreferencesView().environmentObject(appState)) {
                    Label("Vault Preferences", systemImage: "gearshape.fill")
                }

                NavigationLink(destination: VaultServicesStatusView()) {
                    Label("Vault Status", systemImage: "chart.bar.fill")
                }

                NavigationLink(destination: BackupListView(authTokenProvider: { nil })) {
                    Label("Backups", systemImage: "externaldrive.fill")
                }
            }

            Section("Help") {
                NavigationLink(destination: GuideListView()) {
                    Label("Guides", systemImage: "questionmark.circle.fill")
                }

                NavigationLink(destination: AboutView()) {
                    Label("About", systemImage: "info.circle.fill")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
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
