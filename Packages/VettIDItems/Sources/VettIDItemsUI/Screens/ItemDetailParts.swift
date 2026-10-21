#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// The fields of an item in a card, then its notes. Held inside the screen's ``SecureContainer``.
struct ItemValues: View {
    @Environment(\.vettIDColors) private var colors
    let item: ItemDetail
    let shown: Set<String>
    let actions: ItemDetailActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            DetailCard {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if item.fields.isEmpty {
                        Text(ItemsStrings.noFields).foregroundStyle(colors.onSurfaceVariant)
                    }
                    ForEach(Array(item.fields.enumerated()), id: \.offset) { i, f in
                        if i > 0 { Divider() }
                        ItemFieldRow(
                            field: f, protection: item.sensitivity, revealed: item.revealed,
                            shown: f.fieldID.map(shown.contains) ?? false, actions: actions
                        )
                    }
                }
            }
            .accessibilityIdentifier("item_fields")
            if item.hasNotes || !(item.notes ?? "").isEmpty {
                DetailCard {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(ItemsStrings.notes).vettIDFont(.labelLarge)
                        Text(item.notes ?? ItemsStrings.hiddenValue)
                            .vettIDFont(.bodyLarge)
                            .foregroundStyle(item.notes == nil ? colors.onSurfaceVariant : colors.onSurface)
                            .textSelection(.disabled)
                    }
                }
                .accessibilityIdentifier("item_notes")
            }
        }
    }
}

/// One field: its label, its value (hidden, masked or shown), the show and copy buttons, and a one-time code field's
/// current code. Mirrors vettid-android `FieldRow`.
struct ItemFieldRow: View {
    @Environment(\.vettIDColors) private var colors
    let field: ItemFieldView
    let protection: Sensitivity
    let revealed: Bool
    let shown: Bool
    let actions: ItemDetailActions

    private var text: String? {
        switch field.value {
        case .text(let t)?: t
        case .address(let a)?: a.lines.joined(separator: "\n")
        case nil: nil
        }
    }

    var body: some View {
        let masked = FieldKinds.masked(field.kind)
        let otp = field.kind == FieldKinds.otp
        let text = text
        let id = field.fieldID ?? ""
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(field.label).vettIDFont(.labelMedium).foregroundStyle(colors.onSurfaceVariant)
            HStack(spacing: Spacing.xs) {
                Text(display(text, masked: masked))
                    .vettIDFont(.bodyLarge)
                    .font(masked && shown ? .body.monospaced() : nil)
                    .foregroundStyle((text ?? "").isEmpty || (masked && !shown) ? colors.onSurfaceVariant : colors.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("item_value_\(id)")
                if let text, !text.isEmpty, revealed {
                    if masked, let fid = field.fieldID {
                        let label = shown ? ItemsStrings.cdHideValue(field.label) : ItemsStrings.cdShowValue(field.label)
                        IconButton(shown ? .hide : .show, label: label) {
                            actions.onToggleShown(fid)
                        }
                    }
                    // A one-time code's value is its seed: copied only where the member chose to see it. What is copied
                    // otherwise is the current code, below.
                    if !otp || shown {
                        IconButton(.contentCopy, label: otp ? ItemsStrings.cdCopySeed(field.label) : ItemsStrings.cdCopy(field.label)) {
                            actions.onCopy(text)
                        }
                        .accessibilityIdentifier("item_copy_\(id)")
                    }
                }
            }
            if otp, revealed, let text, !text.isEmpty {
                OtpCode(seed: text, label: field.label, onCopy: actions.onCopy)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item_field_\(id)")
    }

    private func display(_ text: String?, masked: Bool) -> String {
        guard let text, revealed else { return ItemsStrings.hiddenValue }
        if text.isEmpty { return ItemsStrings.emptyValue }
        if masked && !shown { return ItemsStrings.maskedValue }
        return field.kind == FieldKinds.phone ? PhoneInput.display(text) : text
    }
}

/// The current one-time code of an `otp` seed (§10.7: apps show codes, RFC 6238), with the seconds it has left and a
/// button that copies the code current at that moment (never the seed). Mirrors vettid-android `OtpCode`.
struct OtpCode: View {
    @Environment(\.vettIDColors) private var colors
    let seed: String
    let label: String
    let onCopy: @MainActor (String) -> Void

    var body: some View {
        if let totp = Totp.parse(seed) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = Int64(context.date.timeIntervalSince1970)
                HStack(spacing: Spacing.m) {
                    Text(Self.grouped(totp.code(now)))
                        .font(.title2.monospaced().weight(.semibold))
                        .foregroundStyle(colors.primary)
                    Text(ItemsStrings.otpLeft(Int(totp.secondsLeft(now))))
                        .vettIDFont(.bodySmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton(.contentCopy, label: ItemsStrings.cdCopyCode(label)) {
                        onCopy(totp.code(Int64(Date().timeIntervalSince1970)))
                    }
                    .accessibilityIdentifier("item_otp_copy")
                }
            }
            .accessibilityIdentifier("item_otp")
        } else {
            Text(ItemsStrings.otpUnreadable).vettIDFont(.bodySmall).foregroundStyle(colors.error)
        }
    }

    /// The code in groups of three ("123 456").
    static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 3).map { i in
            let s = code.index(code.startIndex, offsetBy: i)
            return String(code[s..<code.index(s, offsetBy: min(3, code.count - i))])
        }.joined(separator: " ")
    }
}

