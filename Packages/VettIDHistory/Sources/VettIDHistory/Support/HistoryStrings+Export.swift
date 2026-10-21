import Foundation

/// The History export's texts (vettid-android `feature/history` `strings.xml`, ANDROID-PLAN §4 History "Export").
extension HistoryStrings {
    public static var moreActions: String { String(localized: "history_more_actions", defaultValue: "More options", bundle: .module) }

    public static var exportMenu: String { String(localized: "history_export_menu", defaultValue: "Export…", bundle: .module) }

    public static var exportTitle: String { String(localized: "history_export_title", defaultValue: "Export history", bundle: .module) }

    public static var exportPreparing: String {
        String(
            localized: "history_export_preparing",
            defaultValue: "Counting the entries…",
            bundle: .module
        )
    }

    public static func exportCount(_ count: Int) -> String {
        String(
            localized: "history_export_count",
            defaultValue: "\(count) entries",
            bundle: .module
        )
    }

    public static func exportCountRange(_ a: String, _ b: String) -> String {
        String(
            localized: "history_export_count_range",
            defaultValue: "\(a), \(b)",
            bundle: .module
        )
    }

    public static func exportFilters(_ a: String) -> String {
        String(
            localized: "history_export_filters",
            defaultValue: "What the list shows: \(a)",
            bundle: .module
        )
    }

    public static var exportFiltersNone: String {
        String(
            localized: "history_export_filters_none",
            defaultValue: "All of your history",
            bundle: .module
        )
    }

    public static func exportSearch(_ a: String) -> String {
        String(
            localized: "history_export_search",
            defaultValue: "“\(a)”",
            bundle: .module
        )
    }

    public static var exportMore: String {
        String(
            localized: "history_export_more",
            defaultValue: """
                Only the newest 10,000 of the matching entries can be exported. Narrow the dates to export older ones.
                """,
            bundle: .module
        )
    }

    public static var exportFormat: String { String(localized: "history_export_format", defaultValue: "Format", bundle: .module) }

    public static var exportCsv: String { String(localized: "history_export_csv", defaultValue: "CSV", bundle: .module) }

    public static var exportCsvNote: String {
        String(
            localized: "history_export_csv_note",
            defaultValue: "For a spreadsheet",
            bundle: .module
        )
    }

    public static var exportJson: String { String(localized: "history_export_json", defaultValue: "JSON", bundle: .module) }

    public static var exportJsonNote: String {
        String(
            localized: "history_export_json_note",
            defaultValue: "For checking against your vault",
            bundle: .module
        )
    }

    public static var exportUnencryptedTitle: String {
        String(
            localized: "history_export_unencrypted_title",
            defaultValue: "The file is not encrypted",
            bundle: .module
        )
    }

    public static var exportUnencrypted: String {
        String(
            localized: "history_export_unencrypted",
            defaultValue: """
                The file is not encrypted. Anyone who gets it can see who you connected with, your devices and item names, \
                and when. It holds no item values, passwords or messages.
                """,
            bundle: .module
        )
    }

    public static var exportContinue: String { String(localized: "history_export_continue", defaultValue: "Continue", bundle: .module) }

    public static var exportClose: String { String(localized: "history_export_close", defaultValue: "Close", bundle: .module) }

    public static var exportNothingTitle: String {
        String(
            localized: "history_export_nothing_title",
            defaultValue: "Nothing to export",
            bundle: .module
        )
    }

    public static var exportNothing: String {
        String(
            localized: "history_export_nothing",
            defaultValue: "No entries match what the list shows. Change the filters and try again.",
            bundle: .module
        )
    }

    public static var exportAlarmTitle: String {
        String(
            localized: "history_export_alarm_title",
            defaultValue: "Export is not available",
            bundle: .module
        )
    }

    public static var exportAlarm: String {
        String(
            localized: "history_export_alarm",
            defaultValue: "Export is not available while a credential alarm is open.",
            bundle: .module
        )
    }

    public static var exportAlarmOpen: String {
        String(
            localized: "history_export_alarm_open",
            defaultValue: "Open the alarm",
            bundle: .module
        )
    }

