#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// What the add/edit screen can ask for (no-ops by default, for previews and tests). Mirrors vettid-android
/// `ItemEditActions`.
public struct ItemEditActions {
    /// Leaves the editor (nothing unsaved, or after "Discard").
    public var onBack: @MainActor () -> Void = {}
    /// Back with unsaved changes: "Discard changes to this item?".
    public var onAskDiscard: @MainActor () -> Void = {}
    public var onDiscard: @MainActor () -> Void = {}
    public var onKeepEditing: @MainActor () -> Void = {}
    public var onName: @MainActor (String) -> Void = { _ in }
    public var onCategory: @MainActor (String) -> Void = { _ in }
    public var onSensitivity: @MainActor (Sensitivity) -> Void = { _ in }
    public var onNotes: @MainActor (String) -> Void = { _ in }
    public var onRemoveNotes: @MainActor () -> Void = {}
    public var onTagInput: @MainActor (String) -> Void = { _ in }
    public var onAddTag: @MainActor () -> Void = {}
    public var onRemoveTag: @MainActor (String) -> Void = { _ in }
    public var onInProfile: @MainActor (Bool) -> Void = { _ in }
    public var onFieldText: @MainActor (Int, String) -> Void = { _, _ in }
    public var onFieldAddress: @MainActor (Int, AddressValue) -> Void = { _, _ in }
    public var onAskAddField: @MainActor () -> Void = {}
    public var onAskRenameField: @MainActor (Int) -> Void = { _ in }
    public var onAskFieldKind: @MainActor (Int) -> Void = { _ in }
    public var onAskNewCategory: @MainActor () -> Void = {}
    public var onDialogText: @MainActor (String) -> Void = { _ in }
    public var onDialogKind: @MainActor (String) -> Void = { _ in }
    public var onConfirmDialog: @MainActor () -> Void = {}
    public var onDismissDialog: @MainActor () -> Void = {}
    public var onFieldFocused: @MainActor () -> Void = {}
    public var onRemoveField: @MainActor (Int) -> Void = { _ in }
    public var onMoveField: @MainActor (Int, Int) -> Void = { _, _ in }
    public var onSave: @MainActor () -> Void = {}
    public var onDismissError: @MainActor () -> Void = {}
    public var onPassword: @MainActor (String) -> Void = { _ in }
    public var onSubmitPassword: @MainActor () -> Void = {}
    public var onCancelPassword: @MainActor () -> Void = {}
    public var onConfirmLeaveCritical: @MainActor () -> Void = {}
    public var onDismissLeaveCritical: @MainActor () -> Void = {}

    public init() {}
}

/// Adding ([itemID] nil, from [template] or blank) or editing an item over its view model. Once saved it leaves for the
/// item's screen; when the vault's items are cleared (a lock, the hold, a wipe) what was typed is dropped and it leaves.
/// Mirrors vettid-android `ItemEditRouteContent`.
public struct ItemEditRoute: View {
    private let itemID: String?
    private let template: String?
    private let items: any ItemsRepository
    private let sharing: (any SharingRepository)?
    private let connections: (any ConnectionsRepository)?
    let host: ItemsHost
    /// Made when the screen first appears (never in `init`, which SwiftUI runs again whenever the shell is redrawn).
    @State private var model: ItemEditViewModel?

    public init(
        itemID: String?, template: String?, items: any ItemsRepository, sharing: (any SharingRepository)?,
        connections: (any ConnectionsRepository)?, host: ItemsHost
    ) {
        self.itemID = itemID
        self.template = template
        self.items = items
        self.sharing = sharing
        self.connections = connections
        self.host = host
    }

    public var body: some View {
        Group {
            if let model {
                ItemEditScreen(state: model.state, actions: actions(model))
            } else {
                ItemEditScreen(state: loadingState, actions: ItemEditActions())
            }
        }
        .onAppear {
            if model == nil {
                model = ItemEditViewModel(itemID: itemID, template: template, items: items, sharing: sharing, connections: connections)
            }
        }
        .onChange(of: model?.state.savedID) { _, id in if let id = id ?? nil { host.replaceWithItem(id) } }
        .onChange(of: model?.closed) { _, closed in if closed == true { host.onBack() } }
    }

