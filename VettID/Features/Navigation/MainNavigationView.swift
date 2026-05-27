import SwiftUI

// MARK: - Main Navigation View

struct MainNavigationView: View {
    @EnvironmentObject var appState: AppState

    /// Top-level destination. Android's main scaffold has exactly two:
    /// the Connections list (default) and the Vault (reached by tapping
    /// the avatar or swiping left). The drawer + bottom-nav + More
    /// menu that used to live here are gone — `currentItem` now toggles
    /// between `.connections` and `.vault`, and the previously-drawered
    /// destinations (voting, devices, audit log, grants, actions,
    /// archive) are reached from Settings rows or surfaced inside the
    /// VettID system connection's audit trail.
    @State private var currentItem: DrawerItem = .connections
    /// Which segment is showing when the Vault destination is active.
    /// Matches Android `NavigationState.vaultSegment`.
    @State private var vaultSegment: VaultSegment = .data

    // Badge counts
    @StateObject private var badgeCounts = BadgeCountsViewModel()

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
        VStack(spacing: 0) {
            // Header — tap-avatar toggles Connections ↔ Vault, gear
            // opens Settings. No drawer, no bottom nav (Android parity).
            currentHeader

            // Content
            currentContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(contentSwipeGesture)
        }
        .onChange(of: currentItem) { newValue in
            searchText = ""
            isSearching = false
            // The drawer-shortcut segment mapping is preserved for
            // deep links / external callers that still set currentItem
            // to .personalData / .secrets / .wallets — flip the
            // segment then collapse to the canonical `.vault` item.
            if let seg = newValue.vaultSegment {
                vaultSegment = seg
                Task { @MainActor in currentItem = .vault }
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
            // Connection-centric feed is the activity destination.
            withAnimation(.easeInOut(duration: 0.2)) {
                currentItem = .connections
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
                onProfileTap: toggleDestination,
                searchText: $searchText,
                isSearching: $isSearching,
                actionIcon: "plus",
                onActionTap: { showAddConnection = true },
                onSettingsTap: { showSettings = true },
                profilePhotoData: profilePhotoData
            )
        case .vault:
            // The Vault destination shows a segmented Data/Secrets/Wallets
            // picker; only Secrets and Personal Data benefit from the
            // searchable header (the others have their own surfaces).
            if vaultSegment == .secrets || vaultSegment == .data {
                SearchableHeaderView(
                    title: "Vault",
                    onProfileTap: toggleDestination,
                    searchText: $searchText,
                    isSearching: $isSearching,
                    onSettingsTap: { showSettings = true },
                    profilePhotoData: profilePhotoData
                )
            } else {
                HeaderView(
                    title: "Vault",
                    onProfileTap: toggleDestination,
                    onSettingsTap: { showSettings = true },
                    profilePhotoData: profilePhotoData
                )
            }
        default:
            HeaderView(
                title: currentItem.title,
                onProfileTap: toggleDestination,
                onSettingsTap: { showSettings = true },
                profilePhotoData: profilePhotoData
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var currentContent: some View {
        switch currentItem {
        case .connections:
            // ACTIVITY destination — the connection-centric feed. The
            // separate "feed" tab is gone; the feed IS the connections
            // list now.
            NavigationStack { FeedView() }
        case .vault:
            // VAULT destination — segmented Data / Secrets / Wallets.
            NavigationStack {
                VaultView(segment: $vaultSegment, searchText: searchText)
            }
        case .personalData, .secrets, .wallets:
            // Drawer-shortcut targets — funnel back through the VAULT
            // destination with the appropriate segment. (Pre-emptively
            // handled by onChange(currentItem); this branch covers the
            // transient frame before the onChange flips it.)
            NavigationStack {
                VaultView(segment: $vaultSegment, searchText: searchText)
            }
        case .voting:
            NavigationStack { ProposalsView(authTokenProvider: { nil }) }
        case .archive:
            NavigationStack { ArchivedConnectionsView() }
        case .devices:
            NavigationStack { DeviceManagementView() }
        case .auditLog:
            NavigationStack {
                // Phase 5.3: thread the AppState FeedClient through so
                // the verifier runs against real `audit.query` responses
                // (anchor + per-row hashes). Without it, the view falls
                // back to its mock data path.
                FeedAuditLogView(feedClient: appState.feedClient)
            }
        case .grants:
            NavigationStack { GrantsView() }
        case .actions:
            NavigationStack { ActionsView() }
        }
    }

    // MARK: - Gestures

    /// Horizontal swipe between the two top-level destinations.
    /// Matches Android `horizontalSwipeNavigation` on MainScaffold —
    /// swipe-left from Connections enters the Vault, swipe-right inside
    /// the Vault pops back to Connections.
    private var contentSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                guard value.startLocation.x >= 50 else { return }
                let horizontalAmount = value.translation.width
                let isVaultActive = currentItem == .vault || currentItem.vaultSegment != nil

                if horizontalAmount < -50 && !isVaultActive {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentItem = .vault
                    }
                } else if horizontalAmount > 50 && isVaultActive {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentItem = .connections
                    }
                }
            }
    }

    // MARK: - Actions

    /// Avatar tap — mirrors Android `onAvatarClick` in `MainScaffold`.
    /// Toggles between the two top-level destinations.
    private func toggleDestination() {
        withAnimation(.easeInOut(duration: 0.2)) {
            currentItem = (currentItem == .connections) ? .vault : .connections
        }
    }
}

