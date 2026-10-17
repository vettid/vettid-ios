import Foundation

/// The package's texts, from `Resources/Localizable.xcstrings`. Keys are the Android string names
/// (vettid-android `core/ui/src/main/res/values/strings.xml`); the English values are the same.
enum UIStrings {
    static var openMenu: String { String(localized: "core_ui_cd_open_menu", defaultValue: "Open navigation menu", bundle: .module) }
    static var search: String { String(localized: "core_ui_cd_search", defaultValue: "Search", bundle: .module) }
    static var closeSearch: String { String(localized: "core_ui_cd_close_search", defaultValue: "Close search", bundle: .module) }
    static var dismiss: String { String(localized: "core_ui_cd_dismiss", defaultValue: "Dismiss", bundle: .module) }
    static var clearSearch: String {
        String(localized: "core_ui_cd_clear_search", defaultValue: "Clear and close search", bundle: .module)
    }
    static func account(_ name: String) -> String {
        String(localized: "core_ui_cd_account", defaultValue: "Account: \(name)", bundle: .module)
    }
    static var back: String { String(localized: "core_ui_cd_back", defaultValue: "Back", bundle: .module) }
    static var logo: String { String(localized: "core_ui_cd_logo", defaultValue: "VettID", bundle: .module) }
    static var cancel: String { String(localized: "core_ui_cancel", defaultValue: "Cancel", bundle: .module) }
    static func badgeCount(_ count: Int) -> String {
        String(localized: "core_ui_badge_count", defaultValue: "\(count) pending", bundle: .module)
    }
    static var notifications: String { String(localized: "core_ui_notifications", defaultValue: "Notifications", bundle: .module) }
    static func notificationsUnread(_ count: Int) -> String {
        String(localized: "core_ui_notifications_unread", defaultValue: "Notifications, \(count) unread", bundle: .module)
    }
    static func notificationsUnreadUrgent(_ count: Int) -> String {
        String(
            localized: "core_ui_notifications_unread_urgent",
            defaultValue: "Notifications, \(count) unread, one is urgent",
            bundle: .module
        )
    }
    static func filterOn(_ label: String) -> String {
        String(localized: "core_ui_filter_on", defaultValue: "\(label) filter on", bundle: .module)
    }
    static func filterOff(_ label: String) -> String {
        String(localized: "core_ui_filter_off", defaultValue: "\(label) filter off", bundle: .module)
    }
    static func favoriteAdd(_ name: String) -> String {
        String(localized: "core_ui_favorite_add", defaultValue: "Add \(name) to favourites", bundle: .module)
    }
    static func favoriteRemove(_ name: String) -> String {
        String(localized: "core_ui_favorite_remove", defaultValue: "Remove \(name) from favourites", bundle: .module)
    }
    static func strength(_ label: String) -> String {
        String(localized: "core_ui_cd_strength", defaultValue: "Password strength: \(label)", bundle: .module)
    }
    static var stepPending: String { String(localized: "core_ui_step_pending", defaultValue: "waiting", bundle: .module) }
    static var stepActive: String { String(localized: "core_ui_step_active", defaultValue: "in progress", bundle: .module) }
    static var stepDone: String { String(localized: "core_ui_step_done", defaultValue: "done", bundle: .module) }
    static var stepFailed: String { String(localized: "core_ui_step_failed", defaultValue: "failed", bundle: .module) }
    static func safetyCode(_ spokenDigits: String) -> String {
        String(localized: "core_ui_cd_safety_code", defaultValue: "Safety code \(spokenDigits)", bundle: .module)
    }
    static var clear: String { String(localized: "core_ui_clear", defaultValue: "Clear", bundle: .module) }
    static var clearFilters: String { String(localized: "core_ui_cd_clear_filters", defaultValue: "Clear filters", bundle: .module) }
    static func tagsMore(_ count: Int) -> String {
        String(localized: "core_ui_tags_more", defaultValue: "+\(count)", bundle: .module)
    }
    static func tagsMoreDescription(_ count: Int) -> String {
        String(localized: "core_ui_cd_tags_more", defaultValue: "\(count) more tags", bundle: .module)
    }
}
