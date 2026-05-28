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
            // No header "+" — the Connections screen uses a bottom-right
            // FAB (in ConnectionsHomeView) for the add-connection actions.
            SearchableHeaderView(
                title: "Connections",
                onProfileTap: toggleDestination,
                searchText: $searchText,
                isSearching: $isSearching,
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
            // HOME destination — typed connection cards (system / people
            // / desktops / agents) with the add-connection FAB. The
            // activity feed now opens from the VettID system card.
            // ConnectionsHomeView owns its own NavigationStack.
            ConnectionsHomeView(searchText: searchText)
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


// MARK: - Preview

#Preview {
    MainNavigationView()
        .environmentObject(AppState())
}
