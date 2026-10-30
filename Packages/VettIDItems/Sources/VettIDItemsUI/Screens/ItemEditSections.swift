#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// An outlined text input with a caption above and a supporting line below (an error in the error colour).
struct OutlinedInput<Input: View>: View {
    @Environment(\.vettIDColors) private var colors
    let caption: String
    let supporting: String?
    var isError = false
    /// Where VoiceOver's cursor goes to the error when a save is refused.
    var problem: ProblemFocus?
    @ViewBuilder let input: () -> Input

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(caption).vettIDFont(.labelMedium).foregroundStyle(isError ? colors.error : colors.onSurfaceVariant)
            input()
            if let supporting {
                Text(supporting).vettIDFont(.bodySmall).foregroundStyle(isError ? colors.error : colors.onSurfaceVariant)
                    .problemFocus(isError ? problem : nil)
            }
        }
    }
}

/// A problem's place and the form's VoiceOver focus, given to the view that shows the problem's text.
struct ProblemFocus {
    let binding: AccessibilityFocusState<ProblemPlace?>.Binding
    let place: ProblemPlace
}

extension View {
    /// VoiceOver's cursor lands here, on the problem's own text, when [problem] is the first one of a refused save.
    @ViewBuilder func problemFocus(_ problem: ProblemFocus?) -> some View {
        if let problem { accessibilityFocused(problem.binding, equals: problem.place) } else { self }
    }
}

/// A plain text field in the outlined style.
struct PlainField: View {
    @Environment(\.vettIDColors) private var colors
    let placeholder: String?
    let text: String
    var isError = false
    /// A field that grows over these lines (the ask form's reason); nil: one line.
    var lines: ClosedRange<Int>?
    let onChange: @MainActor (String) -> Void

    /// No AutoFill and no "Save Password?" (IOS-PLAN §6.5): the empty content type the secret fields use, so that iOS
    /// guesses none (a field next to a password is taken for a username otherwise).
    static let noAutofill = UITextContentType(rawValue: "")

    var body: some View {
        TextField(placeholder ?? "", text: Binding(get: { text }, set: { onChange($0) }), axis: lines == nil ? .horizontal : .vertical)
            .lineLimit(lines ?? 1...1)
            .textContentType(Self.noAutofill)
            .vettIDFont(.bodyLarge)
            .frame(minHeight: Spacing.touchTarget)
            .padding(.horizontal, Spacing.l)
            .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(isError ? colors.error : colors.outline))
    }
}

/// The name. A template's name is the placeholder, never pre-typed: left empty, it is used.
struct NameInput: View {
    let state: ItemEditState
    let actions: ItemEditActions
    var problem: ProblemFocus?

    var body: some View {
        let nameProblem = [DraftProblem.nameEmpty, .nameTooLong].first { state.check.problems.contains($0) }
        let shown = state.showErrors ? nameProblem : nil
        let hint = state.nameHint
        let supporting = shown.map { ItemsText.problem($0) }
            ?? (hint != nil && state.draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? hint.map(ItemsStrings.nameDefault) : nil)
        OutlinedInput(caption: ItemsStrings.name, supporting: supporting, isError: shown != nil, problem: problem) {
            PlainField(placeholder: hint, text: state.draft.name, isError: shown != nil) {
                actions.onName($0.replacingOccurrences(of: "\n", with: ""))
            }
            .textInputAutocapitalization(.sentences)
            .accessibilityLabel(ItemsStrings.name)
            .accessibilityIdentifier("item_edit_name")
        }
    }
}

/// The recommended categories, then the member's own (§10.7 allows any), then "New category…".
struct CategoryPicker: View {
    let category: String
    let customs: [String]
    let actions: ItemEditActions

    var body: some View {
        OutlinedInput(caption: ItemsStrings.category, supporting: nil) {
            Menu {
                ForEach(ItemTemplates.categories) { c in
                    Button { actions.onCategory(c.id) } label: { Label(c.label, systemImage: ItemSymbols.category(c.id).rawValue) }
                }
                if !customs.isEmpty {
                    Divider()
                    ForEach(customs, id: \.self) { c in
                        Button { actions.onCategory(c) } label: {
                            Label(ItemsText.category(c), systemImage: ItemSymbols.category(c).rawValue)
                        }
                    }
                }
                Divider()
                Button { actions.onAskNewCategory() } label: { Label(ItemsStrings.categoryNew, systemImage: VettIDSymbol.add.rawValue) }
                    .accessibilityIdentifier("item_edit_category_new")
            } label: {
                MenuField(text: ItemsText.category(category))
            }
            .accessibilityLabel(ItemsStrings.cdChooseCategory)
            .accessibilityValue(ItemsText.category(category))
            .accessibilityIdentifier("item_edit_category")
        }
    }
}

/// A read-only field that opens a menu: its value and a chevron.
struct MenuField: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View {
        HStack {
            Text(text).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
            Spacer()
            Image(systemName: "chevron.down").foregroundStyle(colors.onSurfaceVariant).accessibilityHidden(true)
        }
        .frame(minHeight: Spacing.touchTarget)
        .padding(.horizontal, Spacing.l)
        .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(colors.outline))
        .contentShape(Rectangle())
    }
}

/// The protection, for a new item and an existing one alike. An existing item's change is applied after its content when
/// saved (`item.sensitivity`, §10.7). `@profile` items stay standard (§10.8): the other choices are off, with the reason.
struct SensitivitySection: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemEditState
    let actions: ItemEditActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ItemsStrings.protection).vettIDFont(.titleSmall)
            ForEach(Sensitivity.allCases, id: \.self) { s in
                SensitivityChoice(sensitivity: s, selected: s == state.protection, enabled: !state.inProfile || s == .data) {
                    actions.onSensitivity(s)
                }
            }
            if let note = state.protectionNote {
                Text(note).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("item_edit_protection_note")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item_edit_sensitivity")
    }
}