    public static var exportOldVaultTitle: String {
        String(
            localized: "history_export_old_vault_title",
            defaultValue: "Export is not available yet",
            bundle: .module
        )
    }

    public static var exportOldVault: String {
        String(
            localized: "history_export_old_vault",
            defaultValue: "Export needs a newer vault release. It will be offered once your vault is updated.",
            bundle: .module
        )
    }

    public static var exportPinTitle: String {
        String(
            localized: "history_export_pin_title",
            defaultValue: "Enter your vault PIN",
            bundle: .module
        )
    }

    public static var exportPinBody: String {
        String(
            localized: "history_export_pin_body",
            defaultValue: "Your vault PIN confirms the export. Your vault records it in your history.",
            bundle: .module
        )
    }

    public static var exportPinLabel: String { String(localized: "history_export_pin_label", defaultValue: "Vault PIN", bundle: .module) }

    public static var exportPinWrong: String { String(localized: "history_export_pin_wrong", defaultValue: "Wrong PIN", bundle: .module) }

    public static func exportPinBackoff(_ a: Int) -> String {
        String(
            localized: "history_export_pin_backoff",
            defaultValue: "Too many wrong PINs. Try again in \(a) s.",
            bundle: .module
        )
    }

    public static var exportPinBackoffUndated: String {
        String(
            localized: "history_export_pin_backoff_undated",
            defaultValue: "Too many wrong PINs. Try again later.",
            bundle: .module
        )
    }

    public static var exportExport: String { String(localized: "history_export_export", defaultValue: "Export", bundle: .module) }

    public static func exportReading(_ count: Int) -> String {
        String(
            localized: "history_export_reading",
            defaultValue: "Preparing \(count) entries…",
            bundle: .module
        )
    }

    public static func exportReadingProgress(_ a: Int, _ b: Int) -> String {
        String(
            localized: "history_export_reading_progress",
            defaultValue: "\(a) of \(b) read",
            bundle: .module
        )
    }

    public static var exportSaveTitle: String {
        String(
            localized: "history_export_save_title",
            defaultValue: "Choose where to save",
            bundle: .module
        )
    }

    public static var exportSaveBody: String {
        String(
            localized: "history_export_save_body",
            defaultValue: "Pick a place for the file in the dialog. Only you choose where it goes.",
            bundle: .module
        )
    }

    public static var exportSaveAgain: String {
        String(
            localized: "history_export_save_again",
            defaultValue: "Choose where to save",
            bundle: .module
        )
    }

    public static var exportWriting: String {
        String(
            localized: "history_export_writing",
            defaultValue: "Saving the file…",
            bundle: .module
        )
    }

    public static var exportDoneTitle: String {
        String(
            localized: "history_export_done_title",
            defaultValue: "History exported",
            bundle: .module
        )
    }

    public static func exportDone(_ count: Int) -> String {
        String(
            localized: "history_export_done",
            defaultValue: "\(count) entries exported.",
            bundle: .module
        )
    }

    public static func exportDonePartial(_ a: Int, _ b: Int, _ c: Int) -> String {
        String(
            localized: "history_export_done_partial",
            defaultValue: """
                \(a) of \(b) entries exported; \(c) older entries were removed by your vault's history limit meanwhile.
                """,
            bundle: .module
        )
    }

    public static var exportDoneNote: String {
        String(
            localized: "history_export_done_note",
            defaultValue: "The file is not encrypted: keep it somewhere safe, and delete it when you no longer need it.",
            bundle: .module
        )
    }

    public static var exportFailedTitle: String {
        String(
            localized: "history_export_failed_title",
            defaultValue: "Export did not finish",
            bundle: .module
        )
    }

    public static var exportSaveFailed: String {
        String(
            localized: "history_export_save_failed",
            defaultValue: "The file could not be saved. Nothing was kept; try again.",
            bundle: .module
        )
    }

    public static var exportOwnerCheck: String {
        String(
            localized: "history_export_owner_check",
            defaultValue: "Check now",
            bundle: .module
        )
    }

    public static func exportSummary(_ a: String, _ b: String) -> String {
        String(
            localized: "history_export_summary",
            defaultValue: "\(a) · \(b)",
            bundle: .module
        )
    }
}
