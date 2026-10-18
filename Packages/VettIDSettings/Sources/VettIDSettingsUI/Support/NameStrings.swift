import Foundation

/// The name change's texts and the account's name-status lines (vettid-android `feature/settings` `strings_profile.xml`,
/// word for word).
enum NameStrings {
    static var title: String {
        String(localized: "settings_name_title", defaultValue: "Change your name", bundle: .module)
    }

    static var body: String {
        String(
            localized: "settings_name_body",
            defaultValue: """
                Every connection sees the name on your VettID account. You can change it once every 30 days; VettID \
                applies the change, then your connections get the new name.
                """,
            bundle: .module
        )
    }

    static var first: String {
        String(localized: "settings_name_first", defaultValue: "First name", bundle: .module)
    }

    static var last: String {
        String(localized: "settings_name_last", defaultValue: "Last name", bundle: .module)
    }

    static var rule: String {
        String(localized: "settings_name_rule", defaultValue: "Letters, spaces and ' ’ . - only, at most 40 characters.", bundle: .module)
    }

    static var empty: String {
        String(localized: "settings_name_empty", defaultValue: "Enter a name.", bundle: .module)
    }

    static var tooLong: String {
        String(localized: "settings_name_too_long", defaultValue: "At most 40 characters.", bundle: .module)
    }

    static var invalid: String {
        String(
            localized: "settings_name_invalid",
            defaultValue: "Use letters, spaces and ' ’ . - only, starting with a letter.",
            bundle: .module
        )
    }

    static var same: String {
        String(localized: "settings_name_same", defaultValue: "This is already the name on your account.", bundle: .module)
    }

    static var continueLabel: String {
        String(localized: "settings_name_continue", defaultValue: "Continue", bundle: .module)
    }

    static var confirmTitle: String {
        String(localized: "settings_name_confirm_title", defaultValue: "Confirm with your PIN and password", bundle: .module)
    }

    static func confirmBody(_ s: String) -> String {
        String(
            localized: "settings_name_confirm_body",
            defaultValue: """
                Your vault checks your PIN and your credential password, as in the daily check, then asks VettID to change \
                your name to \(s).
                """,
            bundle: .module
        )
    }

    static var pin: String {
        String(localized: "settings_name_pin", defaultValue: "Vault PIN", bundle: .module)
    }

    static var password: String {
        String(localized: "settings_name_password", defaultValue: "Credential password", bundle: .module)
    }

    static var submit: String {
        String(localized: "settings_name_submit", defaultValue: "Change name", bundle: .module)
    }

    static var back: String {
        String(localized: "settings_name_back", defaultValue: "Back", bundle: .module)
    }

    static var badPin: String {
        String(localized: "settings_name_bad_pin", defaultValue: "That PIN is not correct.", bundle: .module)
    }

    static var badPassword: String {
        String(localized: "settings_name_bad_password", defaultValue: "That password is not correct.", bundle: .module)
    }

    static func checksLeft(_ n: Int) -> String {
        String(localized: "settings_name_checks_left", defaultValue: "\(n) more wrong tries lock your vault.", bundle: .module)
    }

    static var backoff: String {
        String(localized: "settings_name_backoff", defaultValue: "Too many wrong tries. Wait a moment, then try again.", bundle: .module)
    }

    static func wait(_ s: String) -> String {
        String(localized: "settings_name_wait", defaultValue: "Too many wrong tries. Try again in \(s).", bundle: .module)
    }

    static var refusedInvalid: String {
        String(
            localized: "settings_name_refused_invalid",
            defaultValue: "VettID did not accept the name. Use letters, spaces and ' ’ . - only, at most 40 characters each.",
            bundle: .module
        )
    }

    static var requestedTitle: String {
        String(localized: "settings_name_requested_title", defaultValue: "Name change requested", bundle: .module)
    }

    static func requestedBody(_ s: String) -> String {
        String(
            localized: "settings_name_requested_body",
            defaultValue: """
                VettID changes the name on your account to \(s). Your connections see the new name once it is applied; this \
                can take a moment.
                """,
            bundle: .module
        )
    }

    static var appliedTitle: String {
        String(localized: "settings_name_applied_title", defaultValue: "Your name was changed", bundle: .module)
    }

    static func appliedBody(_ s: String) -> String {
        String(
            localized: "settings_name_applied_body",
            defaultValue: "Your account name is now \(s). Your connections get the new name from your vault.",
            bundle: .module
        )
    }

    static var refusedTitle: String {
        String(localized: "settings_name_refused_title", defaultValue: "Your name was not changed", bundle: .module)
    }

    static var done: String {
        String(localized: "settings_name_done", defaultValue: "Done", bundle: .module)
    }

    static func statusPending(_ s: String) -> String {
        String(localized: "settings_name_status_pending", defaultValue: "Name change requested: \(s)", bundle: .module)
    }

    static func tooSoon(_ s: String) -> String {
        String(
            localized: "settings_name_too_soon",
            defaultValue: "You can change your name once every 30 days. You can change it again on \(s).",
            bundle: .module
        )
    }

    static var tooSoonUndated: String {
        String(localized: "settings_name_too_soon_undated", defaultValue: "You can change your name once every 30 days.", bundle: .module)
    }

    static var refusedAccount: String {
        String(localized: "settings_name_refused_account", defaultValue: "Your account cannot change its name right now.", bundle: .module)
    }
}
