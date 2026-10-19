import Foundation
import Observation

/// The app's theme choice. Mirrors vettid-android `ThemePreference`.
public enum ThemePreference: String, CaseIterable, Sendable {
    case system, light, dark

    /// The choice after this one, cycling System → Light → Dark. Mirrors vettid-android `nextThemeMode`.
    public var next: ThemePreference {
        switch self {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }
}

/// Settings → App → Theme (ANDROID-PLAN §4 "Screens", Settings): a preference of this device, not a secret and not vault
/// data, kept in `UserDefaults` where vettid-android keeps it in its preferences DataStore (`PreferencesRepository.theme`,
/// `setTheme`). Read at app start; the app's root observes ``theme``, so a change applies everywhere at once. A value that
/// cannot be read is the system default, as on Android. A process started before the phone's first unlock may find the
/// defaults unreadable and show the system default until it restarts; the stored choice is kept (written only by
/// ``set(_:)``).
@MainActor
@Observable
public final class ThemeSetting {
    /// The `UserDefaults` key.
    public static let key = "settings.theme"

    public private(set) var theme: ThemePreference
    @ObservationIgnored private let defaults: UserDefaults

    /// [launchOverride]: the debug builds' theme from a launch argument (screenshots, vettid-android's `themeOverride`):
    /// shown until the member chooses, never stored.
    public init(defaults: UserDefaults = .standard, launchOverride: ThemePreference? = nil) {
        self.defaults = defaults
        theme = launchOverride ?? defaults.string(forKey: Self.key).flatMap(ThemePreference.init(rawValue:)) ?? .system
    }

    /// Shown, not stored (the debug gallery's theme chips).
    public func show(_ t: ThemePreference) { theme = t }

    /// The member's choice: applied and stored.
    public func set(_ t: ThemePreference) {
        theme = t
        defaults.set(t.rawValue, forKey: Self.key)
    }
}
