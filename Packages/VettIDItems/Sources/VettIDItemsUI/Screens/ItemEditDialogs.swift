#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// The editor's dialogs: a field's name and type (add, rename, change type), a new category (as a sheet), the warning
/// for leaving `critical` and "Discard changes?". Each closes when the app is covered. Mirrors vettid-android
/// `EditDialogs`.
struct ItemEditDialogs: ViewModifier {
    @Environment(\.vettIDCovered) private var covered
    @Environment(\.vettIDColors) private var colors
    let state: ItemEditState
    let actions: ItemEditActions

    private var dialogShown: Binding<Bool> {
        Binding(get: { state.dialog != nil }, set: { if !$0 { actions.onDismissDialog() } })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: uncovered(dialogShown, covered: covered)) {
                Group {
                    switch state.dialog {
                    case .addField(let label, let kind):
                        FieldDialog(
                            title: ItemsStrings.addField, confirm: ItemsStrings.fieldAddConfirm, label: label, kind: kind, actions: actions
                        )
                    case .renameField(_, let label):
                        FieldDialog(
                            title: ItemsStrings.fieldRenameTitle, confirm: ItemsStrings.fieldRenameConfirm, label: label, kind: nil,
                            actions: actions
                        )
                    case .fieldKind(let i, let kind):
                        let label = state.draft.fields.indices.contains(i) ? state.draft.fields[i].label : ""
                        KindDialog(label: label, kind: kind, actions: actions)
                    case .newCategory(let name):
                        NewCategoryDialog(name: name, actions: actions)
                    case nil:
                        EmptyView()
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(colors.surfaceContainerLow.color)
            }
            .confirmDialog(
                isPresented: Binding(get: { state.confirmLeaveCritical }, set: { if !$0 { actions.onDismissLeaveCritical() } }),
                title: ItemsStrings.leaveCriticalTitle, message: ItemsStrings.leaveCriticalBody,
                confirmLabel: ItemsStrings.leaveCriticalConfirm, destructive: true, onConfirm: actions.onConfirmLeaveCritical
            )
            .confirmDialog(
                isPresented: Binding(get: { state.confirmDiscard }, set: { if !$0 { actions.onKeepEditing() } }),
                title: ItemsStrings.discardTitle, message: ItemsStrings.discardBody, confirmLabel: ItemsStrings.discard, destructive: true,
                dismissLabel: ItemsStrings.keepEditing, onConfirm: actions.onDiscard
            )
    }
}

/// A dialog sheet's frame: a title, the content, then Cancel and the confirm button.
struct DialogSheet<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let title: String
    let confirm: String
    let enabled: Bool
    let onCancel: @MainActor () -> Void
    let onConfirm: @MainActor () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(title).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
                content()
                HStack(spacing: Spacing.l) {
                    Spacer()
                    Button(ItemsStrings.cancel) { onCancel() }.foregroundStyle(colors.primary).frame(minHeight: Spacing.touchTarget)
                    Button(confirm) { onConfirm() }
                        .foregroundStyle(enabled ? colors.primary : colors.onSurfaceVariant)
                        .frame(minHeight: Spacing.touchTarget)
                        .disabled(!enabled)
                        .accessibilityIdentifier("item_field_dialog_confirm")
                }
            }
            .padding(Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// What the field is called (the label checks of §10.7) and, when adding, its type.
struct FieldDialog: View {
    let title: String
    let confirm: String
    let label: String
    let kind: String?
    let actions: ItemEditActions
    @FocusState private var focused: Bool

    var body: some View {
        let problem = ItemChecks.labelProblems(label.trimmingCharacters(in: .whitespaces)).sorted { "\($0)" < "\($1)" }.first
        // An empty label only turns the button off; one too long or with control characters says why.
        let shown = label.isEmpty ? nil : problem
        DialogSheet(
            title: title, confirm: confirm, enabled: problem == nil, onCancel: actions.onDismissDialog, onConfirm: actions.onConfirmDialog
        ) {
            OutlinedInput(caption: ItemsStrings.fieldNamePrompt, supporting: shown.map { ItemsText.problem($0) }, isError: shown != nil) {
                PlainField(placeholder: nil, text: label, isError: shown != nil) {
                    actions.onDialogText($0.replacingOccurrences(of: "\n", with: ""))
                }
                    .textInputAutocapitalization(.sentences)
                    .focused($focused)
                    .onSubmit { if problem == nil { actions.onConfirmDialog() } }
                    .accessibilityLabel(ItemsStrings.fieldNamePrompt)
                    .accessibilityIdentifier("item_field_dialog_label")
            }
            if let kind { KindPicker(kind: kind, onKind: actions.onDialogKind) }
        }
        .onAppear { focused = true }
        .accessibilityIdentifier("item_field_dialog")
    }
}

/// An unsaved field's type.
struct KindDialog: View {
    let label: String
    let kind: String
    let actions: ItemEditActions

    var body: some View {
        DialogSheet(
            title: ItemsStrings.fieldTypeTitle(label), confirm: ItemsStrings.fieldTypeConfirm, enabled: true,
            onCancel: actions.onDismissDialog, onConfirm: actions.onConfirmDialog
        ) {
            KindPicker(kind: kind, onKind: actions.onDialogKind)
        }
        .accessibilityIdentifier("item_field_dialog")
    }
}

/// The type of a new field, from the kinds the app offers (never `file`, §10.7).
struct KindPicker: View {
    let kind: String
    let onKind: @MainActor (String) -> Void

    var body: some View {
        OutlinedInput(caption: ItemsStrings.fieldType, supporting: nil) {
            Menu {
                ForEach(FieldKinds.choosable, id: \.self) { k in
                    Button(ItemsText.kind(k)) { onKind(k) }.accessibilityIdentifier("item_field_kind_\(k)")
                }
            } label: {
                MenuField(text: ItemsText.kind(kind))
            }
            .accessibilityLabel(ItemsStrings.cdChooseKind)
            .accessibilityValue(ItemsText.kind(kind))
            .accessibilityIdentifier("item_field_dialog_kind")
        }
    }
}

/// A category of the member's own (§10.7: `[a-z][a-z0-9_]{0,31}`): the typed name, the identifier it gives, or why it
/// gives none. A name that gives a recommended category selects that one.
struct NewCategoryDialog: View {
    let name: String
    let actions: ItemEditActions
    @FocusState private var focused: Bool

    var body: some View {
        let derived = ItemCategories.derive(name)
        let id = derived.id
        let blank = name.trimmingCharacters(in: .whitespaces).isEmpty
        let note: String = if blank {
            ItemsStrings.categoryNewHint
        } else if let id, derived.recommended {
            ItemsStrings.categoryExisting(ItemsText.category(id))
        } else if let id {
            ItemsStrings.categorySavedAs(id)
        } else if derived.problem == .startsWithDigit {
            ItemsStrings.categoryProblemDigit
        } else {
            ItemsStrings.categoryProblemEmpty
        }
        DialogSheet(
            title: ItemsStrings.categoryNewTitle, confirm: ItemsStrings.categoryNewConfirm, enabled: id != nil,
            onCancel: actions.onDismissDialog, onConfirm: actions.onConfirmDialog
        ) {
            OutlinedInput(caption: ItemsStrings.categoryNewName, supporting: note, isError: !blank && id == nil) {
                PlainField(placeholder: nil, text: name, isError: !blank && id == nil) {
                    actions.onDialogText($0.replacingOccurrences(of: "\n", with: ""))
                }
                    .textInputAutocapitalization(.sentences)
                    .focused($focused)
                    .onSubmit { if id != nil { actions.onConfirmDialog() } }
                    .accessibilityLabel(ItemsStrings.categoryNewName)
                    .accessibilityIdentifier("item_category_dialog_name")
            }
        }
        .onAppear { focused = true }
        .accessibilityIdentifier("item_category_dialog")
    }
}
#endif
