import Foundation
import Observation

/// What notifications show (ANDROID-PLAN §4 Notification modes 8): the names (the default), the names and the message
/// text, or nothing. Mirrors vettid-android `NotificationPreviews`.
public enum NotificationPreviews: String, CaseIterable, Sendable {
    case names
    case namesAndText = "names_and_text"
    case nothing
}

/// Settings → App → "Show in notifications": a preference of this device, not a secret and not vault data, kept in
/// `UserDefaults` as ``ThemeSetting`` keeps the theme (vettid-android keeps it in its preferences DataStore,
/// `notificationPreviews`). A value that cannot be read is the default, names, as on Android.
@MainActor
@Observable
public final class NotificationPreviewsSetting {
    /// The `UserDefaults` key.
    public static let key = "settings.notification_previews"

    public private(set) var previews: NotificationPreviews
    @ObservationIgnored private let defaults: UserDefaults
    /// Told of each choice the member makes (the notifications showing follow it).
    @ObservationIgnored public var onSet: @MainActor (NotificationPreviews) -> Void = { _ in }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        previews = defaults.string(forKey: Self.key).flatMap(NotificationPreviews.init(rawValue:)) ?? .names
    }

    /// The member's choice: applied and stored.
    public func set(_ p: NotificationPreviews) {
        previews = p
        defaults.set(p.rawValue, forKey: Self.key)
        onSet(p)
    }

    /// A wipe: the default again, and nothing stored.
    public func reset() {
        previews = .names
        defaults.removeObject(forKey: Self.key)
    }
}
