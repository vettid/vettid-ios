#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// The tags screen's sheet: the colour picker, or the form with the rename and delete previews over it (the form under a
/// preview shows the tag it is about, ``TagFormValues``).
struct TagSheet: View {
    @Environment(\.vettIDColors) private var colors
    let state: TagsState
    let actions: TagsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = errorText {
                Text(error)
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.error)
                    .padding([.horizontal, .top], Spacing.xl)
                    .accessibilityIdentifier("tag_sheet_error")
            }
            if case .colour(let t) = state.dialog {
                TagColourPicker(tag: t, busy: state.busy, actions: actions)
            } else {
                TagForm(values: TagFormValues(state.dialog, registry: state.registry), busy: state.busy, actions: actions)
                    .confirmDialog(
                        isPresented: preview(rename: true), title: renameTitle, message: changeText,
                        confirmLabel: ItemsStrings.tagsRename, onConfirm: actions.onConfirmRename
                    )
                    .confirmDialog(
                        isPresented: preview(rename: false), title: deleteTitle, message: changeText,
                        confirmLabel: ItemsStrings.delete, destructive: true, onConfirm: actions.onConfirmDelete
                    )
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(colors.surfaceContainerLow.color)
        .environment(\.vettIDColors, colors)
        // An action's failure is said inside the sheet while it is up (VoiceOver announces it), as well as under it.
        .onChange(of: errorText) { _, text in if let text { AccessibilityNotification.Announcement(text).post() } }
    }

    private var errorText: String? {
        state.error.map { ItemsText.failure($0, limit: state.limit, shownCode: state.errorCode) }
    }

    private func preview(rename: Bool) -> Binding<Bool> {
        Binding(
            get: {
                switch state.dialog {
                case .confirmRename: rename
                case .confirmDelete: !rename
                default: false
                }
            },
            set: { if !$0 { actions.onDismiss() } }
        )
    }

    private var renameTitle: String {
        guard case .confirmRename(let tag, let into, _) = state.dialog else { return "" }
        return ItemsStrings.tagsRenameTitle(tag, into)
    }

    private var deleteTitle: String {
        guard case .confirmDelete(let tag, _) = state.dialog else { return "" }
        return ItemsStrings.tagsDeleteTitle(tag)
    }

    private var changeText: String {
        switch state.dialog {
        case .confirmRename(_, _, let c): ItemsText.change(c, renaming: true)
        case .confirmDelete(_, let c): ItemsText.change(c, renaming: false)
        default: ""
        }
    }
}

/// What the form shows: its title, the name and description typed, and the tag edited (nil for a new one). Under a
/// preview (which replaces the form's dialog in the state) it shows the tag the preview is about, as the registry has it,
/// with the new name of a rename: never a blank "New tag" form.
struct TagFormValues: Equatable {
    var title = ItemsStrings.tagsNew
    var name = ""
    var description = ""
    var tag: TagView?

    init() {}

    init(_ d: TagDialog?, registry: TagRegistry?) {
        let entry = { (tag: String) in registry?.tags.first { $0.tag == tag } ?? TagView(tag: tag) }
        switch d {
        case .create(let n, let desc):
            self.init()
            name = n
            description = desc
        case .edit(let t, let n, let desc):
            self.init(tag: t, name: n, description: desc)
        case .confirmRename(let tag, let into, _):
            let t = entry(tag)
            self.init(tag: t, name: into, description: t.description ?? "")
        case .confirmDelete(let tag, _):
            let t = entry(tag)
            self.init(tag: t, name: tag, description: t.description ?? "")
        default:
            self.init()
        }
    }

    private init(tag: TagView, name: String, description: String) {
        title = ItemsStrings.tagsEdit
        self.name = name
        self.description = description
        self.tag = tag
    }
}

/// A tag's form: its name (normalised as the vault does, `@` tags refused) and description, and for an existing tag the
/// rules using it, its colour and its deletion. Mirrors vettid-android `TagForm`.
struct TagForm: View {
    @Environment(\.vettIDColors) private var colors
    let values: TagFormValues
    let busy: Bool
    let actions: TagsActions

    private var invalid: Bool {
        !values.name.trimmingCharacters(in: .whitespaces).isEmpty && ItemChecks.normalizeTag(values.name, reserved: false) == nil
    }

