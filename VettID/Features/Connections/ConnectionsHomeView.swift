import SwiftUI

// MARK: - Connections Home
//
// Android-parity main screen: the Connections destination is the home,
// rendering typed connection cards (VettID system, people, desktops,
// agents) with a bottom-right FAB for the four add-connection actions.
// Replaces the old FeedView that used to live in this slot; the
// activity feed now opens from the VettID system card.

struct ConnectionsHomeView: View {
    @EnvironmentObject var appState: AppState
    var searchText: String = ""

    var body: some View {
        Group {
            // Gate on the @Published readiness flag (not the plain
            // ownerSpaceClient var) so this re-renders once the vault
            // clients are built — otherwise the spinner sticks forever.
            if appState.vaultClientsReady, let osc = appState.ownerSpaceClient {
                ConnectionsHomeContent(ownerSpaceClient: osc, searchText: searchText)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to vault…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ConnectionsHomeContent: View {
    let ownerSpaceClient: OwnerSpaceClient
    let searchText: String

    @StateObject private var connectionsVM: ConnectionsViewModel
    @StateObject private var devicesVM: DeviceManagementViewModel
    @StateObject private var agentsVM: AgentManagementViewModel

    // FAB
    @State private var fabExpanded = false
    @State private var showCreateInvitation = false
    @State private var showScanInvitation = false
    @State private var showConnectDesktop = false
    @State private var showAgentInvitation = false

    init(ownerSpaceClient: OwnerSpaceClient, searchText: String) {
        self.ownerSpaceClient = ownerSpaceClient
        self.searchText = searchText
        _connectionsVM = StateObject(wrappedValue: ConnectionsViewModel(
            authTokenProvider: { nil },
            connectionsClient: ConnectionsClient(ownerSpaceClient: ownerSpaceClient),
            ownerSpaceClient: ownerSpaceClient
        ))
        _devicesVM = StateObject(wrappedValue: DeviceManagementViewModel(ownerSpaceClient: ownerSpaceClient))
        _agentsVM = StateObject(wrappedValue: AgentManagementViewModel(ownerSpaceClient: ownerSpaceClient))
    }

    private var peers: [Connection] {
        let all = connectionsVM.state.connections
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.peerDisplayName.localizedCaseInsensitiveContains(searchText) }
    }

    private var agents: [AgentConnection] {
        if case .loaded(let list) = agentsVM.state { return list }
        return []
    }

    private var devices: [ConnectedDevice] {
        if case .loaded(let list) = devicesVM.state { return list }
        return []
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // All connections render as cards in one list —
                        // no section labels. VettID system card first.
                        NavigationLink {
                            FeedView()
                        } label: {
                            SystemConnectionCard()
                        }
                        .buttonStyle(.plain)

                        ForEach(peers) { peer in
                            NavigationLink {
                                ConnectionDetailView(connectionId: peer.id, authTokenProvider: { nil })
                            } label: {
                                UserConnectionCard(
                                    connection: peer,
                                    onMessage: { route = .message(peer.id) },
                                    onCall: { route = .peer(peer.id) }
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(devices) { device in
                            NavigationLink {
                                DesktopConnectionDetailView(connectionId: device.connectionId, ownerSpaceClient: ownerSpaceClient)
                            } label: {
                                DesktopConnectionCard(device: device, onManage: { route = .desktop(device.connectionId) })
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(agents) { agent in
                            NavigationLink {
                                AgentDetailView(connectionId: agent.connectionId, ownerSpaceClient: ownerSpaceClient)
                            } label: {
                                AgentConnectionCard(agent: agent, onChat: { route = .agent(agent.connectionId) }, onManage: { route = .agent(agent.connectionId) })
                            }
                            .buttonStyle(.plain)
                        }

                        Color.clear.frame(height: 88) // FAB clearance
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .refreshable { await loadAll() }

                fab
            }
        }
        .task { await loadAll() }
        .sheet(isPresented: $showCreateInvitation) { CreateInvitationView(authTokenProvider: { nil }) }
        .sheet(isPresented: $showScanInvitation) { ScanInvitationView(authTokenProvider: { nil }) }
        .sheet(isPresented: $showConnectDesktop) { NavigationView { DevicePairingView() } }
        .sheet(isPresented: $showAgentInvitation) { NavigationView { CreateAgentInvitationView() } }
        // Capability-chip targets, presented as sheets (iOS 16 compatible
        // — navigationDestination(item:) is iOS 17+).
        .sheet(item: $route) { r in
            NavigationView {
                switch r {
                case .message(let id):
                    ConversationView(connectionId: id, authTokenProvider: { nil })
                case .peer(let id):
                    ConnectionDetailView(connectionId: id, authTokenProvider: { nil })
                case .desktop(let id):
                    DesktopConnectionDetailView(connectionId: id, ownerSpaceClient: ownerSpaceClient)
                case .agent(let id):
                    AgentDetailView(connectionId: id, ownerSpaceClient: ownerSpaceClient)
                }
            }
        }
    }

    // Capability-chip navigation target (sheet).
    @State private var route: HomeRoute?

    enum HomeRoute: Identifiable {
        case message(String), peer(String), desktop(String), agent(String)
        var id: String {
            switch self {
            case .message(let s): return "m\(s)"
            case .peer(let s): return "p\(s)"
            case .desktop(let s): return "d\(s)"
            case .agent(let s): return "a\(s)"
            }
        }
    }

    private func loadAll() async {
        // Load SEQUENTIALLY, not concurrently. Three parallel NATS
        // requests over the same connection retrigger the reentrant
        // dispatch_sync crash in AppleNatsClient (subscribe/unsubscribe
        // on the shared state queue) — the cause of the unlock-then-crash.
        await connectionsVM.loadConnections()
        await devicesVM.loadDevices()
        await agentsVM.loadAgents()
    }

    // MARK: - FAB

    private var fab: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if fabExpanded {
                fabAction("Agent Invitation", "sparkles", VettIDColor.agentAccent) { collapseThen { showAgentInvitation = true } }
                fabAction("Connect Desktop", "desktopcomputer", VettIDColor.desktopAccent) { collapseThen { showConnectDesktop = true } }
                fabAction("Scan Invitation", "qrcode.viewfinder", VettIDColor.userAccent) { collapseThen { showScanInvitation = true } }
                fabAction("Create Invitation", "person.badge.plus", VettIDColor.goldDark) { collapseThen { showCreateInvitation = true } }
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { fabExpanded.toggle() }
            } label: {
                Image(systemName: fabExpanded ? "xmark" : "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(VettIDColor.black)
                    .frame(width: 58, height: 58)
                    .background(VettIDColor.gold, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    private func fabAction(_ label: String, _ icon: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            }
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func collapseThen(_ action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { fabExpanded = false }
        action()
    }
}
