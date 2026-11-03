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
    /// The least a target may measure (Apple's HIG: 44 pt), for a control drawn smaller than it is hit.
    public static let minTarget: CGFloat = 44
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

/// An icon (a symbol drawn at a point size) that follows Dynamic Type with the body text, up to [capFactor] times its
/// size so that a glyph in a row, a notice or a button never outgrows what is laid out around it (IOS-PLAN ID5).
struct ScaledIconModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let base: CGFloat
    private let weight: Font.Weight
    static let capFactor: CGFloat = 1.75

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        base = size
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: Self.capped(size, base: base), weight: weight))
    }

    static func capped(_ scaled: CGFloat, base: CGFloat) -> CGFloat { min(scaled, base * capFactor) }
}

public extension View {
    /// A symbol at [size] points at the default text size, scaling with Dynamic Type (not past ``ScaledIconModifier/capFactor``).
    func scaledIcon(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledIconModifier(size: size, weight: weight))
    }
}

/// The fixed-width column of an icon, scaled the same way as ``View/scaledIcon(size:weight:)``, so that rows keep their
/// text aligned and the glyph stays inside its column.
struct ScaledIconColumn: ViewModifier {
    @ScaledMetric private var width: CGFloat
    private let base: CGFloat

    init(width: CGFloat) {
        _width = ScaledMetric(wrappedValue: width, relativeTo: .body)
        base = width
    }

    func body(content: Content) -> some View {
        content.frame(width: ScaledIconModifier.capped(width, base: base))
    }
}

public extension View {
    /// A column [width] points wide at the default text size beside an icon, scaling with it.
    func scaledIconColumn(_ width: CGFloat) -> some View { modifier(ScaledIconColumn(width: width)) }
}
