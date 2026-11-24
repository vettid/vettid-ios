import Foundation

// The texts of an agent's request held for approval (ANDROID-PLAN 0.1.116 §4 AA5; 0.1.137 AA8), word for word as vettid-android's
// `feature/approvals` `strings.xml` has them (`approvals_held_*`, `approvals_loading`, `approvals_no_longer_waiting`,
// `approvals_approve`, `approvals_kind_*`, `approvals_waiting_*`), under the same names.
extension ApprovalsStrings {
    static func heldUseTitle(_ who: String, _ item: String) -> String {
        String(
            localized: "approvals_held_use_title",
            defaultValue: "\(who) wants to use \(item) without seeing it",

            bundle: .module
        )
    }

    static func heldUseBody(_ field: String) -> String {
        String(
            localized: "approvals_held_use_body",
            defaultValue: """
            Field: \(field). Your vault uses the value for the agent and gives it only the result. For \
            a short or guessable value, such as a PIN or a common password, the agent could work the \
            value out from that result.
            """,
            bundle: .module
        )
    }

    static var heldUseData: String {
        String(
            localized: "approvals_held_use_data",
            defaultValue: "Data from the agent",

            bundle: .module
        )
    }

    static var heldUseDataHex: String {
        String(
            localized: "approvals_held_use_data_hex",
            defaultValue: "Not text, so shown as hexadecimal",

            bundle: .module
        )
    }

    static func heldGetTitle(_ who: String, _ item: String) -> String {
        String(
            localized: "approvals_held_get_title",
            defaultValue: "\(who) wants to see \(item)",

            bundle: .module
        )
    }

    static func heldGetFields(_ fields: String) -> String {
        String(
            localized: "approvals_held_get_fields",
            defaultValue: "Fields: \(fields)",

            bundle: .module
        )
    }

    static var heldGetAll: String {
        String(
            localized: "approvals_held_get_all",
            defaultValue: "All fields and notes",

            bundle: .module
        )
    }

    static var heldGetHistory: String {
        String(
            localized: "approvals_held_get_history",
            defaultValue: "The agent's app may keep the value in its history.",

            bundle: .module
        )
    }

    static func heldCatalogTitle(_ who: String) -> String {
        String(
            localized: "approvals_held_catalog_title",
            defaultValue: "\(who) wants to list the items it may use",

            bundle: .module
        )
    }

    static var heldCatalogBody: String {
        String(
            localized: "approvals_held_catalog_body",
            defaultValue: "It sees their names and field labels, never their values.",

            bundle: .module
        )
    }

    static func heldLaterTitle(_ who: String, _ item: String) -> String {
        String(
            localized: "approvals_held_later_title",
            defaultValue: "\(who) wants to use \(item) in a way this version of VettID can't show",

            bundle: .module
        )
    }

    static var heldLaterBody: String {
        String(
            localized: "approvals_held_later_body",
            defaultValue: "Update VettID to see the details. Until then you can only deny it.",

            bundle: .module
        )
    }

    static func heldOtherTitle(_ who: String) -> String {
        String(
            localized: "approvals_held_other_title",
            defaultValue: "\(who) asks to approve a request",

            bundle: .module
        )
    }

    static var heldDesktopBody: String {
        String(
            localized: "approvals_held_desktop_body",
            defaultValue: "Desktop requests can't be shown in this version of VettID, so you can only deny them.",

            bundle: .module
        )
    }

    static var heldOtherBody: String {
        String(
            localized: "approvals_held_other_body",
            defaultValue: "This version of VettID can't show this request, so you can only deny it.",

            bundle: .module
        )
    }

    static var heldNoItem: String {
        String(
            localized: "approvals_held_no_item",
            defaultValue: "an item you no longer have",

            bundle: .module
        )
    }

    static var heldNoItemBody: String {
        String(
            localized: "approvals_held_no_item_body",
            defaultValue: "This phone can't find that item or field any more, so you can only deny the request.",

            bundle: .module
        )
    }

    static var heldItemsUnreadBody: String {
        String(
            localized: "approvals_held_items_unread_body",
            defaultValue: """
                Your items could not be read, so this phone can't say what the request is about. Until they are read, you can only \
                deny it.
                """,
            bundle: .module
        )
    }

    static var heldApproved: String { String(localized: "approvals_held_approved", defaultValue: "Approved", bundle: .module) }
    static var heldDenied: String { String(localized: "approvals_held_denied", defaultValue: "Denied", bundle: .module) }
    static func heldForbidden(_ who: String) -> String {
        String(
            localized: "approvals_held_forbidden",
            defaultValue: "Approved, but \(who) no longer has a permission that covers it, or is paused, so nothing was done.",

            bundle: .module
        )
    }

    static func heldSessionEnded(_ who: String) -> String {
        String(
            localized: "approvals_held_session_ended",
            defaultValue: "Approved, but \(who)'s access ended first, so nothing was done.",

            bundle: .module
        )
    }

    static var heldWayNotAllowed: String {
        String(
            localized: "approvals_held_way_not_allowed",
            defaultValue: "Approved, but this item no longer allows that, so nothing was done.",

            bundle: .module
        )
    }

    static func heldOtherResult(_ code: String) -> String {
        String(
            localized: "approvals_held_other_result",
            defaultValue: "Approved, but your vault answered: \(code).",

            bundle: .module
        )
    }

    static var heldNoResult: String {
        String(
            localized: "approvals_held_no_result",
            defaultValue: "Your vault didn't say whether it was done.",

            bundle: .module
        )
    }

    static var loading: String { String(localized: "approvals_loading", defaultValue: "Loading…", bundle: .module) }
    static var noLongerWaiting: String {
        String(
            localized: "approvals_no_longer_waiting",
            defaultValue: "This request is no longer waiting.",

            bundle: .module
        )
    }

    static var approve: String { String(localized: "approvals_approve", defaultValue: "Approve", bundle: .module) }
    static var kindAgent: String { String(localized: "approvals_kind_agent", defaultValue: "Agent", bundle: .module) }
    static var kindDesktop: String { String(localized: "approvals_kind_desktop", defaultValue: "Desktop", bundle: .module) }
    static var kindDevice: String { String(localized: "approvals_kind_device", defaultValue: "Device", bundle: .module) }
    static var waitingLess: String {
        String(
            localized: "approvals_waiting_less",
            defaultValue: "Waiting for less than a minute",

            bundle: .module
        )
    }
    /// "<N> byte(s)": the length of the data an `item.use` asks to compute over.
    static func heldUseBytes(_ count: Int) -> String {
        String(localized: "approvals_held_use_bytes", defaultValue: "\(count) bytes", bundle: .module)
    }

    /// "Waiting for <N> more minute(s)" (to the request's `exp`).
    static func waitingMinutes(_ count: Int) -> String {
        String(localized: "approvals_waiting_minutes", defaultValue: "Waiting for \(count) more minutes", bundle: .module)
    }
}
