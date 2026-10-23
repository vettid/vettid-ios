#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// What the rule editor can ask for (no-ops by default, for previews and tests). Mirrors vettid-android `RuleEditActions`.
public struct RuleEditActions {
    public var onBack: @MainActor () -> Void = {}
    /// Chooses the rule's one tag (owner decision 2026-10-09).
    public var onTag: @MainActor (String) -> Void = { _ in }
    public var onMode: @MainActor (ShareMode) -> Void = { _ in }
    public var onIncludeExisting: @MainActor (Bool) -> Void = { _ in }
    public var onUses: @MainActor (String) -> Void = { _ in }
    /// 0.23.0 §10.12: fetches per hour and per day of all the rule's items together.
    public var onPerHour: @MainActor (String) -> Void = { _ in }
    public var onPerDay: @MainActor (String) -> Void = { _ in }
    public var onExpiry: @MainActor (RuleExpiry) -> Void = { _ in }
    /// The custom end's day, as the date picker gives it.
    public var onEndDate: @MainActor (RuleEnds.Day) -> Void = { _ in }
    /// The custom end's time, hour and minute in the member's zone.
    public var onEndTime: @MainActor (Int, Int) -> Void = { _, _ in }
    public var onCancelEnd: @MainActor () -> Void = {}
    public var onSave: @MainActor () -> Void = {}
    public var onAskDelete: @MainActor (Bool) -> Void = { _ in }
    public var onDelete: @MainActor () -> Void = {}
    public var onDismissError: @MainActor () -> Void = {}
    /// "Already shared — edit its rule": the rule of this connection that shares that tag.
    public var onOpenRule: @MainActor (String) -> Void = { _ in }
    /// Back or up with changes: "Discard changes to this rule?".
    public var onAskDiscard: @MainActor () -> Void = {}
    public var onDiscard: @MainActor () -> Void = {}
    public var onKeepEditing: @MainActor () -> Void = {}

    public init() {}
}

/// A share rule over its view model ([ruleID] nil: a new one), made when the screen first appears (never in `init`, which
/// SwiftUI runs again whenever the shell is redrawn). Once saved or deleted it leaves; when the vault's items are cleared
/// (a lock, the hold, a wipe) the draft is dropped and it leaves. Mirrors vettid-android `RuleEditRouteContent`.
public struct RuleEditRoute: View {
    private let connectionID: String
    private let ruleID: String?
    private let sharing: any SharingRepository
    private let items: any ItemsRepository
    private let connections: any ConnectionsRepository
    let host: ItemsHost
    @State private var model: RuleEditViewModel?

    public init(
        connectionID: String, ruleID: String?, sharing: any SharingRepository, items: any ItemsRepository,
        connections: any ConnectionsRepository, host: ItemsHost
    ) {
        self.connectionID = connectionID
        self.ruleID = ruleID
        self.sharing = sharing
        self.items = items
        self.connections = connections
        self.host = host
    }

    public var body: some View {
        RuleEditScreen(state: model?.state ?? loadingState, actions: Self.actions(model, connectionID: connectionID, host: host))
            .onAppear {
                if model == nil {
                    model = RuleEditViewModel(
                        connectionID: connectionID, ruleID: ruleID, sharing: sharing, items: items, connections: connections
                    )
                }
            }
            .onChange(of: model?.state.done) { _, done in if done == true { host.onBack() } }
            .onChange(of: model?.closed) { _, closed in if closed == true { host.onBack() } }
    }

    private var loadingState: RuleEditState { RuleEditState(draft: RuleDraft(connectionID: connectionID), loading: true) }

