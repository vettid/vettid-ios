#if os(iOS)
import SwiftUI
import VettIDUI

/// One choice of a ``ChoiceSheet``: its label, an optional line under it.
struct ChoiceOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var detail: String?

    var id: Value { value }
}

/// A single-choice list (radio rows) with Cancel: the timeout, the app lock's method, the owner check's interval. A
/// sheet at the medium detent where vettid-android shows its `ChoiceDialog`; [note] goes under the choices.
struct ChoiceSheet<Value: Hashable>: View {
    @Environment(\.vettIDColors) private var colors
    let title: String
    let options: [ChoiceOption<Value>]
    let selected: Value
    var note: String?
    let onPick: @MainActor (Value) -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .vettIDFont(.titleMedium)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, Spacing.m)
                ForEach(options) { o in row(o) }
                if let note {
                    Text(note)
                        .vettIDFont(.bodySmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .padding(.top, Spacing.s)
                }
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Text(SettingsStrings.cancel)
                            .vettIDFont(.labelLarge, weight: .semibold)
                            .foregroundStyle(colors.primary)
                            .frame(minHeight: Spacing.touchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("choice_cancel")
                }
                .padding(.top, Spacing.m)
            }
            .padding(Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(colors.surfaceContainerLow)
    }

    private func row(_ o: ChoiceOption<Value>) -> some View {
        let on = o.value == selected
        return Button { onPick(o.value) } label: {
            HStack(spacing: Spacing.m) {
                (on ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                    .foregroundStyle(on ? colors.primary : colors.onSurfaceVariant)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(o.label).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                    if let detail = o.detail {
                        Text(detail).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

extension View {
    /// Presents [choice] as a ``ChoiceSheet`` while it is set, in this screen's colours.
    func choiceSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(ChoiceSheetModifier(item: item, sheet: content))
    }
}

private struct ChoiceSheetModifier<Item: Identifiable, Sheet: View>: ViewModifier {
    @Environment(\.vettIDColors) private var colors
    @Binding var item: Item?
    let sheet: (Item) -> Sheet

    func body(content: Content) -> some View {
        content.sheet(item: $item) { i in
            sheet(i)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(colors.surfaceContainerLow.color)
                .environment(\.vettIDColors, colors)
        }
    }
}

/// A text action under a notice ("Done"): the primary colour, the touch target's height.
struct NoticeAction: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    var identifier: String?
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(colors.primary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Spacing.touchTarget)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// Dates and times as Settings shows them, in the iPhone's zone and locale (vettid-android `Times`).
enum SettingsTimes {
    /// A full date and time (details, expiries).
    static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}
#endif
