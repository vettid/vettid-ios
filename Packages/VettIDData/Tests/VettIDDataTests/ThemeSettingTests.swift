import Foundation
import Testing
@testable import VettIDData

/// Settings → App → Theme: the choices in vettid-android's order, the cycle of `nextThemeMode` (vettid-android
/// `ThemeModeTest`), and the stored choice read back at the next start.
@MainActor
@Suite struct ThemeSettingTests {
    /// A fresh suite of its own (never the app's domain).
    private func defaults() throws -> UserDefaults {
        let name = "theme-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func theChoicesAndTheirCycle() {
        #expect(ThemePreference.allCases == [.system, .light, .dark])
        var mode = ThemePreference.system
        var seen = [mode]
        for _ in 0..<3 {
            mode = mode.next
            seen.append(mode)
        }
        #expect(seen == [.system, .light, .dark, .system])
    }

    @Test func systemDefaultUntilChosenThenStoredAndReadBack() throws {
        let d = try defaults()
        let first = ThemeSetting(defaults: d)
        #expect(first.theme == .system)
        first.set(.dark)
        #expect(first.theme == .dark)
        #expect(d.string(forKey: ThemeSetting.key) == "dark")
        #expect(ThemeSetting(defaults: d).theme == .dark)
        first.set(.light)
        #expect(ThemeSetting(defaults: d).theme == .light)
    }

    /// An unreadable value is the system default (vettid-android: `valueOf` failing gives `SYSTEM`).
    @Test func anUnreadableValueIsTheSystemDefault() throws {
        let d = try defaults()
        d.set("sepia", forKey: ThemeSetting.key)
        #expect(ThemeSetting(defaults: d).theme == .system)
    }

    /// The debug launch argument is shown but never stored; the member's choice replaces it.
    @Test func theLaunchOverrideIsNotStored() throws {
        let d = try defaults()
        d.set("light", forKey: ThemeSetting.key)
        let s = ThemeSetting(defaults: d, launchOverride: .dark)
        #expect(s.theme == .dark)
        #expect(d.string(forKey: ThemeSetting.key) == "light")
        s.set(.system)
        #expect(ThemeSetting(defaults: d).theme == .system)
    }
}
