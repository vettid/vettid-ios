import Foundation

/// The Notifications screen's texts: vettid-android `feature/notifications` `strings.xml`, word for word, under its
/// string names. The feed items' own titles are VettIDData's (``FeedKinds`` `+Titles`, IOS-PLAN §4.1).
enum NotificationsStrings {
    static var title: String { String(localized: "notifications_title", defaultValue: "Notifications", bundle: .module) }

    static var archivedTitle: String { String(localized: "notifications_archived_title", defaultValue: "Archived", bundle: .module) }

    static var more: String { String(localized: "notifications_more", defaultValue: "More actions", bundle: .module) }

    static var markAllRead: String { String(localized: "notifications_mark_all_read", defaultValue: "Mark all as read", bundle: .module) }

    static var filterUnread: String { String(localized: "notifications_filter_unread", defaultValue: "Unread", bundle: .module) }

    static var needsAttention: String {
        String(
            localized: "notifications_needs_attention",
            defaultValue: "Needs attention",
            bundle: .module
        )
    }

    static var today: String { String(localized: "notifications_today", defaultValue: "Today", bundle: .module) }

    static var yesterday: String { String(localized: "notifications_yesterday", defaultValue: "Yesterday", bundle: .module) }

    static var undated: String { String(localized: "notifications_undated", defaultValue: "Earlier", bundle: .module) }

    static var archive: String { String(localized: "notifications_archive", defaultValue: "Archive", bundle: .module) }

    static var archivedSnackbar: String {
        String(
            localized: "notifications_archived_snackbar",
            defaultValue: "Notification archived",
            bundle: .module
        )
    }

    static var undo: String { String(localized: "notifications_undo", defaultValue: "Undo", bundle: .module) }

    static var markRead: String { String(localized: "notifications_mark_read", defaultValue: "Mark as read", bundle: .module) }

    static var markUnread: String { String(localized: "notifications_mark_unread", defaultValue: "Mark as unread", bundle: .module) }

    static var moveBack: String { String(localized: "notifications_move_back", defaultValue: "Move to Notifications", bundle: .module) }

    static var delete: String { String(localized: "notifications_delete", defaultValue: "Delete", bundle: .module) }

    static var deleteTitle: String {
        String(
            localized: "notifications_delete_title",
            defaultValue: "Delete this notification?",
            bundle: .module
        )
    }

    static var deleteBody: String {
        String(
            localized: "notifications_delete_body",
            defaultValue: "Delete this notification on all your devices?",
            bundle: .module
        )
    }

    static func deleteBatch(_ value: String) -> String {
        String(
            localized: "notifications_delete_batch",
            defaultValue: "Later requests from \(value) will start a new notification.",
            bundle: .module
        )
    }

    static var stateUnread: String { String(localized: "notifications_state_unread", defaultValue: "Unread", bundle: .module) }

    static var stateImportant: String { String(localized: "notifications_state_important", defaultValue: "Important", bundle: .module) }

    static var stateUrgent: String { String(localized: "notifications_state_urgent", defaultValue: "Urgent", bundle: .module) }

    static var emptyTitle: String { String(localized: "notifications_empty_title", defaultValue: "No notifications", bundle: .module) }

    static var emptyBody: String {
        String(
            localized: "notifications_empty_body",
            defaultValue: "What happens in your vault appears here",
            bundle: .module
        )
    }

    static var emptyUnreadTitle: String {
        String(
            localized: "notifications_empty_unread_title",
            defaultValue: "Nothing unread",
            bundle: .module
        )
    }

    static var emptyUnreadBody: String {
        String(
            localized: "notifications_empty_unread_body",
            defaultValue: "You have read every notification",
            bundle: .module
        )
    }

    static var emptyArchivedTitle: String {
        String(
            localized: "notifications_empty_archived_title",
            defaultValue: "Nothing archived",
            bundle: .module
        )
    }

    static var emptyArchivedBody: String {
        String(
            localized: "notifications_empty_archived_body",
            defaultValue: "Notifications you archive appear here",
            bundle: .module
        )
    }

    static var loadFailed: String {
        String(
            localized: "notifications_load_failed",
            defaultValue: "Your notifications could not be read.",
            bundle: .module
        )
    }

    static var retry: String { String(localized: "notifications_retry", defaultValue: "Try again", bundle: .module) }

    static var sheetTime: String { String(localized: "notifications_sheet_time", defaultValue: "When", bundle: .module) }

    static var sheetConnection: String { String(localized: "notifications_sheet_connection", defaultValue: "Connection", bundle: .module) }

    static var sheetItem: String { String(localized: "notifications_sheet_item", defaultValue: "Item", bundle: .module) }

    static var sheetKind: String { String(localized: "notifications_sheet_kind", defaultValue: "Kind", bundle: .module) }

    static var sheetNoLongerWaiting: String {
        String(
            localized: "notifications_sheet_no_longer_waiting",
            defaultValue: "This is no longer waiting.",
            bundle: .module
        )
    }

    static var sheetGone: String {
        String(
            localized: "notifications_sheet_gone",
            defaultValue: "What this was about is no longer there.",
            bundle: .module
        )
    }

    static var sheetNotAvailable: String {
        String(
            localized: "notifications_sheet_not_available",
            defaultValue: "Not available in this version of the app.",
            bundle: .module
        )
    }

    static var sheetUnknown: String {
        String(
            localized: "notifications_sheet_unknown",
            defaultValue: "A newer kind of notification. Update VettID to see more.",
            bundle: .module
        )
    }
}
