import SwiftUI

private let maxBadge = 99

/// The text of a count badge: the count, or "99+" above 99.
func badgeText(_ count: Int) -> String { count > maxBadge ? "\(maxBadge)+" : "\(count)" }

/// Gold count pill (drawer badge, pending approvals). Mirrors vettid-android `CountBadge`.
public struct CountBadge: View {
    @Environment(\.vettIDColors) private var colors
    let count: Int

    public init(_ count: Int) { self.count = count }

    public var body: some View {
        Text(verbatim: badgeText(count))
            .vettIDFont(.labelMedium, weight: .bold)
            .foregroundStyle(colors.onPrimaryContainer)
            .padding(.horizontal, Spacing.s)
            .frame(minWidth: 24, minHeight: 24)
            .background(colors.primaryContainer, in: VettIDShape.pill)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UIStrings.badgeCount(count))
    }
}

/// Small tinted label next to a row title (Proton's "New"). Mirrors vettid-android `TagLabel`.
public struct TagLabel: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .vettIDFont(.labelMedium)
            .foregroundStyle(colors.primary)
            .padding(.horizontal, Spacing.s + Spacing.xxs)
            .padding(.vertical, Spacing.xxs)
            .background(colors.primary.opacity(0.16), in: VettIDShape.pill)
    }
}
