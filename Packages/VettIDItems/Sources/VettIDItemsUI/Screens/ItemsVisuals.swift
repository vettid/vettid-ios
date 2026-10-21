#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// What the Vault destinations need from the app shell. Mirrors vettid-android `ItemsHost`.
public struct ItemsHost {
    /// An item's screen.
    public var onOpenItem: @MainActor (String) -> Void = { _ in }
    /// "Add to vault": the templates and a blank item.
    public var onAdd: @MainActor () -> Void = {}
    /// The add/edit screen over the picker or the item: [itemID] to edit, else a new item from [template] (nil: blank).
    public var onEdit: @MainActor (_ itemID: String?, _ template: String?) -> Void = { _, _ in }
    /// The tags screen ("Manage tags"); nil without the tags.
    public var onTags: (@MainActor () -> Void)?
    public var onBack: @MainActor () -> Void = {}
    /// Leaves the current screen for an item's (the editor, once saved, for the item it saved).
    public var replaceWithItem: @MainActor (String) -> Void = { _ in }

    public init() {}
}

/// Dates and times as the Vault shows them, in the iPhone's zone and locale (vettid-android `Times`).
enum ItemTimes {
    /// A full date and time (an item's created and updated).
    static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    /// A list row's date: the time today, the weekday this week, else the date.
    static func short(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: d)
        let today = calendar.startOfDay(for: now)
        if day == today { return d.formatted(date: .omitted, time: .shortened) }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), day >= weekAgo, day <= today {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The Vault's glyphs: a category's (by the registry's icon name, vettid-vault `docs/item-templates.json`) and a
/// sensitivity's. Mirrors vettid-android `ItemTemplates.icon` and `ItemsText.sensitivityIcon`.
enum ItemSymbols {
    private static let byIcon: [String: VettIDSymbol] = [
        "id-card": .badge, "key": .key, "credit-card": .cardMembership, "bank": .accountBalance, "medical": .medicalServices,
        "shield": .healthAndSafety, "car": .directionsCar, "person": .person, "note": .document, "wallet": .accountBalanceWallet,
    ]

    static func category(_ id: String) -> VettIDSymbol { byIcon[ItemTemplates.icon(id)] ?? .folder }

    static func sensitivity(_ s: Sensitivity) -> VettIDSymbol {
        switch s {
        case .data: .document
        case .secret: .hide
        case .critical: .lock
        }
    }
}

/// One sensitivity to choose, with what it means (a radio row). Mirrors vettid-android `SensitivityChoice`.
struct SensitivityChoice: View {
    @Environment(\.vettIDColors) private var colors
    let sensitivity: Sensitivity
    let selected: Bool
    var enabled = true
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                (selected ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                    .foregroundStyle(selected ? colors.primary : colors.onSurfaceVariant)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(ItemsText.sensitivity(sensitivity)).vettIDFont(.bodyLarge)
                        .foregroundStyle(enabled ? colors.onSurface : colors.onSurfaceVariant)
                    Text(ItemsText.sensitivityNote(sensitivity)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("sensitivity_\(sensitivity.rawValue)")
    }
}

/// The hero glyph above a ``FormScaffold`` title. Mirrors vettid-android `HeaderGlyph`.
struct HeaderGlyph: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: VettIDSymbol

    var body: some View {
        symbol.image
            .font(.system(size: 34))
            .foregroundStyle(colors.primary)
            .padding(.top, Spacing.l)
            .accessibilityHidden(true)
    }
}
#endif
