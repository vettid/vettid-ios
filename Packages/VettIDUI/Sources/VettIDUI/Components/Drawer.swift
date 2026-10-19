import SwiftUI

/// One drawer destination. [badge] > 0 shows a gold count pill.
public struct DrawerItem: Identifiable, Hashable, Sendable {
    public let key: String
    public let label: String
    public let icon: VettIDSymbol
    public let badge: Int

    public init(key: String, label: String, icon: VettIDSymbol, badge: Int = 0) {
        self.key = key
        self.label = label
        self.icon = icon
        self.badge = badge
    }

    public var id: String { key }
}

/// Navigation drawer sheet (Proton; IOS-PLAN ID14): logo header, then groups of destinations separated by hairlines,
/// and the app version at the bottom. Mirrors vettid-android `VettIdDrawerSheet`.
public struct VettIDDrawerSheet: View {
    @Environment(\.vettIDColors) private var colors
    let sections: [[DrawerItem]]
    let selectedKey: String?
    let versionLabel: String
    let onSelect: @MainActor (DrawerItem) -> Void

    /// The drawer's width.
    public static let width: CGFloat = 312

    public init(
        sections: [[DrawerItem]],
        selectedKey: String?,
        versionLabel: String,
        onSelect: @escaping @MainActor (DrawerItem) -> Void
    ) {
        self.sections = sections
        self.selectedKey = selectedKey
        self.versionLabel = versionLabel
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The horizontal logo at its minimum width, with at least the kit's clear space (14 pt) on every side.
            VettIDLogo()
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.l)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        if index > 0 { Hairline(color: colors.outlineVariant) }
                        ForEach(section) { item in
                            DrawerRow(item: item, selected: item.key == selectedKey) { onSelect(item) }
                        }
                    }
                }
            }
            Hairline(color: colors.outlineVariant)
            Text(versionLabel)
                .vettIDFont(.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
                .padding(Spacing.xl)
        }
        .frame(maxWidth: Self.width, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.surfaceContainerLow)
    }
}

private struct DrawerRow: View {
    @Environment(\.vettIDColors) private var colors
    let item: DrawerItem
    let selected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                item.icon.image
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? colors.primary : colors.onSurfaceVariant)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Spacer().frame(width: Spacing.xl)
                Text(item.label)
                    .vettIDFont(.bodyLarge, weight: selected ? .semibold : .regular)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(selected ? colors.onSurface : colors.onSurface.opacity(0.87))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.badge > 0 { CountBadge(item.badge) }
            }
            .padding(.horizontal, Spacing.xl)
            .frame(minHeight: 56)
            .background(selected ? colors.surfaceContainer : colors.surfaceContainerLow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("drawer_\(item.key)")
    }
}

/// A 1 pt horizontal divider (Material's `HorizontalDivider`).
public struct Hairline: View {
    let color: ThemeColor
    let thickness: CGFloat

    public init(color: ThemeColor, thickness: CGFloat = 1) {
        self.color = color
        self.thickness = thickness
    }

    public var body: some View {
        Rectangle().fill(color).frame(height: thickness).accessibilityHidden(true)
    }
}