    private var canSave: Bool { !busy && !values.name.trimmingCharacters(in: .whitespaces).isEmpty && !invalid }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(values.title).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
                field(ItemsStrings.tagsName, text: values.name, error: invalid, onChange: actions.onName)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("tag_form_name")
                Text(invalid ? ItemsStrings.problemTag : ItemsStrings.tagHint)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(invalid ? colors.error : colors.onSurfaceVariant)
                field(ItemsStrings.tagsDescription, text: values.description, error: false, onChange: actions.onDescription)
                if let t = values.tag {
                    if !t.rules.isEmpty {
                        Text(ItemsStrings.tagsUsedByRules(t.rules.count)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                    }
                    Button { actions.onColour(t) } label: {
                        HStack(spacing: Spacing.s) {
                            TagDot(t.tag, stored: t.color)
                            Text(ItemsStrings.tagsEditColour).vettIDFont(.labelLarge).foregroundStyle(colors.primary)
                        }
                        .frame(minHeight: Spacing.touchTarget)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityIdentifier("tag_form_colour")
                    Button { actions.onDelete() } label: {
                        Text(ItemsStrings.tagsDelete)
                            .vettIDFont(.labelLarge)
                            .foregroundStyle(colors.error)
                            .frame(minHeight: Spacing.touchTarget)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityIdentifier("tag_form_delete")
                }
                HStack(spacing: Spacing.l) {
                    Spacer()
                    textButton(ItemsStrings.cancel, id: "tag_form_cancel", enabled: true, action: actions.onDismiss)
                    textButton(ItemsStrings.save, id: "tag_form_save", enabled: canSave, action: actions.onSave)
                }
            }
            .padding(Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func field(_ label: String, text: String, error: Bool, onChange: @escaping @MainActor (String) -> Void) -> some View {
        TextField(label, text: Binding(get: { text }, set: { onChange($0) }))
            .autocorrectionDisabled()
            .vettIDFont(.bodyLarge)
            .frame(minHeight: Spacing.touchTarget)
            .padding(.horizontal, Spacing.l)
            .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(error ? colors.error : colors.outline))
            .accessibilityLabel(label)
    }

    private func textButton(_ label: String, id: String, enabled: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .vettIDFont(.labelLarge, weight: .semibold)
                .foregroundStyle(enabled ? colors.primary : colors.onSurfaceVariant)
                .frame(minHeight: Spacing.touchTarget)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }
}

/// The ten palette colours in two rows, the one the tag shows checked; a tap stores the colour. Mirrors vettid-android
/// `TagColourDialog`.
struct TagColourPicker: View {
    @Environment(\.vettIDColors) private var colors
    let tag: TagView
    let busy: Bool
    let actions: TagsActions

    static let perRow = 5

    var body: some View {
        let current = TagColors.shownSlot(tag.tag, stored: tag.color)
        let palette = colors.isDark ? TagColors.dark : TagColors.light
        let names = ItemsText.colourNames
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(ItemsStrings.tagsColourTitle(ItemsText.tagLabel(tag.tag))).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
            ForEach(Array(stride(from: 0, to: palette.count, by: Self.perRow)), id: \.self) { start in
                HStack(spacing: Spacing.s) {
                    ForEach(start..<min(start + Self.perRow, palette.count), id: \.self) { i in
                        swatch(palette[i], i, names[i], selected: i == current)
                    }
                }
            }
            HStack {
                Spacer()
                Button { actions.onDismiss() } label: {
                    Text(ItemsStrings.cancel)
                        .vettIDFont(.labelLarge, weight: .semibold)
                        .foregroundStyle(colors.primary)
                        .frame(minHeight: Spacing.touchTarget)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.xl)
        .accessibilityIdentifier("tag_colour")
    }

    private func swatch(_ c: TagColor, _ slot: Int, _ name: String, selected: Bool) -> some View {
        Button { actions.onPickColour(TagColors.stored[slot], selected) } label: {
            ZStack {
                Circle().fill(c.container.color)
                if selected {
                    Circle().stroke(colors.primary.color, lineWidth: 3)
                    VettIDSymbol.check.image.foregroundStyle(c.onContainer.color)
                }
            }
            .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(selected ? ItemsStrings.tagsCdColourSelected(name) : name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("tag_colour_\(TagColors.names[slot])")
    }
}
#endif