    static func actions(_ m: RuleEditViewModel?, connectionID id: String, host: ItemsHost) -> RuleEditActions {
        var a = RuleEditActions()
        a.onBack = host.onBack
        a.onOpenRule = { host.onOpenRule(id, $0) }
        guard let m else { return a }
        a.onTag = { m.selectTag($0) }
        a.onMode = { m.setMode($0) }
        a.onIncludeExisting = { m.setIncludeExisting($0) }
        a.onUses = { m.setUses($0) }
        a.onPerHour = { m.setPerHour($0) }
        a.onPerDay = { m.setPerDay($0) }
        a.onExpiry = { m.setExpiry($0) }
        a.onEndDate = { m.pickEndDate($0) }
        a.onEndTime = { m.pickEndTime(hour: $0, minute: $1) }
        a.onCancelEnd = { m.cancelEndPicker() }
        a.onSave = { m.save() }
        a.onAskDelete = { m.askDelete($0) }
        a.onDelete = { m.delete() }
        a.onDismissError = { m.dismissError() }
        a.onAskDiscard = { m.askDiscard(true) }
        a.onDiscard = {
            m.askDiscard(false)
            host.onBack()
        }
        a.onKeepEditing = { m.askDiscard(false) }
        return a
    }
}

/// One share rule (§10.12): the one tag it shares (owner decision 2026-10-09; the chosen chip in its colour with a gold
/// outline and a check mark, a tag another rule already shares opens that rule), "Ask me each time" (the default) or "Share
/// automatically", fetches of each item and (0.23.0) per hour and per day of all its items, an end (presets, or "Custom…":
/// a date and a time in the member's zone), and whether the items that already match count. The connection's other rules
/// covering the same items are named by their tags, with the 0.23.0 rule: asking wins. The vault's dry run lists what it
/// matches and what saving does to each item. "Save rule" is in the top bar (as the item editor's "Save item"); leaving
/// with changes asks first. A rule that names several tags is shown read-only and can be deleted. Mirrors vettid-android
/// `RuleEditScreen`.
public struct RuleEditScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: RuleEditState
    let actions: RuleEditActions

    public init(state: RuleEditState, actions: RuleEditActions) {
        self.state = state
        self.actions = actions
    }

    private var name: String { ItemsText.sharingName(state.connectionName) }

    public var body: some View {
        let leave = { @MainActor in if state.dirty { actions.onAskDiscard() } else { actions.onBack() } }
        FormScaffold(
            title: state.isNew ? ItemsStrings.ruleNewTitle : ItemsStrings.ruleEditTitle,
            message: ItemsStrings.ruleBody(name),
            primaryLabel: nil,
            onPrimary: {},
            onBack: leave,
            header: { HeaderGlyph(symbol: .share) },
            topActions: {
                if !state.readOnly {
                    TopBarTextAction(ItemsStrings.ruleSave, enabled: state.canSave, busy: state.busy, action: actions.onSave)
                        .accessibilityIdentifier("rule_save")
                }
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SharingErrorNotice(error: state.error, limit: state.limit, code: state.errorCode, onDismiss: actions.onDismissError)
                if state.atRuleLimit { RuleLimitNotice() }
                if state.readOnly {
                    ReadOnlyRule(state: state)
                } else {
                    RuleTagsSection(state: state, name: name, actions: actions)
                    RuleModeSection(mode: state.draft.mode, onMode: actions.onMode)
                    RuleLimitsSection(state: state, actions: actions)
                    RuleEndsSection(state: state, onExpiry: actions.onExpiry)
                    RuleExistingSwitch(on: state.draft.includeExisting, onChange: actions.onIncludeExisting)
                }
                if !state.overlaps.isEmpty { RuleOverlapCard(state: state) }
                RulePreviewCard(state: state)
                if !state.isNew {
                    Button { actions.onAskDelete(true) } label: {
                        Text(ItemsStrings.ruleDelete)
                            .vettIDFont(.labelLarge)
                            .foregroundStyle(state.busy ? colors.onSurfaceVariant : colors.error)
                            .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.busy)
                    .accessibilityIdentifier("rule_delete")
                }
            }
        }
        .accessibilityIdentifier("rule_edit")
        // The system back gestures would leave without asking: with changes, back is the arrow, which asks.
        .blocksBackGesture(state.dirty)
        .modifier(RuleEditDialogs(state: state, name: name, actions: actions))
    }
}
#endif