// MARK: - Settings List View

struct SettingsListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    var body: some View {
        // Section layout mirrors Android `VaultPreferencesContent`:
        // Account → Privacy, Data & Logging → App → Activity → Help →
        // Appearance. Android keeps Agent Connections / Audit Log /
        // Grants / Actions under Privacy; Archive / Voting / Devices
        // don't have Android Settings rows so they live in an
        // iOS-only "Activity" section (kept reachable since the
        // drawer is gone).
        List {
            Section("Account") {
                NavigationLink(destination: SecuritySettingsView()) {
                    Label("Security", systemImage: "lock.shield.fill")
                }
                NavigationLink(destination: BackupListView(authTokenProvider: { nil })) {
                    Label("Credential Backup", systemImage: "externaldrive.fill")
                }
            }

            Section("Privacy, Data & Logging") {
                NavigationLink(destination: LocationSettingsView().environmentObject(appState)) {
                    Label("Location", systemImage: "location.fill")
                }
                NavigationLink(destination: AgentManagementView()) {
                    Label("Agent Connections", systemImage: "sparkles")
                }
                NavigationLink(destination: FeedAuditLogView(feedClient: appState.feedClient)) {
                    Label("View Audit Logs", systemImage: "lock.shield")
                }
                NavigationLink(destination: GrantsView()) {
                    Label("Grants", systemImage: "key.fill")
                }
                NavigationLink(destination: ActionsView()) {
                    Label("Actions", systemImage: "wand.and.stars")
                }
            }

            Section("App") {
                NavigationLink(destination: AboutView()) {
                    Label("App Details", systemImage: "info.circle.fill")
                }
                NavigationLink(destination: VaultServicesStatusView()) {
                    Label("Vault Status", systemImage: "chart.bar.fill")
                }
                NavigationLink(destination: VaultPreferencesView().environmentObject(appState)) {
                    Label("Vault Preferences", systemImage: "gearshape.fill")
                }
            }

            // Connection / activity surfaces that don't map to an
            // Android Settings row (Android reaches them from the
            // feed or system-card audit trail). Kept here so the
            // drawer-removal restructure doesn't strand them.
            Section("Activity") {
                NavigationLink(destination: ArchivedConnectionsView()) {
                    Label("Archive", systemImage: "archivebox.fill")
                }
                NavigationLink(destination: ProposalsView(authTokenProvider: { nil })) {
                    Label("Voting", systemImage: "checkmark.square.fill")
                }
                NavigationLink(destination: DeviceManagementView()) {
                    Label("Devices", systemImage: "desktopcomputer")
                }
            }

            Section("Help") {
                NavigationLink(destination: GuideListView()) {
                    Label("Guides", systemImage: "questionmark.circle.fill")
                }
            }

            Section("Appearance") {
                NavigationLink(destination: ThemeSettingsView()) {
                    Label("Theme", systemImage: "paintbrush.fill")
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
        // Four actions matching Android's `+` FAB on the feed: Agent
        // Invitation, Connect Desktop, Scan Invitation, Create
        // Invitation. Same icons (SF Symbols equivalent of Material
        // SmartToy / Computer / QrCodeScanner / PersonAdd) and order.
        NavigationView {
            VStack(spacing: 24) {
                Text("Add Connection")
                    .font(.title2)
                    .fontWeight(.semibold)

                VStack(spacing: 12) {
                    NavigationLink(destination: CreateAgentInvitationView()) {
                        Label("Agent Invitation", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    NavigationLink(destination: DevicePairingView()) {
                        Label("Connect Desktop", systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    NavigationLink(destination: ScanInvitationView(authTokenProvider: { nil })) {
                        Label("Scan Invitation", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    NavigationLink(destination: CreateInvitationView(authTokenProvider: { nil })) {
                        Label("Create Invitation", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