    private var loadingState: ItemEditState {
        var s = ItemEditState(itemID: itemID)
        s.loading = true
        return s
    }

    private func actions(_ m: ItemEditViewModel) -> ItemEditActions {
        let host = host
        var a = ItemEditActions()
        a.onBack = host.onBack
        a.onAskDiscard = { m.askDiscard(true) }
        a.onDiscard = {
            m.askDiscard(false)
            host.onBack()
        }
        a.onKeepEditing = { m.askDiscard(false) }
        a.onName = { m.setName($0) }
        a.onCategory = { m.setCategory($0) }
        a.onSensitivity = { m.setSensitivity($0) }
        a.onNotes = { m.setNotes($0) }
        a.onRemoveNotes = { m.removeNotes() }
        a.onTagInput = { m.setTagInput($0) }
        a.onAddTag = { m.addTag() }
        a.onRemoveTag = { m.removeTag($0) }
        a.onInProfile = { m.setInProfile($0) }
        a.onFieldText = { m.setFieldText($0, $1) }
        a.onFieldAddress = { m.setFieldAddress($0, $1) }
        a.onAskAddField = { m.askAddField() }
        a.onAskRenameField = { m.askRenameField($0) }
        a.onAskFieldKind = { m.askFieldKind($0) }
        a.onAskNewCategory = { m.askNewCategory() }
        a.onDialogText = { m.setDialogText($0) }
        a.onDialogKind = { m.setDialogKind($0) }
        a.onConfirmDialog = { m.confirmDialog() }
        a.onDismissDialog = { m.dismissDialog() }
        a.onFieldFocused = { m.fieldFocused() }
        a.onRemoveField = { m.removeField($0) }
        a.onMoveField = { m.moveField($0, by: $1) }
        a.onSave = { m.save() }
        a.onDismissError = { m.dismissError() }
        a.onPassword = { m.setPassword($0) }
        a.onSubmitPassword = { m.submitPassword() }
        a.onCancelPassword = { m.cancelPassword() }
        a.onConfirmLeaveCritical = { m.confirmLeaveCritical() }
        a.onDismissLeaveCritical = { m.dismissLeaveCritical() }
        return a
    }
}

