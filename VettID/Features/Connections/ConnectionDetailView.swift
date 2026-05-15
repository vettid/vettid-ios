import SwiftUI

/// Connection detail view
struct ConnectionDetailView: View {
    let connectionId: String
    let authTokenProvider: @Sendable () -> String?

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: ConnectionDetailViewModel
    @State private var showRevokeConfirmation = false
    @State private var showShareSheet = false
    @State private var showRequestDataSheet = false
    @State private var showShareDataSheet = false
    /// Phase 1.9: Them / You tabs.
    @State private var selectedTab: ConnectionDetailTab = .them
    @Environment(\.dismiss) private var dismiss

    init(connectionId: String, authTokenProvider: @escaping @Sendable () -> String?) {
        self.connectionId = connectionId
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: ConnectionDetailViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        ScrollView {
            if viewModel.isLoading {
                loadingView
            } else if let connection = viewModel.connection {
                connectionContent(connection)
            } else if let error = viewModel.errorMessage {
                errorView(error)
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Revoke Connection",
            isPresented: $showRevokeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                Task { await viewModel.revokeConnection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently end the connection. You won't be able to message each other.")
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil && !viewModel.isLoading)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .task {
            // Phase 1.9: wire the Grants client so the Them tab's
            // verify row can initiate challenges via GrantsClient.
            viewModel.grantsClient = appState.grantsClient
            await viewModel.loadConnection(connectionId)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showRequestDataSheet) {
            RequestDataSheet(
                connectionId: connectionId,
                peerName: viewModel.connection?.peerDisplayName ?? "Connection"
            )
        }
        .sheet(isPresented: $showShareDataSheet) {
            ShareDataSheet(
                connectionId: connectionId,
                peerName: viewModel.connection?.peerDisplayName ?? "Connection"
            )
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Connection Content

    private func connectionContent(_ connection: Connection) -> some View {
        // Phase 1.9: Them / You tabs. "Them" shows peer-sourced content
        // and peer-targeted actions (verify identity, peer's catalog).
        // "You" shows what I've shared with this peer (outbound grants).
        // Matches Android's connection-detail tab layout (commit f5cb9fb).
        VStack(spacing: 0) {
            // Avatar + name + status stay above the tabs — they belong
            // to the connection itself, not to either side of the
            // relationship.
            VStack(spacing: 12) {
                BusinessCardView(
                    card: businessCardData(for: connection),
                    avatarSize: 100,
                    connectionId: connection.id
                )
                ConnectionStatusBadge(status: connection.status)
            }
            .padding(.top)
            .padding(.horizontal)

            Picker("Section", selection: $selectedTab) {
                Text("Them").tag(ConnectionDetailTab.them)
                Text("You").tag(ConnectionDetailTab.you)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            switch selectedTab {
            case .them: themTab(connection)
            case .you:  youTab(connection)
            }
        }
    }

    // MARK: - Them tab

    @ViewBuilder
    private func themTab(_ connection: Connection) -> some View {
        VStack(spacing: 16) {
            // Phase 1.9: persistent verify-identity row. Always present
            // in the Them tab so the user can check or refresh the
            // verification state at any time. State sourced from
            // GrantsClient.getVerifyState(connectionId:); tap → verify
            // request (initiates a connection-authenticate.request).
            VerifyIdentityRow(
                connectionId: connection.id,
                onChallenge: { Task { await viewModel.startVerifyChallenge() } }
            )
            .padding(.horizontal)

            if let profile = viewModel.peerProfileData {
                PeerCatalogSummaryCard(
                    peer: .init(connectionId: connection.id,
                                label: connection.peerDisplayName),
                    profile: profile
                )
                .padding(.horizontal)
            }

            ConnectionInfoSection(connection: connection)
                .padding(.horizontal)

            if connection.status == .active {
                actionButtons.padding(.horizontal)
            }
        }
        .padding(.bottom)
    }

    // MARK: - You tab

    @ViewBuilder
    private func youTab(_ connection: Connection) -> some View {
        VStack(spacing: 16) {
            // What I've shared with this peer — outbound grants + the
            // shared-data section (kept for backward compat, still
            // mostly stubs).
            OutboundGrantsForConnectionList(connectionId: connection.id)
                .padding(.horizontal)

            SharedDataSection()
                .padding(.horizontal)
        }
        .padding(.bottom)
    }

    // MARK: - Business card adapter

    /// Pick the richest peer-profile source available and convert it
    /// into a `BusinessCardData`. Preference order: vault-published
    /// `peerProfileData` (has identity key + wallets + fields) →
    /// legacy `Profile` (just bio/location) → fall back to the bare
    /// connection record (display name + avatar URL only).
    private func businessCardData(for connection: Connection) -> BusinessCardData {
        if let preview = viewModel.peerProfileData {
            return BusinessCardData(from: PeerProfilePreview(from: preview))
        }
        if let profile = viewModel.peerProfile {
            return BusinessCardData(from: profile, isOwnProfile: false)
        }
        return BusinessCardData(
            displayName: connection.peerDisplayName,
            avatarUrl: connection.peerAvatarUrl
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Primary actions row
            HStack(spacing: 12) {
                NavigationLink(destination: ConversationView(
                    connectionId: connectionId,
                    authTokenProvider: authTokenProvider
                )) {
                    Label("Message", systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Secondary actions
            HStack(spacing: 12) {
                Button {
                    showRequestDataSheet = true
                } label: {
                    Label("Request Data", systemImage: "arrow.down.doc")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    showShareDataSheet = true
                } label: {
                    Label("Share Data", systemImage: "arrow.up.doc")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            // Danger zone
            Button(role: .destructive) {
                showRevokeConfirmation = true
            } label: {
                if viewModel.isRevoking {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Revoke Connection", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isRevoking)
        }
    }

    // MARK: - Share Items

    private var shareItems: [Any] {
        guard let connection = viewModel.connection else { return [] }

        var items: [Any] = []

        // Basic connection info text
        let shareText = "Connected with \(connection.peerDisplayName) on VettID"
        items.append(shareText)

        // Connection deep link
        if let url = URL(string: "vettid://message/\(connection.id)") {
            items.append(url)
        }

        return items
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

            Button("Retry") {
                Task { await viewModel.loadConnection(connectionId) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Connection Detail Tab (Phase 1.9)

enum ConnectionDetailTab: String, CaseIterable, Identifiable {
    case them, you
    var id: String { rawValue }
}

// MARK: - Verify Identity Row (Phase 1.9)

/// Persistent verify-identity row that lives at the top of the "Them"
/// tab. Pulls per-connection verify state from the vault via
/// `GrantsClient.getVerifyState(connectionId:)` and surfaces the last
/// inbound/outbound result. Tap → kicks a fresh challenge via
/// `connection-authenticate.request`.
///
/// Matches Android's persistent verify row (commit `f5cb9fb`).
struct VerifyIdentityRow: View {

    let connectionId: String
    let onChallenge: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var state: VerifyStatePayload?
    @State private var isLoading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: onChallenge) {
                    Text("Verify")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .verifyStateChanged)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        guard let client = appState.grantsClient else {
            isLoading = false
            return
        }
        isLoading = true
        if let dict = try? await client.getVerifyState(connectionId: connectionId) {
            state = VerifyStatePayload.from(dict: dict)
        }
        isLoading = false
    }

    private var glyph: String {
        guard let state = state else { return "questionmark.circle" }
        if state.lastInboundOk == true || state.lastOutboundOk == true {
            return "checkmark.shield.fill"
        }
        if state.lastInboundOk == false || state.lastOutboundOk == false {
            return "exclamationmark.shield"
        }
        return "shield"
    }

    private var tint: Color {
        guard let state = state else { return .secondary }
        if state.lastInboundOk == true || state.lastOutboundOk == true {
            return .green
        }
        if state.lastInboundOk == false || state.lastOutboundOk == false {
            return .orange
        }
        return .secondary
    }

    private var headline: String {
        if isLoading { return "Checking identity…" }
        guard let state = state else { return "Identity verification" }
        if let last = state.lastOutboundAt,
           state.lastOutboundOk == true {
            return "Identity verified \(relative(last))"
        }
        if let last = state.lastInboundAt,
           state.lastInboundOk == true {
            return "Verified by peer \(relative(last))"
        }
        return "Identity not yet verified"
    }

    private var subtitle: String {
        guard let state = state else {
            return "Tap Verify to challenge this connection's identity."
        }
        if let reason = state.lastOutboundReason ?? state.lastInboundReason,
           !reason.isEmpty {
            return reason
        }
        return "Tap Verify to challenge this connection's identity."
    }

    private func relative(_ date: Date) -> String {
        let delta = -date.timeIntervalSinceNow
        if delta < 60       { return "just now" }
        if delta < 3600     { return "\(Int(delta / 60))m ago" }
        if delta < 86400    { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }
}

extension Notification.Name {
    /// Posted when a verify approve/deny round-trip completes. The
    /// `VerifyIdentityRow` observes this to refresh its state without
    /// re-mounting. `GrantsRepository.handleEvent` fires it on the
    /// verify approve/deny events.
    static let verifyStateChanged = Notification.Name("vettid.verify.stateChanged")
}

// MARK: - Peer Catalog Summary Card (Phase 1.9)

/// Compact card linking out to the full `PeerCatalogView`. Sits in the
/// Them tab so the user has an obvious entry point into the peer's
/// catalog without having to scroll the BusinessCardView's inline rows.
struct PeerCatalogSummaryCard: View {

    let peer: MySharingView.Peer
    let profile: PeerProfileData

    @State private var navigate: Bool = false

    var body: some View {
        Button {
            navigate = true
        } label: {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What \(peer.label.isEmpty ? "they" : peer.label) shares")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .background(
            NavigationLink(
                destination: PeerCatalogView(peer: peer, entries: catalogEntries),
                isActive: $navigate
            ) { EmptyView() }
            .hidden()
        )
    }

    private var subtitle: String {
        let count = catalogEntries.count
        if count == 0 { return "Nothing published yet" }
        return "\(count) \(count == 1 ? "item" : "items") available"
    }

    /// Build catalog entries from the peer's published profile. Data
    /// fields come straight through; wallets are surfaced as catalog
    /// rows. Secrets aren't carried in the legacy PeerProfileData
    /// (would need the vault to publish `secret_catalog` separately).
    private var catalogEntries: [PeerCatalogEntry] {
        var out: [PeerCatalogEntry] = []
        if let fields = profile.visibleFields {
            for (namespace, info) in fields.sorted(by: { $0.key < $1.key }) {
                out.append(PeerCatalogEntry(
                    id: namespace,
                    label: info["display_name"] ?? namespace,
                    alias: nil,
                    category: nil,
                    icon: nil,
                    visibility: "PROFILE"
                ))
            }
        }
        for wallet in profile.wallets ?? [] {
            out.append(PeerCatalogEntry(
                id: "wallet:\(wallet.address)",
                label: wallet.label.isEmpty ? wallet.network.uppercased() : wallet.label,
                alias: wallet.network.uppercased(),
                category: "wallet",
                icon: "bitcoinsign.circle",
                visibility: "PROFILE"
            ))
        }
        return out
    }
}

// MARK: - Outbound Grants For Connection (Phase 1.9)

/// Lists grants the local user has issued to this specific connection.
/// Pulls from `GrantsRepository.outbound` and filters by connectionId.
struct OutboundGrantsForConnectionList: View {

    let connectionId: String
    @ObservedObject private var repo = GrantsRepository.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What you've shared").font(.headline)
                Spacer()
                if !grantsForThisConnection.isEmpty {
                    Text("\(grantsForThisConnection.count) \(grantsForThisConnection.count == 1 ? "grant" : "grants")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if grantsForThisConnection.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Nothing shared with this connection yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                ForEach(grantsForThisConnection) { grant in
                    OutboundGrantRow(grant: grant)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var grantsForThisConnection: [GrantSummary] {
        repo.outbound.filter { $0.connectionId == connectionId }
    }
}

private struct OutboundGrantRow: View {
    let grant: GrantSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: grant.kind.icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(grant.itemLabel.isEmpty ? grant.kind.displayName : grant.itemLabel)
                    .font(.subheadline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(grant.status.capitalized)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.15))
                .foregroundStyle(tint)
                .cornerRadius(4)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = [grant.mode.title]
        if let exp = grant.expiresAt {
            parts.append("expires \(exp.formatted(.dateTime.day().month().year()))")
        }
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        switch grant.status.lowercased() {
        case "active":    return .green
        case "expired":   return .secondary
        case "revoked":   return .red
        case "exhausted": return .orange
        default:           return .secondary
        }
    }
}

// MARK: - Profile Info Section (retired in Phase 1.5)
//
// Replaced by `BusinessCardView` which renders bio + location alongside
// the rest of the business card. Left a stub here briefly in case any
// preview/test re-introduces it; can be deleted once no references
// remain in any branch.

// MARK: - Shared Data Section

struct SharedDataSection: View {
    // TODO: Load actual shared data from connection
    @State private var sharedItems: [SharedDataItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shared Data")
                    .font(.headline)
                Spacer()
                if !sharedItems.isEmpty {
                    Text("\(sharedItems.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if sharedItems.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No data shared yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ForEach(sharedItems) { item in
                    SharedDataItemRow(item: item)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct SharedDataItem: Identifiable {
    let id: String
    let type: SharedDataType
    let label: String
    let sharedAt: Date
    let direction: SharedDirection

    enum SharedDataType {
        case credential
        case document
        case profile
        case custom

        var icon: String {
            switch self {
            case .credential: return "key.fill"
            case .document: return "doc.fill"
            case .profile: return "person.fill"
            case .custom: return "cube.fill"
            }
        }

        var color: Color {
            switch self {
            case .credential: return .purple
            case .document: return .orange
            case .profile: return .blue
            case .custom: return .gray
            }
        }
    }

    enum SharedDirection {
        case sent
        case received
    }
}

struct SharedDataItemRow: View {
    let item: SharedDataItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.icon)
                .font(.body)
                .foregroundStyle(item.type.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.subheadline)
                HStack(spacing: 4) {
                    Image(systemName: item.direction == .sent ? "arrow.up.right" : "arrow.down.left")
                        .font(.caption2)
                    Text(item.direction == .sent ? "Sent" : "Received")
                        .font(.caption)
                    Text("·")
                    Text(item.sharedAt, style: .relative)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Connection Info Section

struct ConnectionInfoSection: View {
    let connection: Connection

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Connected since")
                    .foregroundColor(.secondary)
                Spacer()
                Text(connection.createdAt, style: .date)
            }
            .font(.subheadline)

            if let lastMessageAt = connection.lastMessageAt {
                Divider()
                HStack {
                    Text("Last message")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(lastMessageAt, style: .relative)
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Share Sheet (UIKit)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Request Data Sheet

struct RequestDataSheet: View {
    let connectionId: String
    let peerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDataTypes: Set<RequestableDataType> = []
    @State private var isRequesting = false
    @State private var requestSent = false

    enum RequestableDataType: String, CaseIterable, Identifiable {
        case email = "Email Address"
        case phone = "Phone Number"
        case name = "Full Name"
        case address = "Address"
        case organization = "Organization"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .email: return "envelope.fill"
            case .phone: return "phone.fill"
            case .name: return "person.fill"
            case .address: return "location.fill"
            case .organization: return "building.2.fill"
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if requestSent {
                    requestSentView
                } else {
                    requestFormView
                }
            }
            .navigationTitle("Request Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var requestFormView: some View {
        VStack(spacing: 20) {
            Text("Select the data you'd like to request from \(peerName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.top)

            List {
                ForEach(RequestableDataType.allCases) { dataType in
                    Button {
                        if selectedDataTypes.contains(dataType) {
                            selectedDataTypes.remove(dataType)
                        } else {
                            selectedDataTypes.insert(dataType)
                        }
                    } label: {
                        HStack {
                            Image(systemName: dataType.icon)
                                .foregroundStyle(.blue)
                                .frame(width: 24)

                            Text(dataType.rawValue)
                                .foregroundStyle(.primary)

                            Spacer()

                            if selectedDataTypes.contains(dataType) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            Button {
                sendRequest()
            } label: {
                if isRequesting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Send Request")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedDataTypes.isEmpty || isRequesting)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var requestSentView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Request Sent")
                .font(.title2)
                .fontWeight(.bold)

            Text("\(peerName) will be notified of your data request.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private func sendRequest() {
        isRequesting = true

        // Simulate sending request via NATS/VaultResponseHandler
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                isRequesting = false
                requestSent = true
            }
        }
    }
}

// MARK: - Share Data Sheet

struct ShareDataSheet: View {
    let connectionId: String
    let peerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDataFields: Set<ShareableDataField> = []
    @State private var isSharing = false
    @State private var dataSent = false

    enum ShareableDataField: String, CaseIterable, Identifiable {
        case displayName = "Display Name"
        case email = "Email Address"
        case phone = "Phone Number"
        case bio = "Bio"
        case location = "Location"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .displayName: return "person.fill"
            case .email: return "envelope.fill"
            case .phone: return "phone.fill"
            case .bio: return "text.quote"
            case .location: return "location.fill"
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if dataSent {
                    dataSentView
                } else {
                    shareFormView
                }
            }
            .navigationTitle("Share Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var shareFormView: some View {
        VStack(spacing: 20) {
            Text("Select the data you'd like to share with \(peerName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.top)

            List {
                ForEach(ShareableDataField.allCases) { field in
                    Button {
                        if selectedDataFields.contains(field) {
                            selectedDataFields.remove(field)
                        } else {
                            selectedDataFields.insert(field)
                        }
                    } label: {
                        HStack {
                            Image(systemName: field.icon)
                                .foregroundStyle(.purple)
                                .frame(width: 24)

                            Text(field.rawValue)
                                .foregroundStyle(.primary)

                            Spacer()

                            if selectedDataFields.contains(field) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.purple)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            Button {
                shareData()
            } label: {
                if isSharing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Share Selected Data")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(selectedDataFields.isEmpty || isSharing)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var dataSentView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.purple)

            Text("Data Shared")
                .font(.title2)
                .fontWeight(.bold)

            Text("Your selected data has been shared with \(peerName).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .padding()
        }
    }

    private func shareData() {
        isSharing = true

        // Simulate sharing data via NATS/VaultResponseHandler
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                isSharing = false
                dataSent = true
            }
        }
    }
}

#if DEBUG
struct ConnectionDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ConnectionDetailView(
                connectionId: "test-id",
                authTokenProvider: { "test-token" }
            )
        }
    }
}
#endif
