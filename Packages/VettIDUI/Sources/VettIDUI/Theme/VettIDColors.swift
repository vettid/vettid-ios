/// The colours of one theme: the Material roles the Android app uses, and the
/// VettID colours outside them. Mirrors vettid-android `core/ui/…/theme/Color.kt`
/// (`DarkColors`, `LightColors`, `VettIdColors`), role for role.
///
/// Role mapping (both themes):
/// - `primary` = gold *content* (icons, selected text, switches); `primaryContainer` = gold *fill*.
/// - `background` = screen; `surfaceContainerLow` = drawer and sheets;
///   `surfaceContainer` = cards, chips, floating buttons; `surfaceContainerHigh` = pressed / nested.
public struct VettIDColors: Hashable, Sendable {
    public let primary: ThemeColor
    public let onPrimary: ThemeColor
    public let primaryContainer: ThemeColor
    public let onPrimaryContainer: ThemeColor
    public let secondary: ThemeColor
    public let onSecondary: ThemeColor
    public let secondaryContainer: ThemeColor
    public let onSecondaryContainer: ThemeColor
    public let background: ThemeColor
    public let onBackground: ThemeColor
    public let surface: ThemeColor
    public let onSurface: ThemeColor
    public let surfaceVariant: ThemeColor
    public let onSurfaceVariant: ThemeColor
    public let surfaceDim: ThemeColor
    public let surfaceBright: ThemeColor
    public let surfaceContainerLowest: ThemeColor
    public let surfaceContainerLow: ThemeColor
    public let surfaceContainer: ThemeColor
    public let surfaceContainerHigh: ThemeColor
    public let surfaceContainerHighest: ThemeColor
    public let inverseSurface: ThemeColor
    public let inverseOnSurface: ThemeColor
    public let inversePrimary: ThemeColor
    public let outline: ThemeColor
    public let outlineVariant: ThemeColor
    public let error: ThemeColor
    public let onError: ThemeColor

    // VettID colours outside the Material roles.

    /// Background of a connection's initial tile.
    public let tile: ThemeColor
    /// Letter on ``tile``.
    public let onTile: ThemeColor
    /// Tile of a favourite connection (`connection.update` favorite, VAULT-MESSAGING §10.4).
    public let favoriteTile: ThemeColor
    public let onFavoriteTile: ThemeColor
    /// The member's own avatar tile (gold).
    public let avatar: ThemeColor
    public let onAvatar: ThemeColor
    public let success: ThemeColor
    public let warning: ThemeColor
    /// Background of grouped screens (settings); also the hairline between rows in a group.
    public let groupedBackground: ThemeColor
    /// Grouped settings card.
    public let card: ThemeColor
    /// Background behind modal content (drawer, sheet).
    public let scrim: ThemeColor
    /// The dark theme (picks the tag colours, ``TagColors``).
    public let isDark: Bool
}

public extension VettIDColors {
    static let dark = VettIDColors(
        primary: VettIDPalette.gold,
        onPrimary: VettIDPalette.ink,
        primaryContainer: VettIDPalette.gold,
        onPrimaryContainer: VettIDPalette.ink,
        secondary: VettIDPalette.inkBody,
        onSecondary: VettIDPalette.ink,
        secondaryContainer: VettIDPalette.navy800,
        onSecondaryContainer: VettIDPalette.inkHigh,
        background: VettIDPalette.navy900,
        onBackground: VettIDPalette.inkHigh,
        surface: VettIDPalette.navy900,
        onSurface: VettIDPalette.inkHigh,
        surfaceVariant: VettIDPalette.navy800,
        onSurfaceVariant: VettIDPalette.inkBody,
        surfaceDim: VettIDPalette.navy950,
        surfaceBright: VettIDPalette.navy700,
        surfaceContainerLowest: VettIDPalette.navy950,
        surfaceContainerLow: VettIDPalette.navy850,
        surfaceContainer: VettIDPalette.navy800,
        surfaceContainerHigh: VettIDPalette.navy700,
        surfaceContainerHighest: VettIDPalette.navy600,
        inverseSurface: VettIDPalette.inkHigh,
        inverseOnSurface: VettIDPalette.navy900,
        inversePrimary: VettIDPalette.goldDeep,
        outline: VettIDPalette.navy600,
        outlineVariant: VettIDPalette.navy800,
        error: VettIDPalette.errorDark,
        onError: VettIDPalette.ink,
        tile: VettIDPalette.indigo,
        onTile: VettIDPalette.inkHigh,
        favoriteTile: VettIDPalette.teal,
        onFavoriteTile: VettIDPalette.white,
        avatar: VettIDPalette.gold,
        onAvatar: VettIDPalette.ink,
        success: VettIDPalette.success,
        warning: VettIDPalette.warning,
        groupedBackground: VettIDPalette.navy850,
        card: VettIDPalette.navy800,
        scrim: VettIDPalette.navy950.opacity(0.6),
        isDark: true
    )

    static let light = VettIDColors(
        primary: VettIDPalette.goldDeep,
        onPrimary: VettIDPalette.white,
        primaryContainer: VettIDPalette.gold,
        onPrimaryContainer: VettIDPalette.ink,
        secondary: VettIDPalette.inkMuteLight,
        onSecondary: VettIDPalette.white,
        secondaryContainer: VettIDPalette.mist100,
        onSecondaryContainer: VettIDPalette.ink,
        background: VettIDPalette.paper,
        onBackground: VettIDPalette.ink,
        surface: VettIDPalette.paper,
        onSurface: VettIDPalette.ink,
        surfaceVariant: VettIDPalette.mist100,
        onSurfaceVariant: VettIDPalette.inkMuteLight,
        surfaceDim: VettIDPalette.mist200,
        surfaceBright: VettIDPalette.paper,
        surfaceContainerLowest: VettIDPalette.paper,
        surfaceContainerLow: VettIDPalette.mist50,
        surfaceContainer: VettIDPalette.mist100,
        surfaceContainerHigh: VettIDPalette.mist200,
        surfaceContainerHighest: VettIDPalette.mist300,
        inverseSurface: VettIDPalette.navy900,
        inverseOnSurface: VettIDPalette.inkHigh,
        inversePrimary: VettIDPalette.gold,
        outline: VettIDPalette.mist300,
        outlineVariant: VettIDPalette.mist200,
        error: VettIDPalette.errorLight,
        onError: VettIDPalette.white,
        tile: VettIDPalette.indigo,
        onTile: VettIDPalette.white,
        favoriteTile: VettIDPalette.teal,
        onFavoriteTile: VettIDPalette.white,
        avatar: VettIDPalette.gold,
        onAvatar: VettIDPalette.ink,
        success: VettIDPalette.successDeep,
        warning: VettIDPalette.warningDeep,
        groupedBackground: VettIDPalette.mist100,
        card: VettIDPalette.paper,
        scrim: VettIDPalette.ink.opacity(0.4),
        isDark: false
    )
}
