import Foundation

// swiftlint:disable line_length

/// The texts of the microphone screens of calls (the owner approved them in Ground Control #10653, answer a), in
/// `Localizable.xcstrings`. A changed text is the owner's to approve (``CallStringsTests``). The screens come with the calls UI.
public enum CallStrings {
    /// The bundle of these texts (the tests read every key from it).
    public static var bundle: Bundle { .module }

    /// `NSMicrophoneUsageDescription` (the system's own prompt). **Not in the app's Info.plist yet**: no app target links the
    /// calls packages (owner decision), and the key goes only into a build that does. The change that links calls adds it,
    /// with this text.
    public static let microphoneUsageDescription = "VettID uses the microphone only during calls, so the person you're talking to can hear you."

    /// Our own screen before the system's prompt.
    public static var microphoneTitle: String {
        String(localized: "calls_microphone_title", defaultValue: "Allow the microphone", bundle: .module)
    }

    /// [name]: the other member's first name.
    public static func microphoneBody(_ name: String) -> String {
        String(
            localized: "calls_microphone_body",
            defaultValue: "VettID needs the microphone so \(name) can hear you. It is used only during calls.",
            bundle: .module
        )
    }

    public static var microphoneAllow: String {
        String(localized: "calls_microphone_allow", defaultValue: "Allow", bundle: .module)
    }

    public static var microphoneNotNow: String {
        String(localized: "calls_microphone_not_now", defaultValue: "Not now", bundle: .module)
    }

    /// The microphone is denied: iOS asks no more.
    public static var microphoneBlockedTitle: String {
        String(localized: "calls_microphone_blocked_title", defaultValue: "The microphone is turned off for VettID", bundle: .module)
    }

    public static var microphoneBlockedBody: String {
        String(
            localized: "calls_microphone_blocked_body",
            defaultValue: "iOS doesn't ask again. To make and answer calls, allow the microphone for VettID in Settings.",
            bundle: .module
        )
    }

    public static var microphoneOpenSettings: String {
        String(localized: "calls_microphone_open_settings", defaultValue: "Open Settings", bundle: .module)
    }

    public static var microphoneClose: String {
        String(localized: "calls_microphone_close", defaultValue: "Close", bundle: .module)
    }
}
// swiftlint:enable line_length
