import SwiftUI

// MARK: - Android-parity palette
//
// Exact hex values ported from the Android app's
// `ui/theme/Theme.kt` so iOS surfaces match the brand:
// gold + black + grays, with the cloud connection-status colors.

extension Color {
    /// Build a Color from a 24-bit RGB hex literal (e.g. 0xF4B942).
    init(rgbHex hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Brand palette, matching Android `VettidGold` etc.
enum VettIDColor {
    // Brand primitives
    static let gold = Color(rgbHex: 0xF4B942)
    static let goldDark = Color(rgbHex: 0xD9A137)
    static let goldLight = Color(rgbHex: 0xFFD980)
    static let black = Color(rgbHex: 0x000000)
    static let darkGray = Color(rgbHex: 0x121212)
    static let mediumGray = Color(rgbHex: 0x2C2C2C)
    static let lightGray = Color(rgbHex: 0x9E9E9E)
    static let offWhite = Color(rgbHex: 0xF5F5F5)
    static let white = Color(rgbHex: 0xFFFFFF)

    // Cloud connection-status colors (Android NatsConnectionStatusIndicator)
    static let statusConnected = Color(rgbHex: 0x4CAF50) // green
    static let statusConnecting = Color(rgbHex: 0xFFC107) // amber
    static let statusExpired = Color(rgbHex: 0xFF9800)    // orange
    static let statusFailed = Color(rgbHex: 0xF44336)     // red
    static let statusIdle = Color(rgbHex: 0x757575)       // gray

    // Per-connection-type accents for the typed cards.
    static let systemAccent = gold              // VettID system connection
    static let userAccent = Color(rgbHex: 0x4C8BF5)   // peer/person — blue
    static let desktopAccent = Color(rgbHex: 0x26A69A) // desktop client — teal
    static let agentAccent = Color(rgbHex: 0xAB47BC)   // agent — purple
}
