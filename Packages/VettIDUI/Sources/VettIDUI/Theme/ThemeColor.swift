import SwiftUI

/// An opaque sRGB colour of the palette (or one with an [alpha]), kept as its
/// value so that tests can compute contrast. Usable directly as a shape style
/// (`.foregroundStyle(colors.primary)`); `.color` gives the SwiftUI `Color`.
public struct ThemeColor: Hashable, Sendable, ShapeStyle {
    /// 0xRRGGBB.
    public let rgb: UInt32
    public let alpha: Double

    public init(_ rgb: UInt32, alpha: Double = 1) {
        self.rgb = rgb & 0xFF_FFFF
        self.alpha = alpha
    }

    public var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    public var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(rgb & 0xFF) / 255 }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// The same colour with [alpha] (Compose's `copy(alpha = …)`).
    public func opacity(_ alpha: Double) -> ThemeColor { ThemeColor(rgb, alpha: alpha) }

    public func resolve(in environment: EnvironmentValues) -> Color { color }
}
