#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// What a connection's sharing screen can ask for (no-ops by default, for previews and tests). Mirrors vettid-android
/// `ConnectionSharingActions`, without its `onOpenItem`, which that screen never uses.
public struct ConnectionSharingActions {
    public var onBack: @MainActor () -> Void = {}
    public var onNewRule: @MainActor () -> Void = {}
    public var onOpenRule: @MainActor (String) -> Void = { _ in }
    public var onAskRevoke: @MainActor (GrantView?) -> Void = { _ in }
    public var onRevoke: @MainActor () -> Void = {}
    public var onDismissError: @MainActor () -> Void = {}

    public init() {}
}

/// What one connection can see of the member's vault (its share rules and grants) over its view model, made when the
/// screen first appears (never in `init`, which SwiftUI runs again whenever the shell is redrawn) and read again whenever
/// the screen comes back (from a rule). Mirrors vettid-android `ConnectionSharingRouteContent`.
public struct ConnectionSharingRoute: View {
    private let connectionID: String
    private let sharing: any SharingRepository
    private let items: any ItemsRepository
    private let connections: any ConnectionsRepository
    let host: ItemsHost
    @State private var model: ConnectionSharingViewModel?

    public init(
        _ connectionID: String, sharing: any SharingRepository, items: any ItemsRepository, connections: any ConnectionsRepository,
        host: ItemsHost
    ) {
        self.connectionID = connectionID
        self.sharing = sharing
        self.items = items
        self.connections = connections
        self.host = host
    }

    public var body: some View {
        ConnectionSharingScreen(state: model?.state ?? ConnectionSharingState(connectionID: connectionID), actions: actions(model))
            .onAppear {
                if let model { model.load() } else {
                    model = ConnectionSharingViewModel(connectionID: connectionID, sharing: sharing, items: items, connections: connections)
                }
            }
    }

    private func actions(_ m: ConnectionSharingViewModel?) -> ConnectionSharingActions {
        let host = host, id = connectionID
        var a = ConnectionSharingActions()
        a.onBack = host.onBack
        a.onNewRule = { host.onOpenRule(id, nil) }
        a.onOpenRule = { host.onOpenRule(id, $0) }
        a.onAskRevoke = { m?.askRevoke($0) }
        a.onRevoke = { m?.revoke() }
        a.onDismissError = { m?.dismissError() }
        return a
    }
}

/// "What <name> can see" (VAULT-ITEMS §6): the share rules by tag with their mode, then what the connection can fetch now
/// (each grant, from a rule or a one-off request, revocable) and the critical items it can only ask to use. Mirrors
/// vettid-android `ConnectionSharingScreen`.
public struct ConnectionSharingScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: ConnectionSharingState
    let actions: ConnectionSharingActions

    public init(state: ConnectionSharingState, actions: ConnectionSharingActions) {
        self.state = state
        self.actions = actions
    }

    private var name: String { ItemsText.sharingName(state.connectionName) }

    public var body: some View {
        DetailScaffold(onBack: actions.onBack) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LargeTitle(ItemsStrings.sharingTitle(name))
                    Text(ItemsStrings.sharingBody(name))
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .padding(.horizontal, Spacing.gutter)
                    SharingErrorNotice(error: state.error, limit: state.limit, code: state.errorCode, onDismiss: actions.onDismissError)
                    if state.loading && state.rules.isEmpty {
                        ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity).padding(Spacing.xl)
                    }
                    rules
                    if state.pendingCount > 0 {
                        NoticeCard(
                            .info, title: ItemsStrings.sharingPendingTitle, message: ItemsStrings.sharingPendingBody(state.pendingCount)
                        )
                            .padding(.horizontal, Spacing.s)
                    }
                    given
                }
                .padding(.bottom, Spacing.xxl)
            }
        }
        .accessibilityIdentifier("connection_sharing")
        .confirmDialog(
            isPresented: Binding(get: { state.confirmRevoke != nil }, set: { if !$0 { actions.onAskRevoke(nil) } }),
            title: ItemsStrings.sharingRevokeTitle(state.confirmRevoke?.name ?? ""),
            message: state.confirmRevoke?.ruleID != nil ? ItemsStrings.sharingRevokeBodyRule(name) : ItemsStrings.sharingRevokeBody(name),
            confirmLabel: ItemsStrings.sharingRevoke, destructive: true, onConfirm: actions.onRevoke
        )
    }

    /// The connection's rules, each with its own settings (§10.12), and "Add a rule" up to 64.
    @ViewBuilder private var rules: some View {
        SettingsSectionHeader(ItemsStrings.sharingRules)
        if !state.loading && state.rules.isEmpty {
            Text(ItemsStrings.sharingNoRules(name))
                .foregroundStyle(colors.onSurfaceVariant)
                .padding(.horizontal, Spacing.gutter)
                .accessibilityIdentifier("sharing_no_rules")
        }
        let names = RuleNames.of(state.rules)
        let overlaps = state.overlaps
        ForEach(state.rules) { r in
            RuleCard(rule: r, overlaps: overlaps[r.ruleID] ?? [], names: names, onOpen: actions.onOpenRule)
        }
        if state.atRuleLimit { RuleLimitNotice().padding(.horizontal, Spacing.s) }
        SecondaryButton(ItemsStrings.sharingNewRule) { actions.onNewRule() }
            .disabled(state.atRuleLimit)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
            .accessibilityIdentifier("sharing_new_rule")
    }

    /// What the connection can fetch now, and the critical items it can only ask to use.
    @ViewBuilder private var given: some View {
        SettingsSectionHeader(ItemsStrings.sharingCanSee(name))
        if state.active.isEmpty && state.usable.isEmpty {
            Text(ItemsStrings.sharingNothing(name))
                .foregroundStyle(colors.onSurfaceVariant)
                .padding(.horizontal, Spacing.gutter)
                .accessibilityIdentifier("sharing_nothing")
        }
        ForEach(state.active) { g in GrantRow(grant: g, onRevoke: actions.onAskRevoke) }
        ForEach(state.usable, id: \.self) { id in
            Text(ItemsStrings.sharingUsable(state.items[id]?.name ?? ItemsStrings.deletedItem))
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.xs)
        }
    }
}

