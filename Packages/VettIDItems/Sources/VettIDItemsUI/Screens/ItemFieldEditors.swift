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
    /// Where VoiceOver's cursor goes to the error when a save is refused.
    var problem: ProblemFocus?

    private var kindName: String { ItemsText.kindName(field) }

    var body: some View {
        let caption = field.label.trimmingCharacters(in: .whitespaces).isEmpty ? kindName : field.label
        let error = errorText
        let hint = field.kept ? ItemsStrings.fieldKindKept(kindName) : kindName
        HStack(alignment: .top, spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(caption).vettIDFont(.labelMedium).foregroundStyle(error == nil ? colors.onSurfaceVariant : colors.error)
                if field.kind == FieldKinds.address {
                    AddressEditor(address: field.address, secret: secret, focus: focus) { actions.onFieldAddress(index, $0) }
                } else {
                    ValueEditor(
                        index: index, field: field, caption: caption, isError: error != nil, focus: focus, secret: secret, actions: actions
                    )
                }
                Text(error ?? hint)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(error == nil ? colors.onSurfaceVariant : colors.error)
                    .problemFocus(error == nil ? nil : problem)
                    .accessibilityIdentifier(field.kept ? "item_edit_field_kept_\(index)" : "item_edit_field_hint_\(index)")
            }
            FieldMenu(index: index, count: count, field: field, caption: caption, actions: actions)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item_edit_field_\(index)")
        // The input took the focus asked for (each input takes it when it appears or when asked): asked once.
        .onAppear { focusTaken() }
        .onChange(of: focus) { _, _ in focusTaken() }
    }

    private func focusTaken() {
        guard focus else { return }
        Task { @MainActor in
            await Task.yield()
            actions.onFieldFocused()
        }
    }

    private var errorText: String? { ItemsText.fieldError(field, problems: problems) }
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
/// ``FieldInput``): characters the kind cannot hold never get in. A password is a ``SecretField``. A one-time code seed,
/// and every value of a secret or critical item, is typed visibly on a keyboard that does not learn and offers no AutoFill
/// (``VisibleSecretField`` with the digit pad of a number, a phone number or a date; ``SecretTextEditor``); a standard
/// item's other values on the system's keyboards, with no AutoFill either (``PlainField``). Each takes the focus when asked
/// ([focus]). Mirrors vettid-android `ValueEditor`.
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
            input
                .accessibilityIdentifier("item_edit_field_value_\(index)")
                .onAppear { if focus { focused = true } }
                .onChange(of: focus) { _, now in if now { focused = true } }
            if let note = phoneNote {
                Text(note).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("item_edit_field_phone_note_\(index)")
            }
        }
    }

    /// A phone number's notes (VAULT-MESSAGING §10.7 "Phone values"): while an extension marker is typed, that extensions are
    /// not saved; else "Check this number" for what is not a possible number (never a block).
    private var phoneNote: String? {
        guard kind == FieldKinds.phone, !field.kept else { return nil }
        if PhoneInput.hasExtension(field.text) { return ItemsStrings.phoneExtensionNote }
        return PhoneInput.doubtful(field.text) ? ItemsStrings.phoneCheck : nil
    }

    @ViewBuilder private var input: some View {
        let guarded = secret || kind == FieldKinds.otp
        if kind == FieldKinds.password {
            SecretField(caption, text: binding, focus: focus)
        } else if kind == FieldKinds.date {
            DateEditor(index: index, field: field, caption: caption, isError: isError, secret: guarded, focus: focus) {
                actions.onFieldText(index, $0)
            }
        } else if guarded && kind == FieldKinds.multiline {
            SecretTextEditor(caption, text: binding, placeholder: placeholder, isError: isError, focus: focus)
        } else if guarded {
            VisibleSecretField(
                caption, text: binding, placeholder: placeholder ?? caption,
                capitalization: kind == FieldKinds.otp ? .allCharacters : .none, monospaced: kind == FieldKinds.otp,
                keyboard: Self.secretKeyboard(kind), isError: isError, focus: focus, accept: Self.accept(kind)
            )
        } else if kind == FieldKinds.multiline {
            TextField(placeholder ?? caption, text: binding, axis: .vertical)
                .lineLimit(3...)
                .vettIDFont(.bodyLarge)
                .padding(Spacing.l)
                .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(isError ? colors.error : colors.outline))
                .textContentType(PlainField.noAutofill)
                .focused($focused)
                .accessibilityLabel(caption)
        } else {
            let free = kind == FieldKinds.text
            // A phone number is drawn in the as-you-type format over its digits (display only: the text kept is the digits).
            PlainField(
                placeholder: placeholder ?? caption, text: kind == FieldKinds.phone ? PhoneInput.mask(field.text) : field.text,
                isError: isError
            ) {
                // A deletion that removes only drawn separators takes the digit before them too.
                let typed = kind == FieldKinds.phone ? PhoneInput.afterDeletion(shown: PhoneInput.mask(field.text), typed: $0) : $0
                actions.onFieldText(index, FieldInput.accept(kind, typed))
            }
            .keyboardType(Self.keyboard(kind))
            .textInputAutocapitalization(free ? .sentences : .never)
            .autocorrectionDisabled(!free)
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

    /// What a value's input keeps of an edit (§10.7, ``FieldInput``).
    static func accept(_ kind: String) -> SecretTextInput.Accept { { _, typed in FieldInput.accept(kind, typed) } }

    /// What a date's input keeps of an edit (``DateInput``): the date so far, or the text before when no date can begin so.
    static func acceptDate(monthOnly: Bool) -> SecretTextInput.Accept {
        { old, typed in DateInput.accept(old: old, typed: typed, monthOnly: monthOnly) ?? old }
    }

    /// A secret value's keyboard: the digit pads (no suggestions to begin with), else ASCII-capable.
    static func secretKeyboard(_ kind: String) -> UIKeyboardType {
        switch kind {
        case FieldKinds.number: .decimalPad
        case FieldKinds.phone: .phonePad
        case FieldKinds.date: .numberPad
        default: .asciiCapable
        }
    }
}

