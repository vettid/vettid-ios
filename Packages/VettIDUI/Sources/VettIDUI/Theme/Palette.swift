/// Raw brand palette, aligned with the website tokens (vettid.org
/// `website/assets/site.css`; token names in comments). Screens never use these
/// directly: they read ``VettIDColors`` from the environment.
///
/// Gold (#FFC125, `--gold`) is the single accent. On light surfaces it is too pale
/// for text and icons (1.6:1), so "gold content" there uses ``goldDeep``
/// (`--gold-ink-light`, 5.6:1 on white) and the bright gold is kept for fills.
///
/// Mirrors vettid-android `core/ui/…/theme/Color.kt`.
public enum VettIDPalette {
    public static let gold = ThemeColor(0xFFC125) // --gold
    public static let goldDeep = ThemeColor(0x7F640A) // --gold-ink-light
    public static let ink = ThemeColor(0x101018) // --ink-on-light
    public static let white = ThemeColor(0xFFFFFF)

    // Navy ramp (dark theme surfaces), after the website's surface tokens.
    public static let navy950 = ThemeColor(0x0B0B18)
    public static let navy900 = ThemeColor(0x14142A) // --surface-1
    public static let navy850 = ThemeColor(0x1B1B3A) // --surface-2
    public static let navy800 = ThemeColor(0x26264A)
    public static let navy700 = ThemeColor(0x30305A)
    public static let navy600 = ThemeColor(0x3E3E6C)
    public static let indigo = ThemeColor(0x2E2D88) // --surface-indigo

    /// Favourite connections' tiles: a teal that sits with navy and gold.
    public static let teal = ThemeColor(0x1F7A6B)

    // Light theme neutrals.
    public static let paper = ThemeColor(0xFFFFFF)
    public static let mist50 = ThemeColor(0xF7F7FA)
    public static let mist100 = ThemeColor(0xF4F4F6) // --band-light
    public static let mist200 = ThemeColor(0xE6E6EE)
    public static let mist300 = ThemeColor(0xD9D9DF) // --border-light

    public static let inkHigh = ThemeColor(0xF7F7FA) // --ink-hi
    public static let inkBody = ThemeColor(0xA9A9C2)
    public static let inkMuteLight = ThemeColor(0x4C4C58) // --ink-on-light-mute

    public static let success = ThemeColor(0x3FD97F) // --success
    public static let successDeep = ThemeColor(0x1E7A46)
    public static let warning = ThemeColor(0xFFB020) // --warn
    public static let warningDeep = ThemeColor(0x8A5A00)
    public static let errorDark = ThemeColor(0xFF6B6B) // --error
    public static let errorLight = ThemeColor(0xB3261E)
}
