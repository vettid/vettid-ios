import SwiftUI

/// The VettID rook, the brand kit's icon without its tile (Rook Gold, the keyhole cut out) at [height]; width keeps
/// the 264:350 ratio. The mark for every size below the logo's minimum (``VettIDLogo``).
///
/// Mirrors vettid-android `RookLogo.kt`; the artwork is its `ic_rook` vector as SVG.
public struct RookLogo: View {
    let height: CGFloat
    let decorative: Bool

    public init(height: CGFloat = 32, decorative: Bool = false) {
        self.height = height
        self.decorative = decorative
    }

    public var body: some View {
        Image("Rook", bundle: .module)
            .resizable()
            .frame(width: height * Self.aspect, height: height)
            .accessibilityHidden(decorative)
            .accessibilityLabel(UIStrings.logo)
    }

    private static let aspect: CGFloat = 264 / 350
}

/// The brand kit's horizontal logo (the rook and the VETTID wordmark, no tagline), [width] wide. The wordmark is
/// artwork: never type "VettID" next to the rook instead.
///
/// The kit's rules are the caller's to keep: at least ``minWidth`` wide (smaller, use ``RookLogo``), and
/// ``clearSpace(width:)`` of empty space on every side. The artwork follows the theme: the gold wordmark on dark
/// surfaces, the kit's on-light file (VettID Blue wordmark, gold rook) on light ones; [onDark] overrides it for a logo
/// on a surface that does not follow the theme.
///
/// Mirrors vettid-android `VettIdLogo.kt`.
public struct VettIDLogo: View {
    @Environment(\.vettIDColors) private var colors
    let width: CGFloat
    let decorative: Bool
    let onDark: Bool?

    public init(width: CGFloat = VettIDLogo.minWidth, decorative: Bool = false, onDark: Bool? = nil) {
        precondition(width >= VettIDLogo.minWidth, "the horizontal logo is at least 160 pt wide; use RookLogo")
        self.width = width
        self.decorative = decorative
        self.onDark = onDark
    }

    public var body: some View {
        Image((onDark ?? colors.isDark) ? "LogoHorizontal" : "LogoHorizontalOnLight", bundle: .module)
            .resizable()
            .frame(width: width, height: width / Self.aspect)
            .accessibilityHidden(decorative)
            .accessibilityLabel(UIStrings.logo)
    }

    private static let artworkWidth: CGFloat = 631.6
    private static let artworkHeight: CGFloat = 200
    /// The battlements are 96 of the rook's 344 units, and the rook is the artwork's height.
    private static let battlements: CGFloat = artworkHeight * 96 / 344

    /// Minimum size of the horizontal logo on screen (the artwork's width).
    public static let minWidth: CGFloat = 160
    /// Width : height of the artwork (631.6 × 200 of the kit's 752 × 300 canvas).
    public static let aspect: CGFloat = artworkWidth / artworkHeight

    /// The kit's clear space X, the height of the rook's battlements, for a logo [width] wide.
    public static func clearSpace(width: CGFloat) -> CGFloat { width * (battlements / artworkWidth) }
}
