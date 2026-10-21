import Foundation

/// History's texts: vettid-android `feature/history` `strings.xml`, word for word, under its string names (the export's
/// in ``HistoryStrings`` `+Export`; the kinds' titles and detail lines in ``HistoryKindTexts``). Every text of History is
/// in this package's table, so that the view models build the titles a search and an export use.
public enum HistoryStrings {
    public static var title: String { String(localized: "history_title", defaultValue: "History", bundle: .module) }

    public static var search: String { String(localized: "history_search", defaultValue: "Search by name or event", bundle: .module) }

    public static var searchClear: String { String(localized: "history_search_clear", defaultValue: "Clear search", bundle: .module) }

    public static var searchLocal: String {
        String(
            localized: "history_search_local",
            defaultValue: """
                Your vault does not search its history yet: this phone searches the entries it loads, by event and \
                connection name.
                """,
            bundle: .module
        )
    }

    public static var searchingOlder: String {
        String(
            localized: "history_searching_older",
            defaultValue: "Searching older entries…",
            bundle: .module
        )
    }

    public static var chainBroken: String {
        String(
            localized: "history_chain_broken",
            defaultValue: "Your vault's history does not match what this phone saw before",
            bundle: .module
        )
    }

    public static var emptyTitle: String { String(localized: "history_empty_title", defaultValue: "No history yet", bundle: .module) }

    public static var emptyBody: String {
        String(
            localized: "history_empty_body",
            defaultValue: "What happens in your vault is recorded here: unlocks, connections, messages, items and more",
            bundle: .module
        )
    }

    public static var noMatchTitle: String {
        String(
            localized: "history_no_match_title",
            defaultValue: "No activity matches these filters",
            bundle: .module
        )
    }

    public static var noMatchBody: String {
        String(
            localized: "history_no_match_body",
            defaultValue: "Change the search, or tap “✕ Clear” above to show all activity",
            bundle: .module
        )
    }

    public static var errorTitle: String {
        String(
            localized: "history_error_title",
            defaultValue: "History could not be loaded",
            bundle: .module
        )
    }

    public static var retry: String { String(localized: "history_retry", defaultValue: "Try again", bundle: .module) }

    public static var loadingMore: String {
        String(
            localized: "history_loading_more",
            defaultValue: "Loading older entries",
            bundle: .module
        )
    }

    public static var end: String { String(localized: "history_end", defaultValue: "Start of your history", bundle: .module) }

    public static var categoryAll: String { String(localized: "history_category_all", defaultValue: "All", bundle: .module) }

    public static var categoryVaultAccess: String {
        String(
            localized: "history_category_vault_access",
            defaultValue: "Unlocks and daily checks",
            bundle: .module
        )
    }

    public static var categorySecurity: String { String(localized: "history_category_security", defaultValue: "Security", bundle: .module) }

    public static var categoryDevices: String { String(localized: "history_category_devices", defaultValue: "Devices", bundle: .module) }

    public static var categoryConnections: String {
        String(
            localized: "history_category_connections",
            defaultValue: "Connections",
            bundle: .module
        )
    }

    public static var categoryMessages: String {
        String(
            localized: "history_category_messages",
            defaultValue: "Messages and calls",
            bundle: .module
        )
    }

    public static var categoryItems: String {
        String(
            localized: "history_category_items",
            defaultValue: "Vault (items, sharing, wallet)",
            bundle: .module
        )
    }

    public static var categoryAgents: String { String(localized: "history_category_agents", defaultValue: "Agents", bundle: .module) }

    public static var categoryLocation: String { String(localized: "history_category_location", defaultValue: "Location", bundle: .module) }

    public static var categoryAccount: String {
        String(
            localized: "history_category_account",
            defaultValue: "Account and settings",
            bundle: .module
        )
    }

    public static var categoryDropped: String {
        String(
            localized: "history_category_dropped",
            defaultValue: "Blocked and dropped",
            bundle: .module
        )
    }

    public static var categoryOther: String { String(localized: "history_category_other", defaultValue: "Other", bundle: .module) }

    public static var connectionAny: String {
        String(
            localized: "history_connection_any",
            defaultValue: "All connections",
            bundle: .module
        )
    }

    public static var connectionPick: String { String(localized: "history_connection_pick", defaultValue: "Connection", bundle: .module) }

    public static var connectionRemoved: String {
        String(
            localized: "history_connection_removed",
            defaultValue: "Removed connection",
            bundle: .module
        )
    }

    public static var connectionUnnamed: String {
        String(
            localized: "history_connection_unnamed",
            defaultValue: "Name not shared yet",
            bundle: .module
        )
    }

    public static var dateAny: String { String(localized: "history_date_any", defaultValue: "Any time", bundle: .module) }

    public static var dateDay: String { String(localized: "history_date_day", defaultValue: "Today", bundle: .module) }