/// A `date` (§10.7): digits on a number pad with the dashes put in (`YYYY-MM-DD`, or `YYYY-MM` for a month-and-year
/// field), a digit no date can continue with refused, and a calendar button (a month picker for month and year). What is
/// stored is always the spec's format. A secret item's date is a ``VisibleSecretField``. Mirrors vettid-android
/// `DateEditor`.
struct DateEditor: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDCovered) private var covered
    let index: Int
    let field: DraftField
    let caption: String
    let isError: Bool
    let secret: Bool
    let focus: Bool
    let onValue: @MainActor (String) -> Void
    @State private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        let month = field.monthYear
        let empty = month ? ItemsStrings.placeholderMonth : ItemsStrings.placeholderDate
        let placeholder = field.kept ? ItemsStrings.fieldKeptPlaceholder : empty
        let typed = Binding(get: { field.text }, set: { t in
            if let v = DateInput.accept(old: field.text, typed: t, monthOnly: month) { onValue(v) }
        })
        HStack(spacing: Spacing.xs) {
            if secret {
                VisibleSecretField(
                    caption, text: typed, placeholder: placeholder, keyboard: .numberPad, isError: isError, focus: focus,
                    accept: ValueEditor.acceptDate(monthOnly: month)
                )
            } else {
                PlainField(placeholder: placeholder, text: field.text, isError: isError) { typed.wrappedValue = $0 }
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .accessibilityLabel(caption)
                    .onAppear { if focus { focused = true } }
                    .onChange(of: focus) { _, now in if now { focused = true } }
            }
            IconButton(.schedule, label: month ? ItemsStrings.cdPickMonth(caption) : ItemsStrings.cdPickDate(caption)) { picking = true }
                .accessibilityIdentifier("item_edit_field_pick_\(index)")
        }
        .sheet(isPresented: uncovered($picking, covered: covered)) {
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

/// The calendar; the day picked is stored as `YYYY-MM-DD` (§10.7). The picker, the day it opens on and the day stored all
/// go through one calendar (the iPhone's), so that the day picked is the day stored in every time zone.
struct DayPicker: View {
    @Environment(\.vettIDColors) private var colors
    let onDone: @MainActor (String?) -> Void
    private let calendar: Calendar
    @State private var day: Date

    init(stored: String, calendar: Calendar = .current, onDone: @escaping @MainActor (String?) -> Void) {
        self.onDone = onDone
        self.calendar = calendar
        _day = State(initialValue: DateInput.toPicker(stored, calendar: calendar) ?? Date())
    }

    var body: some View {
        VStack(spacing: Spacing.m) {
            DatePicker("", selection: $day, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                .environment(\.calendar, calendar)
                .environment(\.timeZone, calendar.timeZone)
                .accessibilityIdentifier("item_date_picker")
            PickerButtons(onCancel: { onDone(nil) }, onOK: { onDone(DateInput.fromPicker(day, calendar: calendar)) })
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
    /// The street takes the focus (the field was just added).
    let focus: Bool
    let onValue: @MainActor (AddressValue) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Spacing.xs) {
            part(ItemsStrings.addressStreet, address.street, first: true) { a, v in a.street = v }
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
        _ label: String, _ value: String, caps: Bool = false, first: Bool = false, _ set: @escaping (inout AddressValue, String) -> Void
    ) -> some View {
        let binding = Binding(get: { value }, set: { v in
            var a = address
            set(&a, v.replacingOccurrences(of: "\n", with: ""))
            onValue(a)
        })
        if secret {
            VisibleSecretField(
                label, text: binding, capitalization: caps ? .allCharacters : .words, focus: first && focus,
                accept: { _, typed in caps ? FieldInput.country(typed) : typed.replacingOccurrences(of: "\n", with: "") }
            )
        } else {
            let input = PlainField(placeholder: label, text: value) { binding.wrappedValue = $0 }
                .textInputAutocapitalization(caps ? .characters : .words)
                .accessibilityLabel(label)
            if first {
                input
                    .focused($focused)
                    .onAppear { if focus { focused = true } }
                    .onChange(of: focus) { _, now in if now { focused = true } }
            } else {
                input
            }
        }
    }
}
#endif
