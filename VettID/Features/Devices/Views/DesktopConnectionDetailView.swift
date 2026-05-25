import SwiftUI

/// Per-desktop detail view — Device card + Session card + Recent
/// activity + Remove desktop (danger zone). Mirrors Android
/// `DesktopConnectionDetailScreen`.
struct DesktopConnectionDetailView: View {
    let connectionId: String

    @StateObject private var viewModel: DesktopConnectionDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingEnd = false
    @State private var confirmingRemove = false

    init(connectionId: String, ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.connectionId = connectionId
        self._viewModel = StateObject(wrappedValue: DesktopConnectionDetailViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView().scaleEffect(1.4)
            case .error(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48)).foregroundStyle(.red)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.red)
                }
                .padding()
            case .loaded(let loaded):
                content(loaded: loaded)
            }
        }
        .navigationTitle(isAgentLoaded ? "Agent" : "Desktop")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load(connectionId: connectionId)
        }
        .alert("End session now?", isPresented: $confirmingEnd) {
            Button("End session", role: .destructive) {
                Task { await viewModel.endSession(connectionId: connectionId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends the current session — the desktop will be locked out until a new session is authorized. The pairing stays in place.")
        }
        .alert(isAgentLoaded ? "Remove agent?" : "Remove desktop?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    await viewModel.remove(connectionId: connectionId) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if isAgentLoaded {
                Text("This revokes the agent's session and retires the pairing. The agent will need a fresh invite code to reconnect.")
            } else {
                Text("This will end the session and erase the desktop's stored credentials on its next sync. The desktop will need to re-pair to reconnect.")
            }
        }
        .alert("Notice", isPresented: Binding(
            get: { viewModel.toast != nil },
            set: { if !$0 { viewModel.toast = nil } }
        )) {
            Button("OK") { viewModel.toast = nil }
        } message: {
            if let msg = viewModel.toast { Text(msg) }
        }
    }

    // MARK: - Loaded content

    /// True when the currently-loaded state describes an agent.
    /// Used to swap copy/labels across the screen.
    private var isAgentLoaded: Bool {
        if case .loaded(let loaded) = viewModel.state { return loaded.connectionType == "agent" }
        return false
    }

    private func content(loaded: DesktopDetailLoaded) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                header(loaded: loaded)
                // Area G (Android 79ab9b2): agent variant shows the
                // Contract section in place of the Session section
                // (agents don't have the rotating-key session model
                // desktops do; the Contract is the truth).
                if loaded.connectionType == "agent" {
                    sectionCard(title: "Identity") { deviceRows(loaded: loaded) }
                    if let contract = loaded.contract {
                        sectionCard(title: "Contract") {
                            contractRows(contract: contract)
                        }
                    }
                } else {
                    sectionCard(title: "Device") { deviceRows(loaded: loaded) }
                    sectionCard(title: "Session") { sessionRows(loaded: loaded) }
                }
                sectionCard(title: "Recent activity") { activityRows() }
                dangerZone()
            }
            .padding(16)
        }
    }

    private func header(loaded: DesktopDetailLoaded) -> some View {
        // Area G (Android ff6e499 + 2cd1968): agent avatar is gold
        // (warning yellow on iOS) so it stands apart from desktops
        // in the connection list.
        let isAgent = loaded.connectionType == "agent"
        let tint: Color = isAgent ? .yellow : .blue
        let icon = isAgent ? "cpu" : "desktopcomputer"
        return VStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(isAgent ? 0.95 : 0.15))
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(isAgent ? .black : tint)
            }
            .frame(width: 64, height: 64)

            Text(loaded.deviceName).font(.title3).fontWeight(.semibold)

            statusPill(loaded: loaded)
        }
        .frame(maxWidth: .infinity)
    }

    /// Area G (Android 79ab9b2): renders the agent's authorized
    /// scope / approval-mode / rate-limit. Read-only — Android added
    /// an editable contract surface in commit 78e0ea9; iOS surfaces
    /// it as a follow-up when the scope editor UI lands.
    private func contractRows(contract: AgentContract) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailRow("Approval mode",
                      contract.approvalMode == "auto_within_contract"
                        ? "Auto within scope"
                        : "Always ask")
            detailRow("Rate limit",
                      contract.rateLimitMax > 0
                        ? "\(contract.rateLimitMax) per \(contract.rateLimitPer)"
                        : "—")
            if contract.scope.isEmpty {
                detailRow("Scope", "—")
            } else {
                HStack(alignment: .top) {
                    Text("Scope")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(contract.scope, id: \.self) { token in
                            let meta = AgentScopeLabels.meta(for: token)
                            HStack(alignment: .top, spacing: 6) {
                                if meta.sensitive {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                Text(meta.label)
                                    .font(.footnote)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func statusPill(loaded: DesktopDetailLoaded) -> some View {
        let active = loaded.sessionStatus == "active"
            && (loaded.sessionExpiresAt.map { $0 > Date() } ?? false)
        let (text, color): (String, Color) = {
            // Area G (Android 79ab9b2): agent paired/revoked pill —
            // distinct vocabulary from the desktop "Session active"
            // / "Session expired" set since agents don't carry a
            // session window.
            if loaded.connectionType == "agent" {
                switch loaded.status {
                case "paired":  return ("Paired", .green)
                case "revoked": return ("Revoked", .red)
                default:         return (loaded.status.capitalized, .secondary)
                }
            }
            if active, let exp = loaded.sessionExpiresAt {
                return ("Session · \(Self.formatRemaining(exp))", .blue)
            }
            switch loaded.sessionStatus {
            case "expired": return ("Session expired", .red)
            case "revoked": return ("Revoked", .red)
            default:
                if loaded.status == "pending_pairing" { return ("Awaiting pairing", .orange) }
                return (loaded.status, .secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func deviceRows(loaded: DesktopDetailLoaded) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Hostname", loaded.hostname.orDash())
            detailRow("Platform", loaded.platform.orDash())
            let os = [loaded.osName, loaded.osVersion].compactMap { $0 }.joined(separator: " ")
            detailRow("OS", os.isEmpty ? "—" : os)
            detailRow("App version", loaded.appVersion.orDash())
            detailRow("Client IP", loaded.clientIp.orDash())
            detailRow("Binary fingerprint", loaded.binaryFingerprint.orDash(), mono: true)
            detailRow("Machine fingerprint", loaded.machineFingerprint.orDash(), mono: true)
            detailRow("Paired", Self.formatDate(loaded.firstSeenAt))
        }
    }

    private func sessionRows(loaded: DesktopDetailLoaded) -> some View {
        Group {
            if loaded.sessionStatus == nil {
                Text("No active session.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    detailRow("Status", loaded.sessionStatus ?? "—")
                    detailRow("Started", Self.formatDate(loaded.sessionStartedAt))
                    detailRow("Expires", Self.formatDate(loaded.sessionExpiresAt))
                    detailRow("Last active", Self.formatDate(loaded.sessionLastActiveAt))
                    let remaining: String = {
                        guard let exp = loaded.sessionExpiresAt else { return "—" }
                        if exp <= Date() { return "expired" }
                        return Self.formatRemaining(exp)
                    }()
                    detailRow("Remaining", remaining)
                    detailRow("Key rotations", String(loaded.sessionKeyRotations))

                    let canEnd = loaded.sessionStatus == "active"
                        && (loaded.sessionExpiresAt.map { $0 > Date() } ?? false)
                    if canEnd {
                        Button {
                            confirmingEnd = true
                        } label: {
                            Text(viewModel.isWorking ? "Ending…" : "End session now")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isWorking)
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    private func activityRows() -> some View {
        Group {
            switch viewModel.activity {
            case .loading:
                Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
            case .error(let m):
                Text(m).font(.subheadline).foregroundStyle(.red)
            case .loaded(let entries):
                if entries.isEmpty {
                    Text("No recent activity.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        // Area C (Android 2150404): screen-section
                        // pill summarising the chain-verification of
                        // the loaded page. Hidden when the chain is
                        // empty (no anchor / pre-chain rows only).
                        chainStatusPill
                        ForEach(entries) { entry in
                            activityRow(for: entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(for entry: DesktopActivityEntry) -> some View {
        let verdict = viewModel.verificationByEntryId[entry.id] ?? .unsigned
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.title).font(.subheadline).fontWeight(.medium)
                Spacer()
                // Inline "Unverified" badge only on tampered rows —
                // Verified / Unsigned would clutter every row, and
                // the section pill already summarises those.
                if verdict == .tampered {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.caption2)
                        Text("Unverified")
                            .font(.caption2).fontWeight(.medium)
                    }
                    .foregroundStyle(.red)
                }
                Text(Self.formatDate(entry.createdAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let body = entry.body, !body.isEmpty {
                Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private struct ChainPillStyle {
        let label: String
        let icon: String
        let color: Color
    }

    private var chainPillStyle: ChainPillStyle? {
        switch viewModel.chainStatus {
        case .empty:
            return nil
        case .verified(let signed, let unsigned):
            let total = signed + unsigned
            let title = unsigned == 0
                ? "\(signed) of \(total) signed — chain verified"
                : "\(signed) of \(total) signed"
            return ChainPillStyle(label: title, icon: "checkmark.shield.fill", color: .green)
        case .unsigned(let rows):
            return ChainPillStyle(
                label: "\(rows) unsigned — unlock to verify",
                icon: "minus.circle",
                color: .orange
            )
        case .tampered:
            return ChainPillStyle(
                label: "Chain tampered",
                icon: "exclamationmark.shield.fill",
                color: .red
            )
        }
    }

    @ViewBuilder
    private var chainStatusPill: some View {
        if let style = chainPillStyle {
            HStack(spacing: 4) {
                Image(systemName: style.icon).font(.caption2)
                Text(style.label).font(.caption2).fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.15))
            .foregroundStyle(style.color)
            .clipShape(Capsule())
        }
    }

    private func dangerZone() -> some View {
        let agent = isAgentLoaded
        return VStack(alignment: .leading, spacing: 8) {
            Text(agent ? "Remove agent" : "Remove desktop")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(.red)
            Text(agent
                 ? "Revokes the agent's session and retires the pairing. The agent will need a fresh invite code to reconnect."
                 : "Ends the session, wipes the desktop's session key, and tells the desktop client to clear its stored credentials.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                confirmingRemove = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text(viewModel.isWorking
                         ? "Removing…"
                         : (agent ? "Remove agent" : "Remove desktop"))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.isWorking)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.08))
        )
    }

    // MARK: - Helpers

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08))
        )
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(mono ? .footnote.monospaced() : .footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func formatDate(_ date: Date?) -> String {
        guard let date = date, date.timeIntervalSince1970 > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func formatRemaining(_ expiresAt: Date) -> String {
        let secs = Int(expiresAt.timeIntervalSinceNow)
        if secs <= 0 { return "0s" }
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 && h > 0 { return "\(d)d \(h)h" }
        if d > 0 { return "\(d)d" }
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}

private extension Optional where Wrapped == String {
    func orDash() -> String {
        guard let v = self, !v.isEmpty else { return "—" }
        return v
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        DesktopConnectionDetailView(connectionId: "preview")
    }
}
#endif
