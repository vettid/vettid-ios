#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// What an item's screen can ask for (no-ops by default, for previews and tests). Mirrors vettid-android
/// `ItemDetailActions`.
public struct ItemDetailActions {
    public var onBack: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    public var onReveal: @MainActor () -> Void = {}
    public var onOpen: @MainActor () -> Void = {}
    public var onHide: @MainActor () -> Void = {}
    public var onToggleShown: @MainActor (String) -> Void = { _ in }
    public var onEdit: @MainActor () -> Void = {}
    public var onDelete: @MainActor () -> Void = {}
    public var onConfirmDelete: @MainActor () -> Void = {}
    public var onProtection: @MainActor () -> Void = {}
    public var onPickProtection: @MainActor (Sensitivity) -> Void = { _ in }
    public var onConfirmLeaveCritical: @MainActor () -> Void = {}
    public var onDismissDialog: @MainActor () -> Void = {}
    public var onDismissError: @MainActor () -> Void = {}
    public var onPassword: @MainActor (String) -> Void = { _ in }
    public var onSubmitPassword: @MainActor () -> Void = {}
    public var onCancelPassword: @MainActor () -> Void = {}
    /// Copies a value (a field's, or a one-time code) to the pasteboard, local to this iPhone and for a minute.
    public var onCopy: @MainActor (String) -> Void = { SecurePasteboard.copy($0) }

    public init() {}
}

/// An item over its view model. A secret item's values are revealed only after the iPhone's owner is confirmed (Face ID,
/// Touch ID or the passcode, ``UserPresence``); revealed values do not outlive the app leaving the foreground (§10.7:
/// revealed on purpose). Editing reveals nothing (VAULT-MESSAGING 0.21.0 §10.7 Kept values). Mirrors vettid-android
/// `ItemDetailRouteContent`.
public struct ItemDetailRoute: View {
    @Environment(\.vettIDUserPresence) private var presence
    @Environment(\.scenePhase) private var phase
    private let itemID: String
    private let items: any ItemsRepository
    let host: ItemsHost
    /// Made when the screen first appears (never in `init`, which SwiftUI runs again whenever the shell is redrawn).
    @State private var model: ItemDetailViewModel?

    public init(_ itemID: String, items: any ItemsRepository, host: ItemsHost) {
        self.itemID = itemID
        self.items = items
        self.host = host
    }

    public var body: some View {
        let state = model?.state ?? ItemDetailState(itemID: itemID)
        ItemDetailScreen(state: state, actions: Self.actions(model, presence: presence, host: host))
            .onChange(of: phase) { _, now in Self.phaseChanged(now, model) }
            .onChange(of: model?.state.deleted) { _, gone in if gone == true { host.onBack() } }
            .onDisappear { Self.left(model) }
            .onAppear {
                // Back from the editor: the item as saved.
                if let model { model.load() } else { model = ItemDetailViewModel(itemID: itemID, items: items) }
            }
    }

    /// The screen went (back, or another screen over it): the revealed values go.
    static func left(_ model: ItemDetailViewModel?) { model?.hide() }

    /// The app left the foreground: the revealed values go (§10.7: revealed on purpose).
    static func phaseChanged(_ phase: ScenePhase, _ model: ItemDetailViewModel?) {
        if phase == .background { model?.hide() }
    }

    static func actions(_ model: ItemDetailViewModel?, presence: UserPresence, host: ItemsHost) -> ItemDetailActions {
        var a = ItemDetailActions()
        a.onBack = host.onBack
        guard let model else { return a }
        a.onRetry = { model.load() }
        a.onReveal = { model.askReveal { await presence($0) } }
        a.onOpen = { model.open() }
        a.onHide = { model.hide() }
        a.onToggleShown = { model.toggleShown($0) }
        a.onEdit = { if let id = model.state.item?.itemID { host.onEdit(id, nil) } }
        a.onDelete = { model.askDelete() }
        a.onConfirmDelete = { model.confirmDelete() }
        a.onProtection = { model.askProtection() }
        a.onPickProtection = { model.pickProtection($0) }
        a.onConfirmLeaveCritical = { model.confirmLeaveCritical() }
        a.onDismissDialog = { model.dismissDialog() }
        a.onDismissError = { model.dismissError() }
        a.onPassword = { model.setPassword($0) }
        a.onSubmitPassword = { model.submitPassword() }
        a.onCancelPassword = { model.cancelPassword() }
        return a
    }
}