/// The item screen's confirmations: delete, leaving `critical`, and the protection to pick. Each closes when the app is
/// covered.
struct ItemDetailDialogs: ViewModifier {
    @Environment(\.vettIDCovered) private var covered
    let state: ItemDetailState
    let actions: ItemDetailActions

    private func shown(_ d: DetailDialog) -> Binding<Bool> {
        Binding(get: { state.dialog == d && state.item != nil }, set: { if !$0 { actions.onDismissDialog() } })
    }

    func body(content: Content) -> some View {
        let name = state.item?.name ?? ""
        content
            .confirmDialog(
                isPresented: shown(.delete), title: ItemsStrings.deleteTitle(name),
                message: state.item?.sensitivity == .critical ? ItemsStrings.deleteBodyCritical : ItemsStrings.deleteBody,
                confirmLabel: ItemsStrings.delete, destructive: true, onConfirm: actions.onConfirmDelete
            )
            .confirmDialog(
                isPresented: shown(.leaveCritical), title: ItemsStrings.leaveCriticalTitle, message: ItemsStrings.leaveCriticalBody,
                confirmLabel: ItemsStrings.leaveCriticalConfirm, destructive: true, onConfirm: actions.onConfirmLeaveCritical
            )
            .sheet(isPresented: uncovered(shown(.protectionPick), covered: covered)) {
                ProtectionPicker(current: state.item?.sensitivity ?? .data, actions: actions)
                    .presentationDetents([.medium])
            }
    }
}

/// "Protection": the three sensitivities, the item's checked. Mirrors the protection dialog of vettid-android
/// `ItemDetailScreen`.
struct ProtectionPicker: View {
    @Environment(\.vettIDColors) private var colors
    let current: Sensitivity
    let actions: ItemDetailActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ItemsStrings.protectionTitle).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
            ForEach(Sensitivity.allCases, id: \.self) { s in
                SensitivityChoice(sensitivity: s, selected: s == current) { actions.onPickProtection(s) }
            }
            HStack {
                Spacer()
                Button(ItemsStrings.cancel) { actions.onDismissDialog() }
                    .foregroundStyle(colors.primary)
                    .frame(minHeight: Spacing.touchTarget)
            }
        }
        .padding(Spacing.xl)
        .presentationBackground(colors.surfaceContainerLow.color)
        .accessibilityIdentifier("item_protection_dialog")
    }
}
#endif
