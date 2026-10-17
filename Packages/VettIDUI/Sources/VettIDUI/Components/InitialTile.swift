import SwiftUI

/// First letter or digit of the name, upper-cased; "?" for a name without one.
public func initialOf(_ name: String) -> String {
    guard let c = name.trimmingCharacters(in: .whitespaces).first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
    return String(c).uppercased()
}

/// Visual role of an ``InitialTile``: a connection, a favourite connection, or the member.
public enum TileStyle: Sendable {
    case connection, favorite, ownAccount
}

/// Rounded-square tile with an initial (Proton's avatar tile). Decorative: the row or button around it carries the
/// accessible label. A [photo] (a shared profile photo, VAULT-MESSAGING §10.8) fills the tile instead of the initial;
/// an [icon] replaces the initial on non-person rows (History). [colors] overrides the [style]'s colours (a tag's own
/// colour on the tags screen, ``TagColors``).
///
/// Mirrors vettid-android `InitialTile.kt`.
public struct InitialTile: View {
    @Environment(\.vettIDColors) private var theme
    let name: String
    let size: CGFloat
    let style: TileStyle
    let photo: UIImage?
    let icon: VettIDSymbol?
    let colors: TagColor?

    public init(
        _ name: String,
        size: CGFloat = 40,
        style: TileStyle = .connection,
        photo: UIImage? = nil,
        icon: VettIDSymbol? = nil,
        colors: TagColor? = nil
    ) {
        self.name = name
        self.size = size
        self.style = style
        self.photo = photo
        self.icon = icon
        self.colors = colors
    }

    public var body: some View {
        let (bg, fg) = tileColors
        ZStack {
            bg.color
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if let icon {
                icon.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.5, height: size * 0.5)
                    .foregroundStyle(fg)
            } else {
                // The letter scales with the tile, not with Dynamic Type: the tile does not grow.
                Text(verbatim: initialOf(name))
                    .font(VettIDTextStyle.titleMedium.font(weight: .semibold, size: size * 0.45))
                    .dynamicTypeSize(.large)
                    .foregroundStyle(fg)
            }
        }
        .frame(width: size, height: size)
        .clipShape(VettIDShape.tile(size))
        .accessibilityHidden(true)
    }

    private var tileColors: (ThemeColor, ThemeColor) {
        if let colors { return (colors.container, colors.onContainer) }
        switch style {
        case .connection: return (theme.tile, theme.onTile)
        case .favorite: return (theme.favoriteTile, theme.onFavoriteTile)
        case .ownAccount: return (theme.avatar, theme.onAvatar)
        }
    }
}