/// Adding or editing an item (VAULT-ITEMS §9: name, category, protection, tags, fields; §10.7's checks before anything is
/// sent). A new item picks its protection here; a critical one is saved with the credential password. A secret or
/// critical item's stored values show as kept, never revealed (VAULT-MESSAGING 0.21.0 §10.7 Kept values): typing into a
/// field replaces its value; its values and notes are typed on a keyboard that does not learn, with no AutoFill. Fields
/// are value-first: one input captioned with the field's label, its type as a hint, and a menu to rename, retype (unsaved
/// fields), move or remove it. Saving is "Save item" in the top bar; back with unsaved changes asks first. Mirrors
/// vettid-android `ItemEditScreen`.
public struct ItemEditScreen: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    let state: ItemEditState
    let actions: ItemEditActions

    public init(state: ItemEditState, actions: ItemEditActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        // A ZStack keeps its identity whichever step it shows, so that the gesture block below stays on one probe.
        ZStack {
            if let prompt = state.prompt {
                CredentialPasswordScreen(
                    prompt: prompt, itemName: state.shownName, onPassword: actions.onPassword, onSubmit: actions.onSubmitPassword,
                    onCancel: actions.onCancelPassword
                )
            } else if state.loading {
                ProgressView().tint(colors.primary.color).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        // The system back gestures would leave without asking: with unsaved changes (the password step included), back is
        // the arrow, which asks.
        .blocksBackGesture(state.dirty)
    }

    private var form: some View {
        let d = state.draft
        let leave = { @MainActor in if state.dirty { actions.onAskDiscard() } else { actions.onBack() } }
        return FormScaffold(
            title: state.isNew ? ItemsStrings.newTitle : ItemsStrings.editTitle,
            primaryLabel: nil,
            onPrimary: {},
            onBack: leave,
            header: { HeaderGlyph(symbol: state.isNew ? ItemSymbols.category(d.category) : .edit) },
            topActions: {
                TopBarTextAction(ItemsStrings.saveItem, enabled: !state.loading, busy: state.busy, action: actions.onSave)
                    .accessibilityIdentifier("item_edit_save")
            }
        ) {
            // What is typed and shown here (values, notes, a one-time code seed) stays out of screenshots and recordings
            // unless "Allow screenshots" is on, as on the item's screen (IOS-PLAN §6.4, ID10, I3.1).
            SecureContainer(isSecure: !(allowance?.allowed ?? false)) {
                ItemEditForm(state: state, actions: actions)
            }
        }
        .accessibilityIdentifier("item_edit")
        .modifier(ItemEditDialogs(state: state, actions: actions))
    }
}

/// The form's sections: notices, the name, the category, the protection, the tags, the fields, the notes, the problems
/// and the size.
struct ItemEditForm: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemEditState
    let actions: ItemEditActions

    var body: some View {
        let d = state.draft
        let show = state.showErrors
        let problems = state.check.problems
        // A secret or critical item's values and notes (or one becoming so) are typed on a keyboard that does not learn.
        let secret = d.sensitivity != .data || state.protection != .data
        VStack(alignment: .leading, spacing: Spacing.m) {
            notices
            NameInput(state: state, actions: actions)
            CategoryPicker(category: d.category, customs: state.pickerCustoms, actions: actions)
            SensitivitySection(state: state, actions: actions)
            TagsSection(state: state, actions: actions)
            Text(ItemsStrings.fields).vettIDFont(.titleSmall)
            if d.fields.isEmpty {
                Text(ItemsStrings.noFieldsYet).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("item_edit_no_fields")
            }
            ForEach(Array(d.fields.enumerated()), id: \.offset) { i, f in
                FieldEditor(
                    index: i, count: d.fields.count, field: f, problems: show ? state.check.fieldProblems[i] ?? [] : [],
                    focus: state.focusField == i, secret: secret, actions: actions
                )
            }
            AddFieldButton(enabled: d.fields.count < ItemChecks.maxFields, onAdd: actions.onAskAddField)
            NotesInput(state: state, secret: secret, actions: actions)
            let other = problems.subtracting([.nameEmpty, .nameTooLong, .notesTooLong])
            if show && !other.isEmpty {
                let lines = other.map { ItemsText.problem($0) }.sorted().joined(separator: "\n")
                NoticeCard(.warning, title: ItemsStrings.problemsTitle, message: lines, announce: .assertive)
                    .accessibilityIdentifier("item_edit_problems")
            }
            if let size = ItemsText.sizeNote(state.check) {
                let over = (state.check.roomLeft ?? 0) < 0 && state.check.exact
                Text(size).vettIDFont(.bodySmall).foregroundStyle(over ? colors.error : colors.onSurfaceVariant)
                    .accessibilityIdentifier("item_edit_size")
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if let e = state.error {
            let text = ItemsText.failure(
                e, creating: state.isNew, critical: state.draft.sensitivity == .critical, profile: state.inProfile, limit: state.limit,
                shownCode: state.errorCode
            )
            NoticeCard(.warning, title: ItemsStrings.errorSave, message: text, announce: .assertive) {
                Button(ItemsStrings.ok) { actions.onDismissError() }
            }
            .accessibilityIdentifier("item_edit_error")
        }
        if state.savedButProtection {
            NoticeCard(.info, title: ItemsStrings.savedProtectionNotTitle, message: ItemsStrings.savedProtectionNotBody)
                .accessibilityIdentifier("item_edit_saved_protection_not")
        }
    }
}
#endif