/// A rule of this connection: its tag (in the tag's colour), mode, limits, end, what it shares now and the other rules
/// covering the same items, named by their tags with the 0.23.0 rule (asking wins). Mirrors vettid-android `RuleCard`.
struct RuleCard: View {
    @Environment(\.vettIDColors) private var colors
    let rule: ShareRule
    let overlaps: [ShareRule]
    let names: [String: RuleNames.Name]
    let onOpen: @MainActor (String) -> Void

    var body: some View {
        DetailCard {
            ChipFlow { ForEach(rule.tags, id: \.self) { TagChip(ItemsText.tagLabel($0), tag: $0) } }
            Spacer().frame(height: Spacing.s)
            if rule.tags.count > 1 {
                Text(rule.match == .all ? ItemsStrings.ruleMatchAllShort : ItemsStrings.ruleMatchAnyShort)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
            }
            Text(ItemsText.ruleMode(rule.mode)).vettIDFont(.bodyMedium, weight: .semibold)
            Text(ItemsText.ruleLimits(rule)).vettIDFont(.bodySmall)
            Text(ItemsText.ruleCounts(rule)).vettIDFont(.bodySmall)
            if let also = ItemsText.overlap(rule, overlaps, names: names) {
                Text(also)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("rule_also_\(rule.ruleID)")
            }
            Button { onOpen(rule.ruleID) } label: {
                Text(ItemsStrings.ruleChange)
                    .vettIDFont(.labelLarge)
                    .foregroundStyle(colors.primary)
                    .frame(minHeight: Spacing.touchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rule_change_\(rule.ruleID)")
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rule_\(rule.ruleID)")
    }
}

/// A grant given to the connection, with "Revoke". Mirrors vettid-android `GrantRow`.
struct GrantRow: View {
    @Environment(\.vettIDColors) private var colors
    let grant: GrantView
    let onRevoke: @MainActor (GrantView?) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(grant.name.isEmpty ? ItemsStrings.deletedItem : grant.name).vettIDFont(.bodyLarge)
                Text(ItemsText.givenLine(grant)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { onRevoke(grant) } label: {
                Text(ItemsStrings.sharingRevoke)
                    .vettIDFont(.labelLarge)
                    .foregroundStyle(colors.error)
                    .frame(minHeight: Spacing.touchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("revoke_\(grant.grantID)")
        }
        .padding(.leading, Spacing.gutter)
        .padding(.trailing, Spacing.s)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("grant_\(grant.grantID)")
    }
}
#endif
