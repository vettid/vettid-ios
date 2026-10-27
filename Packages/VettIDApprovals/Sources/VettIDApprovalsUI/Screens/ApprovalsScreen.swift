#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDData
import VettIDUI

/// What the Approvals screen can ask for. Mirrors vettid-android `ApprovalsScreen`'s callbacks and `PausedActions`.
public struct ApprovalsActions {
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var onRetry: @MainActor () -> Void = {}
    public var onDismissPeerDecline: @MainActor (String) -> Void = { _ in }
    public var onResume: @MainActor (String) -> Void = { _ in }
    public var onAskRemove: @MainActor (ConnectionInfo?) -> Void = { _ in }
    public var onRemove: @MainActor () -> Void = {}

    public init() {}
}

/// Approvals (ANDROID-PLAN §4 Approvals): one typed row per request, the connection requests of either side included; a
/// connection's asks within 10 minutes are one row ("Dr Lee asks for 3 things", 0.23.0 §10.4.1) that lists them; a
/// connection whose asks are paused after several declines is a notice with "Resume requests" and "Remove connection".
/// Mirrors vettid-android `ApprovalsScreen`.
public struct ApprovalsScreen: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: ApprovalsState
    let chrome: ShellChrome
    let actions: ApprovalsActions
    @State private var expanded: Set<String> = []

    public init(state: ApprovalsState, chrome: ShellChrome, actions: ApprovalsActions) {
        self.state = state
        self.chrome = chrome
        self.actions = actions
    }

    public var body: some View {
        TopLevelScaffold(title: ApprovalsStrings.title, chrome: chrome) { content }
            .confirmDialog(
                isPresented: Binding(get: { state.confirmRemove != nil }, set: { if !$0 { actions.onAskRemove(nil) } }),
                title: state.confirmRemove.map(ApprovalTexts.removeTitle) ?? "",
                message: ApprovalsStrings.removeBody,
                confirmLabel: ApprovalsStrings.pausedRemove,
                destructive: true,
                onConfirm: actions.onRemove
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("approvals_screen")
    }

    @ViewBuilder private var content: some View {
        if state.loading && state.nothing {
            ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("approvals_loading")
        } else if state.nothing, let error = state.error {
            NoticeCard(.warning, title: ApprovalsStrings.errorTitle, message: error.message(timeScale: timeScale)) {
                NoticeAction(label: ApprovalsStrings.retry, identifier: "approvals_retry", action: actions.onRetry)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("approvals_error")
        } else if state.nothing {
            EmptyState(icon: .approvals, title: ApprovalsStrings.emptyTitle, message: ApprovalsStrings.emptyBody)
                .accessibilityIdentifier("approvals_empty")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // The other member declined a request (0.10.5): it has left the list; told once.
                ForEach(state.peerDeclines, id: \.requestID) { d in
                    NoticeCard(.info, title: ApprovalTexts.peerDeclined(d), message: ApprovalsStrings.peerDeclinedBody) {
                        NoticeAction(label: ApprovalsStrings.ok, identifier: "peer_declined_ok") {
                            actions.onDismissPeerDecline(d.requestID)
                        }
                    }
                    .accessibilityIdentifier("peer_declined_\(d.requestID)")
                    .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                }
                // 0.23.0 §10.4.1: paused after several declines, with the actions that end it.
                ForEach(state.paused) { c in PausedNotice(connection: c, busy: state.busy, actions: actions) }
                ForEach(state.entries, id: \.key) { e in row(e) }
            }
            .padding(.bottom, Spacing.xxl)
        }
        .accessibilityIdentifier("approvals")
    }

    @ViewBuilder private func row(_ e: ApprovalEntry) -> some View {
        switch e {
        case .one(let a):
            ApprovalRow(approval: a, name: state.connectionName(a.connectionID), onOpen: actions.onOpen)
        case .batch(let connectionID, let asks):
            BatchRow(
                key: e.key, asks: asks, receivedAt: e.receivedAt, name: state.connectionName(connectionID),
                open: expanded.contains(e.key), onOpen: actions.onOpen
            ) {
                if expanded.contains(e.key) { expanded.remove(e.key) } else { expanded.insert(e.key) }
            }
        }
    }
}

