#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// One field, value-first: a single input captioned with the field's label, with the keyboard of its kind, and under it
/// the kind as a hint (a problem replaces it). The label and kind change from the field's menu, never inline. A kept value
/// (§10.7 Kept values) is not at hand: the input stays empty until the member types a new one. Mirrors vettid-android
/// `FieldEditor`.
struct FieldEditor: View {
    @Environment(\.vettIDColors) private var colors
    let index: Int
    let count: Int
    let field: DraftField
    let problems: Set<DraftProblem>
    /// The input takes the focus (the field was just added).
    let focus: Bool
    /// A secret or critical item: no keyboard learning, no AutoFill, for every value a text keyboard would take.
    let secret: Bool
    let actions: ItemEditActions

    private var kindName: String { ItemsText.kindName(field) }

    var body: some View {
        let caption = field.label.trimmingCharacters(in: .whitespaces).isEmpty ? kindName : field.label
        let error = errorText
        let hint = field.kept ? ItemsStrings.fieldKindKept(kindName) : kindName
        HStack(alignment: .top, spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(caption).vettIDFont(.labelMedium).foregroundStyle(error == nil ? colors.onSurfaceVariant : colors.error)
                if field.kind == FieldKinds.address {
                    AddressEditor(address: field.address, secret: secret) { actions.onFieldAddress(index, $0) }
                } else {
                    ValueEditor(
                        index: index, field: field, caption: caption, isError: error != nil, focus: focus, secret: secret, actions: actions
                    )
                }
                Text(error ?? hint)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(error == nil ? colors.onSurfaceVariant : colors.error)
                    .accessibilityIdentifier(field.kept ? "item_edit_field_kept_\(index)" : "item_edit_field_hint_\(index)")
            }
            FieldMenu(index: index, count: count, field: field, caption: caption, actions: actions)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item_edit_field_\(index)")
    }

    /// A label's problem first, then the value's; a value that is not (yet) one of its kind says its rule while typing.
    private var errorText: String? {
        let labelProblem = [DraftProblem.labelEmpty, .labelTooLong].first { problems.contains($0) }
            ?? (problems.contains(.badCharacter) && !ItemChecks.labelProblems(field.label.trimmingCharacters(in: .whitespaces)).isEmpty
                ? .badCharacter : nil)
        if let labelProblem { return ItemsText.problem(labelProblem) }
        let valueProblem = problems.subtracting([.labelEmpty, .labelTooLong]).sorted { "\($0)" < "\($1)" }.first
        let live: DraftProblem? = !field.kept && FieldInput.incomplete(field.kind, field.text) ? .valueInvalid : nil
        return (valueProblem ?? live).map { ItemsText.problem($0, kind: field.kind) }
    }
}

/// A field's ⋯ menu: Rename…, Change type… (unsaved fields only, §10.7), Move up, Move down, Remove.
struct FieldMenu: View {
    let index: Int
    let count: Int
    let field: DraftField
    let caption: String
    let actions: ItemEditActions

    var body: some View {
        Menu {
            Button { actions.onAskRenameField(index) } label: { Label(ItemsStrings.fieldRename, systemImage: VettIDSymbol.edit.rawValue) }
                .accessibilityIdentifier("item_edit_field_rename")
            // A saved field keeps its kind (its id names the same field, §10.7): offered, off, with the reason.
            Button { actions.onAskFieldKind(index) } label: {
                Text(ItemsStrings.fieldChangeType)
                if field.fieldID != nil { Text(ItemsStrings.fieldTypeFixed) }
            }
            .disabled(field.fieldID != nil)
            .accessibilityIdentifier("item_edit_field_kind")
            Button { actions.onMoveField(index, -1) } label: { Label(ItemsStrings.fieldMoveUp, systemImage: VettIDSymbol.dragUp.rawValue) }
                .disabled(index == 0)
            Button { actions.onMoveField(index, 1) } label: {
                Label(ItemsStrings.fieldMoveDown, systemImage: VettIDSymbol.dragDown.rawValue)
            }
                .disabled(index >= count - 1)
            Button(role: .destructive) { actions.onRemoveField(index) } label: {
                Label(ItemsStrings.fieldRemove, systemImage: VettIDSymbol.delete.rawValue)
            }
        } label: {
            VettIDSymbol.moreHoriz.image.frame(width: Spacing.touchTarget, height: Spacing.touchTarget).contentShape(Rectangle())
        }
        .accessibilityLabel(ItemsStrings.cdFieldOptions(caption))
        .accessibilityIdentifier("item_edit_field_menu_\(index)")
        .padding(.top, Spacing.l)
    }
}

