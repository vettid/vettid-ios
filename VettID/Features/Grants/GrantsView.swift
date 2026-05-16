import SwiftUI

// MARK: - Grants View

/// Top-level Grants surface (Phase 3.4) — three-tab inbox for incoming
/// requests and outstanding grants. Parity with Android `GrantsScreen`.
///
/// Reached from:
///   - the More menu in MainNavigationView,
///   - a `PendingRow.incomingGrantRequest` tap on a connection card,
///   - the connection-detail screen's "Data sharing" section.
///
/// The tabs:
///   - **Pending**: requests awaiting my approve/deny decision. Tap a
///     row → the appropriate approval view (DataGrantApproval /
///     CriticalUseApproval / IdentityVerifyApproval).
///   - **Granted**: outbound grants I've issued (peers I've given
///     access). Tap → revoke option.
///   - **Received**: inbound grants peers have issued to me (held in
///     trust until I fetch).
struct GrantsView: View {

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = GrantsViewModel()
    @State private var selectedTab: GrantsTab = .pending
    /// Phase 3.6-3.8: which pending request to present an approval
    /// screen for. The destination view differs by kind; navigation
    /// pushes onto the NavigationStack the parent already owns.
    @State private var presentedDataRequest: PendingRequestSummary?
    @State private var presentedCriticalUse: CriticalUseApprovalView.Input?
    @State private var presentedVerify: IdentityVerifyApprovalView.Input?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(GrantsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            content
        }
        .navigationTitle("Grants")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        // Push approval destinations onto the stack. Three navigation
        // destinations because each kind of pending request has its own
        // screen — DataGrantApproval doesn't need to know about the
        // critical-use payload shape and vice versa.
        // Each kind of pending request has its own approval screen
        // because the privacy disclosure and the wire-level approve
        // verb differ. Presented as sheets — approval is a modal
        // commitment, not a side-trip on the navigation stack.
        .sheet(item: $presentedDataRequest) { req in
            NavigationView { DataGrantApprovalView(request: req) }
        }
        .sheet(item: $presentedCriticalUse) { input in
            NavigationView { CriticalUseApprovalView(request: input) }
        }
        .sheet(item: $presentedVerify) { input in
            NavigationView { IdentityVerifyApprovalView(request: input) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .pending:
            list(rows: viewModel.pending.map { .pending($0) },
                 emptyTitle: "No pending requests",
                 emptyMessage: "When a connection asks for access to your data, it'll show up here.")
        case .granted:
            list(rows: viewModel.outbound.map { .grant($0, direction: .outbound) },
                 emptyTitle: "Nothing granted yet",
                 emptyMessage: "Grants you've approved will appear here.")
        case .received:
            list(rows: viewModel.inbound.map { .grant($0, direction: .inbound) },
                 emptyTitle: "Nothing received yet",
                 emptyMessage: "When a connection approves a request you've made, it'll appear here.")
        }
    }

    @ViewBuilder
    private func list(rows: [GrantRow], emptyTitle: String, emptyMessage: String) -> some View {
        if rows.isEmpty {
            emptyView(title: emptyTitle, message: emptyMessage)
        } else {
            List(rows) { row in
                grantRow(row)
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func grantRow(_ row: GrantRow) -> some View {
        switch row {
        case .pending(let req):
            PendingRequestRow(request: req)
                .contentShape(Rectangle())
                .onTapGesture {
                    handlePendingTap(req)
                }
        case .grant(let grant, let dir):
            GrantSummaryRow(grant: grant, direction: dir)
        }
    }

    /// Route a pending-request tap to the right approval surface. Each
    /// `GrantItemKind` has its own view because the privacy disclosure
    /// and the wire-level approve verb differ.
    private func handlePendingTap(_ req: PendingRequestSummary) {
        switch req.kind {
        case .data, .minorSecret, .criticalSecretValue:
            presentedDataRequest = req
        case .criticalSecretUse:
            presentedCriticalUse = CriticalUseApprovalView.Input(
                requestId: req.requestId,
                peerLabel: req.peerLabel,
                itemLabel: req.itemLabel,
                operation: req.kind.displayName,
                context: req.reason
            )
        case .identityVerify:
            presentedVerify = IdentityVerifyApprovalView.Input(
                requestId: req.requestId,
                peerLabel: req.peerLabel,
                challenge: req.reason
            )
        }
    }

    private func emptyView(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tab enum

private enum GrantsTab: String, CaseIterable, Identifiable {
    case pending, granted, received

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending:  return "Pending"
        case .granted:  return "Granted"
        case .received: return "Received"
        }
    }
}

// MARK: - Row union

private enum GrantRow: Identifiable {
    case pending(PendingRequestSummary)
    case grant(GrantSummary, direction: GrantSummaryRow.Direction)

    var id: String {
        switch self {
        case .pending(let req):   return "pending-\(req.requestId)"
        case .grant(let g, _):    return "grant-\(g.grantId)"
        }
    }
}

// MARK: - Rows

private struct PendingRequestRow: View {
    let request: PendingRequestSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: request.kind.icon)
                .foregroundStyle(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle).font(.subheadline.weight(.medium))
                Text(rowSubtitle).font(.caption).foregroundStyle(.secondary)
                if !request.reason.isEmpty {
                    Text("\u{201C}\(request.reason)\u{201D}")
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var rowTitle: String {
        let who = request.peerLabel.isEmpty ? "A connection" : request.peerLabel
        let what = request.itemLabel.isEmpty ? request.kind.displayName : request.itemLabel
        return "\(who) wants \(what)"
    }

    private var rowSubtitle: String {
        let mode = request.requestedMode.title
        if let exp = request.requestedExpiresAt {
            return "\(mode) · expires \(Self.relative(exp))"
        }
        return mode
    }

    private static func relative(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta < 0 { return "expired" }
        if delta < 3600 { return "in \(Int(delta / 60))m" }
        if delta < 86400 { return "in \(Int(delta / 3600))h" }
        return "in \(Int(delta / 86400))d"
    }
}

private struct GrantSummaryRow: View {
    enum Direction { case outbound, inbound }
    let grant: GrantSummary
    let direction: Direction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: grant.kind.icon)
                .foregroundStyle(directionTint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle).font(.subheadline.weight(.medium))
                Text(rowSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusChip
        }
        .padding(.vertical, 2)
    }

    private var rowTitle: String {
        let peer = grant.peerLabel.isEmpty ? "Connection" : grant.peerLabel
        return direction == .outbound
            ? "\(peer) · \(grant.itemLabel)"
            : "From \(peer): \(grant.itemLabel)"
    }

    private var rowSubtitle: String {
        var parts: [String] = [grant.mode.title]
        if let exp = grant.expiresAt {
            parts.append("expires \(exp.formatted(.dateTime.day().month().year().hour().minute()))")
        }
        if grant.maxUses > 0 {
            parts.append("\(grant.usesRemaining)/\(grant.maxUses) uses left")
        }
        return parts.joined(separator: " · ")
    }

    private var directionTint: Color {
        direction == .outbound ? .green : .accentColor
    }

    private var statusChip: some View {
        Text(grant.status.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch grant.status.lowercased() {
        case "active":    return .green
        case "expired":   return .secondary
        case "revoked":   return .red
        case "exhausted": return .orange
        default:           return .secondary
        }
    }
}