/// The tags: what they do, the item's own (removable), the input to add one, what saving does to sharing (the vault's dry
/// run), and the built-in "Shared profile" choice.
struct TagsSection: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemEditState
    let actions: ItemEditActions

    var body: some View {
        let typed = state.tagInput
        let invalid = !typed.trimmingCharacters(in: .whitespaces).isEmpty && ItemChecks.normalizeTag(typed) == nil
        // The reserved @profile is the built-in choice below, not a chip.
        let own = state.draft.tags.filter { $0 != ItemChecks.profileTag }
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ItemsStrings.tags).vettIDFont(.titleSmall)
            Text(ItemsStrings.tagsNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                .accessibilityIdentifier("item_edit_tags_note")
            if !own.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(own, id: \.self) { t in
                            RemovableTagChip(ItemsText.tagLabel(t), tag: t, removeLabel: ItemsStrings.cdRemoveTag(ItemsText.tagLabel(t))) {
                                actions.onRemoveTag(t)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("item_edit_tags")
            }
            let supporting = invalid ? ItemsStrings.problemTag : ItemsStrings.tagHint
            OutlinedInput(caption: ItemsStrings.tagAdd, supporting: supporting, isError: invalid) {
                HStack(spacing: Spacing.s) {
                    PlainField(placeholder: nil, text: typed, isError: invalid, onChange: actions.onTagInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { actions.onAddTag() }
                        .accessibilityLabel(ItemsStrings.tagAdd)
                        .accessibilityIdentifier("item_edit_tag_input")
                    IconButton(.add, label: ItemsStrings.tagAdd) { actions.onAddTag() }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || invalid)
                }
            }
            if !state.shareImpact.isEmpty {
                NoticeCard(.info, title: ItemsStrings.impactTitle, message: state.shareImpact.map(ItemsText.impact).joined(separator: "\n"))
                    .accessibilityIdentifier("item_edit_share_impact")
            }
            ProfileChoice(state: state, onInProfile: actions.onInProfile)
        }
    }
}

/// "Shared profile" (`@profile`, §10.8) as a built-in tag choice: only a standard item can carry it, so for a secret or
/// critical one it is off, with the reason (an item that carries it anyway can still take it off).
struct ProfileChoice: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemEditState
    let onInProfile: @MainActor (Bool) -> Void

    var body: some View {
        let on = state.inProfile
        let available = on || state.draft.sensitivity == .data
        Button { onInProfile(!on) } label: {
            HStack(spacing: Spacing.m) {
                (on ? VettIDSymbol.checkBox : VettIDSymbol.checkBoxOutline).image
                    .foregroundStyle(on ? colors.primary : colors.onSurfaceVariant)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(ItemsStrings.tagProfile).vettIDFont(.bodyLarge)
                        .foregroundStyle(available ? colors.onSurface : colors.onSurfaceVariant)
                    Text(available ? ItemsStrings.profileChoiceNote : ItemsStrings.problemProfile)
                        .vettIDFont(.bodySmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier("item_edit_profile_choice")
    }
}

/// "Add a field", or why no more can be added (§10.7: at most 64 fields).
struct AddFieldButton: View {
    @Environment(\.vettIDColors) private var colors
    let enabled: Bool
    let onAdd: @MainActor () -> Void

    var body: some View {
        Button(action: onAdd) {
            Label(enabled ? ItemsStrings.addField : ItemsStrings.problemFields, systemImage: VettIDSymbol.add.rawValue)
                .vettIDFont(.labelLarge)
                .foregroundStyle(enabled ? colors.primary : colors.onSurfaceVariant)
                .frame(minHeight: Spacing.touchTarget)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("item_edit_add_field")
    }
}

/// The notes: kept notes (§10.7) show as kept, typing replaces them, and "Remove notes" drops them. A secret or critical
/// item's notes are typed on a keyboard that does not learn, with no AutoFill.
struct NotesInput: View {
    @Environment(\.vettIDColors) private var colors
    let state: ItemEditState
    let secret: Bool
    let actions: ItemEditActions
    var problem: ProblemFocus?

    var body: some View {
        let d = state.draft
        let tooLong = state.showErrors && state.check.problems.contains(.notesTooLong)
        let supporting = tooLong ? ItemsText.problem(.notesTooLong) : (d.keepNotes ? ItemsStrings.notesKept : nil)
        let binding = Binding(get: { d.notes }, set: { actions.onNotes($0) })
        let placeholder = d.keepNotes ? ItemsStrings.notesKeptPlaceholder : nil
        VStack(alignment: .leading, spacing: Spacing.xs) {
            OutlinedInput(caption: ItemsStrings.notes, supporting: supporting, isError: tooLong, problem: problem) {
                if secret {
                    SecretTextEditor(ItemsStrings.notes, text: binding, placeholder: placeholder, isError: tooLong)
                } else {
                    TextField(placeholder ?? "", text: binding, axis: .vertical)
                        .textContentType(PlainField.noAutofill)
                        .lineLimit(3...)
                        .vettIDFont(.bodyLarge)
                        .padding(Spacing.l)
                        .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(tooLong ? colors.error : colors.outline))
                        .accessibilityLabel(ItemsStrings.notes)
                }
            }
            .accessibilityIdentifier("item_edit_notes")
            if d.keepNotes {
                Button(ItemsStrings.notesRemove) { actions.onRemoveNotes() }
                    .foregroundStyle(colors.primary)
                    .frame(minHeight: Spacing.touchTarget)
                    .accessibilityIdentifier("item_edit_notes_remove")
            }
        }
    }
}
#endif