/// One value's input, with the keyboard of its kind and its format enforced while typing and on paste (§10.7,
/// ``FieldInput``): characters the kind cannot hold never get in. A password is a ``SecretField``; a one-time code seed,
/// and every value of a secret or critical item that a text keyboard would take, is typed visibly on a keyboard that does
/// not learn and offers no AutoFill (``VisibleSecretField``, ``SecretTextEditor``). Mirrors vettid-android `ValueEditor`.
struct ValueEditor: View {
    @Environment(\.vettIDColors) private var colors
    let index: Int
    let field: DraftField
    let caption: String
    let isError: Bool
    let focus: Bool
    let secret: Bool
    let actions: ItemEditActions
    @FocusState private var focused: Bool

    private var kind: String { field.kind }

    private var binding: Binding<String> {
        Binding(get: { field.text }, set: { actions.onFieldText(index, FieldInput.accept(kind, $0)) })
    }

    private var placeholder: String? {
        if field.kept { return ItemsStrings.fieldKeptPlaceholder }
        switch kind {
        case FieldKinds.url: return ItemsStrings.placeholderUrl
        case FieldKinds.otp: return ItemsStrings.placeholderOtp
        case FieldKinds.email: return ItemsStrings.placeholderEmail
        case FieldKinds.phone: return ItemsStrings.placeholderPhone
        case FieldKinds.number: return ItemsStrings.placeholderNumber
        default: return nil
        }
    }

    var body: some View {
        input
            .accessibilityIdentifier("item_edit_field_value_\(index)")
            .onAppear { takeFocus() }
            .onChange(of: focus) { _, _ in takeFocus() }
    }

    private func takeFocus() {
        guard focus else { return }
        focused = true
        actions.onFieldFocused()
    }

    @ViewBuilder private var input: some View {
        let free = kind == FieldKinds.text || kind == FieldKinds.multiline
        let guarded = kind == FieldKinds.otp || (secret && (free || kind == FieldKinds.email || kind == FieldKinds.url))
        if kind == FieldKinds.password {
            SecretField(caption, text: binding)
        } else if kind == FieldKinds.date {
            DateEditor(index: index, field: field, caption: caption, isError: isError) { actions.onFieldText(index, $0) }
        } else if guarded && kind == FieldKinds.multiline {
            SecretTextEditor(caption, text: binding, placeholder: placeholder, isError: isError)
        } else if guarded {
            VisibleSecretField(
                caption, text: binding, placeholder: placeholder ?? caption,
                capitalization: kind == FieldKinds.otp ? .allCharacters : .none, monospaced: kind == FieldKinds.otp, isError: isError
            )
        } else if kind == FieldKinds.multiline {
            TextField(placeholder ?? caption, text: binding, axis: .vertical)
                .lineLimit(3...)
                .vettIDFont(.bodyLarge)
                .padding(Spacing.l)
                .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(isError ? colors.error : colors.outline))
                .focused($focused)
                .accessibilityLabel(caption)
        } else {
            PlainField(placeholder: placeholder ?? caption, text: field.text, isError: isError) {
                actions.onFieldText(index, FieldInput.accept(kind, $0))
            }
                .keyboardType(Self.keyboard(kind))
                .textInputAutocapitalization(free ? .sentences : .never)
                .autocorrectionDisabled(!free)
                .textContentType(nil)
                .focused($focused)
                .accessibilityLabel(caption)
        }
    }

    static func keyboard(_ kind: String) -> UIKeyboardType {
        switch kind {
        case FieldKinds.number: .decimalPad
        case FieldKinds.email: .emailAddress
        case FieldKinds.phone: .phonePad
        case FieldKinds.url: .URL
        default: .default
        }
    }
}

/// A `date` (§10.7): digits on a number pad with the dashes put in (`YYYY-MM-DD`, or `YYYY-MM` for a month-and-year
/// field), a digit no date can continue with refused, and a calendar button (a month picker for month and year). What is
/// stored is always the spec's format. Mirrors vettid-android `DateEditor`.
struct DateEditor: View {
    @Environment(\.vettIDColors) private var colors
    let index: Int
    let field: DraftField
    let caption: String
    let isError: Bool
    let onValue: @MainActor (String) -> Void
    @State private var picking = false