    public static var dateWeek: String { String(localized: "history_date_week", defaultValue: "Last 7 days", bundle: .module) }

    public static var dateMonth: String { String(localized: "history_date_month", defaultValue: "Last 30 days", bundle: .module) }

    public static var dateCustom: String { String(localized: "history_date_custom", defaultValue: "Choose dates…", bundle: .module) }

    public static func dateRange(_ a: String, _ b: String) -> String {
        String(
            localized: "history_date_range",
            defaultValue: "\(a) – \(b)",
            bundle: .module
        )
    }

    public static var datePick: String { String(localized: "history_date_pick", defaultValue: "Dates", bundle: .module) }

    public static var ok: String { String(localized: "history_ok", defaultValue: "OK", bundle: .module) }

    public static var cancel: String { String(localized: "history_cancel", defaultValue: "Cancel", bundle: .module) }

    public static func kindSummary(_ a: String) -> String {
        String(
            localized: "history_kind_summary",
            defaultValue: "\(a) (hourly summary)",
            bundle: .module
        )
    }

    public static func kindDropped(_ a: String) -> String {
        String(
            localized: "history_kind_dropped",
            defaultValue: "Message blocked: \(a)",
            bundle: .module
        )
    }

    public static func kindUnknown(_ a: String) -> String {
        String(
            localized: "history_kind_unknown",
            defaultValue: "Vault event: \(a)",
            bundle: .module
        )
    }

    public static var detailWhen: String { String(localized: "history_detail_when", defaultValue: "When", bundle: .module) }

    public static var detailCategory: String { String(localized: "history_detail_category", defaultValue: "Category", bundle: .module) }

    public static var detailKind: String { String(localized: "history_detail_kind", defaultValue: "Event type", bundle: .module) }

    public static var detailConnection: String {
        String(
            localized: "history_detail_connection",
            defaultValue: "Connection",
            bundle: .module
        )
    }

    public static var detailDevice: String { String(localized: "history_detail_device", defaultValue: "Device", bundle: .module) }

    public static var detailDeviceId: String { String(localized: "history_detail_device_id", defaultValue: "Device ID", bundle: .module) }

    public static func deviceThisPhone(_ a: String) -> String {
        String(
            localized: "history_device_this_phone",
            defaultValue: "\(a) (this phone)",
            bundle: .module
        )
    }

    public static var deviceThisPhoneAlone: String {
        String(
            localized: "history_device_this_phone_alone",
            defaultValue: "This phone",
            bundle: .module
        )
    }

    public static var detailRef: String { String(localized: "history_detail_ref", defaultValue: "Reference", bundle: .module) }

    public static var detailDirection: String { String(localized: "history_detail_direction", defaultValue: "Direction", bundle: .module) }

    public static var detailDirectionIn: String {
        String(
            localized: "history_detail_direction_in",
            defaultValue: "Incoming",
            bundle: .module
        )
    }

    public static var detailDirectionOut: String {
        String(
            localized: "history_detail_direction_out",
            defaultValue: "Outgoing",
            bundle: .module
        )
    }

    public static var detailSeq: String { String(localized: "history_detail_seq", defaultValue: "Entry number", bundle: .module) }

    public static var detailId: String { String(localized: "history_detail_id", defaultValue: "Entry ID", bundle: .module) }

    public static var detailHash: String { String(localized: "history_detail_hash", defaultValue: "Entry hash", bundle: .module) }

    public static func detailCopy(_ a: String) -> String {
        String(
            localized: "history_detail_copy",
            defaultValue: "Copy \(a)",
            bundle: .module
        )
    }

    public static var detailOpenConnection: String {
        String(
            localized: "history_detail_open_connection",
            defaultValue: "Open connection",
            bundle: .module
        )
    }

    public static var detailUnknownTime: String {
        String(
            localized: "history_detail_unknown_time",
            defaultValue: "Unknown time",
            bundle: .module
        )
    }

    public static var detailNote: String {
        String(
            localized: "history_detail_note",
            defaultValue: """
                Your vault keeps this log append-only and hash-chained: no one can change or delete an entry. It holds no \
                message text, item values or keys.
                """,
            bundle: .module
        )
    }

    public static var detailMissing: String {
        String(
            localized: "history_detail_missing",
            defaultValue: "This entry is no longer in your history.",
            bundle: .module
        )
    }

    public static var itemDeleted: String { String(localized: "history_item_deleted", defaultValue: "Deleted item", bundle: .module) }

    public static var detailItem: String { String(localized: "history_detail_item", defaultValue: "Item", bundle: .module) }

    public static var detailOpenItem: String {
        String(
            localized: "history_detail_open_item",
            defaultValue: "Open the item",
            bundle: .module
        )
    }

    public static var deviceRemoved: String { String(localized: "history_device_removed", defaultValue: "Removed device", bundle: .module) }
}