/// An item (ANDROID-PLAN §4, the Vault's detail): its name, category, protection and tags, then its fields in a card,
/// kept out of screenshots and recordings (``SecureContainer``) unless the member allowed them. A `secret` item's values
/// show after "Reveal"; a `critical` item's after the credential password ("Open"). Passwords and one-time code seeds stay
/// masked until shown on purpose; a one-time code field shows the current code. The pill: edit, protection and delete.
/// Mirrors vettid-android `ItemDetailScreen`.
public struct ItemDetailScreen: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemDetailState
    let actions: ItemDetailActions

    public init(state: ItemDetailState, actions: ItemDetailActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        if let prompt = state.prompt, let item = state.item {
            CredentialPasswordScreen(
                prompt: prompt, itemName: item.name, onPassword: actions.onPassword, onSubmit: actions.onSubmitPassword,
                onCancel: actions.onCancelPassword
            )
        } else {
            DetailScaffold(onBack: actions.onBack) {
                content
            } overlay: {
                if state.item != nil, !state.missing {
                    FloatingPillActionBar([
                        PillAction(.edit, label: ItemsStrings.edit, action: actions.onEdit),
                        PillAction(.shield, label: ItemsStrings.protection, action: actions.onProtection),
                        PillAction(.delete, label: ItemsStrings.delete, destructive: true, action: actions.onDelete),
                    ])
                }
            }
            .accessibilityIdentifier("item_detail")
            .modifier(ItemDetailDialogs(state: state, actions: actions))
        }
    }

    @ViewBuilder private var content: some View {
        if state.missing {
            EmptyState(icon: .delete, title: ItemsStrings.missingTitle, message: ItemsStrings.missingBody)
                .accessibilityIdentifier("item_missing")
        } else if let item = state.item {
            ItemDetailBody(item: item, state: state, actions: actions)
        } else if state.loading {
            ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let message = ItemsText.failure(state.error ?? .other, shownCode: state.errorCode)
            NoticeCard(.warning, title: ItemsStrings.errorItem, message: message) {
                Button(ItemsStrings.retry) { actions.onRetry() }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The item's header, the gate (reveal or open), its fields, its notes and its dates.
struct ItemDetailBody: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    let item: ItemDetail
    let state: ItemDetailState
    let actions: ItemDetailActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LargeTitle(item.name).accessibilityIdentifier("item_name")
                HStack(spacing: Spacing.s) {
                    ItemSymbols.sensitivity(item.sensitivity).image.foregroundStyle(colors.primary).accessibilityHidden(true)
                    Text(ItemsStrings.detailKind(ItemsText.category(item.category), ItemsText.sensitivity(item.sensitivity)))
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("item_kind")
                }
                .padding(.horizontal, Spacing.gutter)
                if !item.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.s) { ForEach(item.tags, id: \.self) { TagChip(ItemsText.tagLabel($0), tag: $0) } }
                            .padding(.horizontal, Spacing.gutter)
                    }
                    .padding(.vertical, Spacing.s)
                }
                Spacer().frame(height: Spacing.m)
                if let e = state.error {
                    let message = ItemsText.failure(e, limit: state.limit, shownCode: state.errorCode)
                    NoticeCard(.warning, title: ItemsStrings.errorItem, message: message) {
                        Button(ItemsStrings.ok) { actions.onDismissError() }
                    }
                    .padding(.horizontal, Spacing.s)
                    .padding(.bottom, Spacing.m)
                    .accessibilityIdentifier("item_error")
                }
                ItemGate(item: item, busy: state.busy, actions: actions)
                // The values, the one-time codes and the notes: out of screenshots and recordings (IOS-PLAN §6.4).
                SecureContainer(isSecure: !(allowance?.allowed ?? false)) {
                    ItemValues(item: item, shown: state.shown, actions: actions)
                }
                ItemDates(item: item)
            }
            .padding(.bottom, Spacing.xxl * 2)
        }
    }
}

/// The notice above a hidden item's fields: reveal (secret) or open with the password (critical); hide again.
struct ItemGate: View {
    @Environment(\.vettIDColors) private var colors
    let item: ItemDetail
    let busy: Bool
    let actions: ItemDetailActions

    var body: some View {
        if item.sensitivity != .data {
            Group {
                if !item.revealed && item.sensitivity == .secret {
                    NoticeCard(.info, title: ItemsStrings.secretHiddenTitle, message: ItemsStrings.secretHiddenBody) {
                        Button(ItemsStrings.reveal) { actions.onReveal() }.disabled(busy).accessibilityIdentifier("item_reveal")
                    }
                    .padding(.horizontal, Spacing.s)
                    .accessibilityIdentifier("item_gate")
                } else if !item.revealed {
                    NoticeCard(.info, title: ItemsStrings.criticalHiddenTitle, message: ItemsStrings.criticalHiddenBody) {
                        Button(ItemsStrings.open) { actions.onOpen() }.disabled(busy).accessibilityIdentifier("item_open")
                    }
                    .padding(.horizontal, Spacing.s)
                    .accessibilityIdentifier("item_gate")
                } else {
                    HStack {
                        Spacer()
                        Button(ItemsStrings.hide) { actions.onHide() }
                            .foregroundStyle(colors.primary)
                            .frame(minHeight: Spacing.touchTarget)
                            .accessibilityIdentifier("item_hide")
                    }
                    .padding(.horizontal, Spacing.gutter)
                }
            }
            .padding(.bottom, Spacing.m)
        }
    }
}

/// When the item was created and last updated.
struct ItemDates: View {
    @Environment(\.vettIDColors) private var colors
    let item: ItemDetail

    var body: some View {
        let lines = [
            item.createdAt.map { ItemsStrings.created(ItemTimes.full($0)) },
            item.updatedAt.flatMap { $0 == item.createdAt ? nil : ItemsStrings.updated(ItemTimes.full($0)) },
        ].compactMap { $0 }
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(lines, id: \.self) { Text($0).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant) }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.top, Spacing.m)
    }
}
#endif
