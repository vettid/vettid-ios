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

    /// The debug gallery's chips: shown, the member's stored choice untouched.
    @Test func aThemeShownIsNotStored() throws {
        let d = try defaults()
        let s = ThemeSetting(defaults: d)
        s.set(.light)
        s.show(.dark)
        #expect(s.theme == .dark)
        #expect(ThemeSetting(defaults: d).theme == .light)
    }
}

/// Settings → App → "Show in notifications" (ANDROID-PLAN §4 Notification modes 8): names until chosen (Android's
/// default), then the stored choice read back at the next start; a value that does not read is the default.
@MainActor
@Suite struct NotificationPreviewsSettingTests {
    @Test func namesUntilChosenThenStoredAndReadBack() throws {
        let name = "previews-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        #expect(NotificationPreviews.allCases == [.names, .namesAndText, .nothing])
        let first = NotificationPreviewsSetting(defaults: d)
        #expect(first.previews == .names)
        first.set(.nothing)
        #expect(first.previews == .nothing && NotificationPreviewsSetting(defaults: d).previews == .nothing)
        d.set("garbled", forKey: NotificationPreviewsSetting.key)
        #expect(NotificationPreviewsSetting(defaults: d).previews == .names)
    }

    /// Each choice is told (the notifications showing follow it); a wipe's reset is the default, stored nowhere.
    @Test func aChoiceIsToldAndAResetIsTheDefault() throws {
        let name = "previews-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let s = NotificationPreviewsSetting(defaults: d)
        var told: [NotificationPreviews] = []
        s.onSet = { told.append($0) }
        s.set(.nothing)
        #expect(told == [.nothing])
        s.reset()
        #expect(s.previews == .names && d.string(forKey: NotificationPreviewsSetting.key) == nil && told == [.nothing])
    }
}

/// A notification's tap waits at most ``NotificationOpenInbox/maxWait`` for the shell (chosen; not in the spec).
@MainActor
@Suite struct NotificationOpenInboxStaleTests {
    @Test func aTapOlderThanTenMinutesIsStale() {
        var t = Date(timeIntervalSince1970: 1_000)
        let inbox = NotificationOpenInbox(now: { t })
        #expect(!inbox.isStale)
        inbox.offer("f1")
        t += 600
        #expect(!inbox.isStale)
        t += 1
        #expect(inbox.isStale)
        // Tapped again: it waits from the new tap.
        inbox.offer("f1")
        #expect(!inbox.isStale)
        inbox.consume()
        t += 10_000
        #expect(!inbox.isStale && inbox.itemID == nil)
    }
}