/// One request's row: its kind, who asks and what, when; bold while it waits for this member's decision.
struct ApprovalRow: View {
    let approval: PendingApproval
    let name: String?
    let onOpen: @MainActor (String) -> Void

    var body: some View {
        let who = ApprovalTexts.who(approval, name: name)
        VettIDListRow(
            title: ApprovalTexts.title(approval, name: name),
            supporting: ApprovalTexts.supporting(approval, name: name),
            meta: ApprovalTimes.short(approval.receivedAt),
            tileName: who ?? "?",
            emphasized: approval.needsDecision,
            onTap: { onOpen(approval.key) }
        )
        .accessibilityIdentifier("approval_\(approval.key)")
    }
}

/// One entry for a batch of a connection's asks (§10.4.1): "Dr Lee asks for 3 things", listing them when opened.
struct BatchRow: View {
    @Environment(\.vettIDColors) private var colors
    let key: String
    let asks: [PendingApproval]
    let receivedAt: Date
    let name: String?
    let open: Bool
    let onOpen: @MainActor (String) -> Void
    let onToggle: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VettIDListRow(
                title: ApprovalTexts.batchTitle(asks: asks.count, name: name),
                supporting: Self.kinds(asks, name: name),
                meta: ApprovalTimes.short(receivedAt),
                tileName: name ?? ApprovalsStrings.aConnection,
                emphasized: true,
                onTap: onToggle
            )
            NoticeAction(
                label: open ? ApprovalsStrings.batchHide : ApprovalsStrings.batchShow, identifier: "approval_batch_toggle_\(key)",
                action: onToggle
            )
            .padding(.leading, Spacing.gutter)
            if open {
                ForEach(asks, id: \.key) { a in
                    ApprovalRow(approval: a, name: name, onOpen: onOpen).padding(.leading, Spacing.xl)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval_\(key)")
    }

    /// The asks' kinds, each once, in order.
    static func kinds(_ asks: [PendingApproval], name: String? = nil) -> String {
        var seen = Set<String>()
        return asks.map { ApprovalTexts.title($0, name: name) }.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }
}

/// "<First>'s requests are paused" (§10.4.1): resume them, or remove the connection (confirmed).
struct PausedNotice: View {
    @Environment(\.vettIDColors) private var colors
    let connection: ConnectionInfo
    let busy: Bool
    let actions: ApprovalsActions

    var body: some View {
        NoticeCard(.warning, title: ApprovalTexts.pausedTitle(connection), message: ApprovalsStrings.pausedBody) {
            NoticeAction(label: ApprovalsStrings.pausedResume, identifier: "paused_resume_\(connection.id)") {
                actions.onResume(connection.id)
            }
            .disabled(busy)
            NoticeAction(label: ApprovalsStrings.pausedRemove, identifier: "paused_remove_\(connection.id)", destructive: true) {
                actions.onAskRemove(connection)
            }
            .disabled(busy)
        }
        .accessibilityIdentifier("paused_\(connection.id)")
        .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
    }
}

/// A notice's text action ("OK", "Try again", "Resume requests").
struct NoticeAction: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    var identifier = ""
    var destructive = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(destructive ? colors.error : colors.primary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Spacing.touchTarget)
        .accessibilityIdentifier(identifier)
    }
}

/// Dates and times as the Approvals screens show them, in the iPhone's zone and locale (vettid-android `Times`).
enum ApprovalTimes {
    /// A full date and time (expiries).
    static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    /// A list row's date: the time today, the weekday this week, else the date.
    static func short(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: d)
        let today = calendar.startOfDay(for: now)
        if day == today { return d.formatted(date: .omitted, time: .shortened) }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), day >= weekAgo, day <= today {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}
#endif
