import SwiftUI

/// Spacing scale (4 pt grid). Mirrors vettid-android `core/ui/…/theme/Spacing.kt`.
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48

    /// Horizontal screen gutter.
    public static let gutter: CGFloat = 16

    /// Minimum touch target (Android's 48 dp; above Apple's 44 pt minimum).
    public static let touchTarget: CGFloat = 48
}

/// Shapes of VettID components. Mirrors vettid-android `core/ui/…/theme/Shape.kt`.
public enum VettIDShape {
    /// Rounded square for initial tiles: about 28 % of the side, as in Proton.
    public static func tile(_ side: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
    }

    /// Grouped settings cards and detail cards.
    public static let card = RoundedRectangle(cornerRadius: 20, style: .continuous)

    /// Pills: filter chips, floating action bar, badges.
    public static let pill = Capsule(style: .continuous)

    /// Material's shape scale (extraSmall … extraLarge), for components that use it.
    public static let extraSmall: CGFloat = 6
    public static let small: CGFloat = 10
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 20
    public static let extraLarge: CGFloat = 28
}