    var body: some View {
        let month = field.monthYear
        let empty = month ? ItemsStrings.placeholderMonth : ItemsStrings.placeholderDate
        let placeholder = field.kept ? ItemsStrings.fieldKeptPlaceholder : empty
        HStack(spacing: Spacing.xs) {
            PlainField(placeholder: placeholder, text: field.text, isError: isError) { typed in
                if let v = DateInput.accept(old: field.text, typed: typed, monthOnly: month) { onValue(v) }
            }
            .keyboardType(.numberPad)
            .accessibilityLabel(caption)
            IconButton(.schedule, label: month ? ItemsStrings.cdPickMonth(caption) : ItemsStrings.cdPickDate(caption)) { picking = true }
                .accessibilityIdentifier("item_edit_field_pick_\(index)")
        }
        .sheet(isPresented: $picking) {
            Group {
                if month {
                    MonthPicker(stored: field.text) { v in
                        picking = false
                        if let v { onValue(v) }
                    }
                } else {
                    DayPicker(stored: field.text) { v in
                        picking = false
                        if let v { onValue(v) }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(colors.surfaceContainerLow.color)
        }
    }
}

/// The calendar; the day picked is stored as `YYYY-MM-DD` (§10.7).
struct DayPicker: View {
    @Environment(\.vettIDColors) private var colors
    let onDone: @MainActor (String?) -> Void
    @State private var day: Date

    init(stored: String, onDone: @escaping @MainActor (String?) -> Void) {
        self.onDone = onDone
        _day = State(initialValue: DateInput.toPicker(stored) ?? Date())
    }

    var body: some View {
        VStack(spacing: Spacing.m) {
            DatePicker("", selection: $day, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                .accessibilityIdentifier("item_date_picker")
            PickerButtons(onCancel: { onDone(nil) }, onOK: { onDone(DateInput.fromPicker(day)) })
        }
        .padding(Spacing.xl)
    }
}

/// A month and year (a card's expiry): the year with arrows, the twelve months; stored as `YYYY-MM` (§10.7).
struct MonthPicker: View {
    @Environment(\.vettIDColors) private var colors
    let onDone: @MainActor (String?) -> Void
    @State private var year: Int
    @State private var month: Int

    init(stored: String, onDone: @escaping @MainActor (String?) -> Void) {
        self.onDone = onDone
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        let initial = DateInput.yearMonth(stored) ?? (now.year ?? 2026, now.month ?? 1)
        _year = State(initialValue: initial.year)
        _month = State(initialValue: initial.month)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ItemsStrings.monthPickerTitle).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
            HStack {
                IconButton(.back, label: ItemsStrings.cdPreviousYear) { year = max(1, year - 1) }
                Text(String(year)).vettIDFont(.titleMedium).frame(maxWidth: .infinity).accessibilityIdentifier("item_month_year")
                IconButton(.chevronForward, label: ItemsStrings.cdNextYear) { year = min(9_999, year + 1) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Spacing.s) {
                ForEach(1...12, id: \.self) { m in
                    VettIDFilterChip(Calendar.current.shortMonthSymbols[m - 1], selected: m == month) { month = m }
                        .accessibilityIdentifier("item_month_\(m)")
                }
            }
            PickerButtons(onCancel: { onDone(nil) }, onOK: { onDone(DateInput.month(year: year, month: month)) })
        }
        .padding(Spacing.xl)
        .accessibilityIdentifier("item_month_picker")
    }
}

/// A picker's Cancel and OK.
struct PickerButtons: View {
    @Environment(\.vettIDColors) private var colors
    let onCancel: @MainActor () -> Void
    let onOK: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Spacing.l) {
            Spacer()
            Button(ItemsStrings.cancel) { onCancel() }.foregroundStyle(colors.primary).frame(minHeight: Spacing.touchTarget)
            Button(ItemsStrings.ok) { onOK() }.foregroundStyle(colors.primary).frame(minHeight: Spacing.touchTarget)
                .accessibilityIdentifier("item_date_pick_ok")
        }
    }
}

/// An address (§10.7): street, second line, postal code, city, region, and the country as two upper-case letters.
struct AddressEditor: View {
    let address: AddressValue
    let secret: Bool
    let onValue: @MainActor (AddressValue) -> Void

    var body: some View {
        VStack(spacing: Spacing.xs) {
            part(ItemsStrings.addressStreet, address.street) { a, v in a.street = v }
            part(ItemsStrings.addressStreet2, address.street2) { a, v in a.street2 = v }
            part(ItemsStrings.addressPostalCode, address.postalCode) { a, v in a.postalCode = v }
            part(ItemsStrings.addressCity, address.city) { a, v in a.city = v }
            part(ItemsStrings.addressRegion, address.region) { a, v in a.region = v }
            // ISO 3166-1 alpha-2, upper case (§10.7).
            part(ItemsStrings.addressCountry, address.country, caps: true) { a, v in a.country = FieldInput.country(v) }
        }
    }

    @ViewBuilder
    private func part(
        _ label: String, _ value: String, caps: Bool = false, _ set: @escaping (inout AddressValue, String) -> Void
    ) -> some View {
        let binding = Binding(get: { value }, set: { v in
            var a = address
            set(&a, v.replacingOccurrences(of: "\n", with: ""))
            onValue(a)
        })
        if secret {
            VisibleSecretField(label, text: binding, capitalization: caps ? .allCharacters : .words)
        } else {
            PlainField(placeholder: label, text: value) { binding.wrappedValue = $0 }
                .textInputAutocapitalization(caps ? .characters : .words)
                .accessibilityLabel(label)
        }
    }
}
#endif
