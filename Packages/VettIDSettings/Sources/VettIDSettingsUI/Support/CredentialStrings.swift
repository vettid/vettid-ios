import Foundation

/// The Credential screen's and the password change's texts (vettid-android `feature/credential` `strings.xml`, word for
/// word).
enum CredentialStrings {
    static var title: String {
        String(localized: "credential_title", defaultValue: "Credential", bundle: .module)
    }

    static var emptyTitle: String {
        String(localized: "credential_empty_title", defaultValue: "No credential yet", bundle: .module)
    }

    static var emptyBody: String {
        String(
            localized: "credential_empty_body",
            defaultValue: "Your Protean Credential is created when you enroll your vault",
            bundle: .module
        )
    }

    static var loading: String {
        String(localized: "credential_loading", defaultValue: "Loading your credential", bundle: .module)
    }

    static var retry: String {
        String(localized: "credential_retry", defaultValue: "Try again", bundle: .module)
    }

    static var sectionStatus: String {
        String(localized: "credential_section_status", defaultValue: "Protean Credential", bundle: .module)
    }

    static var version: String {
        String(localized: "credential_version", defaultValue: "Version", bundle: .module)
    }

    static var key: String {
        String(localized: "credential_key", defaultValue: "Credential key", bundle: .module)
    }

    static var updated: String {
        String(localized: "credential_updated", defaultValue: "Last changed", bundle: .module)
    }

    static var criticalItems: String {
        String(localized: "credential_critical_items", defaultValue: "Critical items", bundle: .module)
    }

    static var backup: String {
        String(localized: "credential_backup", defaultValue: "Sealed backup", bundle: .module)
    }

    static var unknown: String {
        String(localized: "credential_unknown", defaultValue: "Unknown", bundle: .module)
    }

    static var sectionWindow: String {
        String(localized: "credential_section_window", defaultValue: "Unlock window", bundle: .module)
    }

    static var windowState: String {
        String(localized: "credential_window_state", defaultValue: "Status", bundle: .module)
    }

    static var windowClosed: String {
        String(localized: "credential_window_closed", defaultValue: "Closed", bundle: .module)
    }

    static func windowOpenUntil(_ s: String) -> String {
        String(localized: "credential_window_open_until", defaultValue: "Open until \(s)", bundle: .module)
    }

    static var windowOpen: String {
        String(localized: "credential_window_open", defaultValue: "Open the unlock window", bundle: .module)
    }

    static var windowOpenBody: String {
        String(
            localized: "credential_window_open_body",
            defaultValue: "Lets signing actions (member authentication, agents) use your credential key without asking each time.",
            bundle: .module
        )
    }

    static var windowClose: String {
        String(localized: "credential_window_close", defaultValue: "Close it now", bundle: .module)
    }

    static var windowLength: String {
        String(localized: "credential_window_length", defaultValue: "Window length", bundle: .module)
    }

    static var ttlTitle: String {
        String(localized: "credential_ttl_title", defaultValue: "Unlock window length", bundle: .module)
    }

    static var ttlThirtySeconds: String {
        String(localized: "credential_ttl_30s", defaultValue: "30 seconds", bundle: .module)
    }

    static var ttlOneMinute: String {
        String(localized: "credential_ttl_1m", defaultValue: "1 minute", bundle: .module)
    }

    static var ttlFiveMinutes: String {
        String(localized: "credential_ttl_5m", defaultValue: "5 minutes", bundle: .module)
    }

    static var ttlFifteenMinutes: String {
        String(localized: "credential_ttl_15m", defaultValue: "15 minutes", bundle: .module)
    }

    static var ttlOneHour: String {
        String(localized: "credential_ttl_1h", defaultValue: "1 hour", bundle: .module)
    }

    static func ttlSeconds(_ n: Int) -> String {
        String(localized: "credential_ttl_seconds", defaultValue: "\(n) seconds", bundle: .module)
    }

    static var sectionProtect: String {
        String(localized: "credential_section_protect", defaultValue: "Protection", bundle: .module)
    }

    static var changePassword: String {
        String(localized: "credential_change_password", defaultValue: "Change password", bundle: .module)
    }

    static var backupSupportingOn: String {
        String(localized: "credential_backup_supporting_on", defaultValue: "Your vault keeps a sealed copy for recovery", bundle: .module)
    }

    static var backupSupportingOff: String {
        String(
            localized: "credential_backup_supporting_off",
            defaultValue: "No recovery: only this phone holds your credential",
            bundle: .module
        )
    }

    static var backupOffTitle: String {
        String(localized: "credential_backup_off_title", defaultValue: "Turn the sealed backup off?", bundle: .module)
    }

    static var backupOffBody: String {
        String(
            localized: "credential_backup_off_body",
            defaultValue: """
                If this phone is lost, broken, reset or replaced without a transfer, your vault <b>cannot be \
                recovered</b>. It can only be deleted and replaced by a new one, and <b>everything in it is lost</b>.
                """,
            bundle: .module
        )
    }

    static var backupOffAck: String {
        String(
            localized: "credential_backup_off_ack",
            defaultValue: "I understand that without this phone my vault cannot be recovered",
            bundle: .module
        )
    }

    static var backupOffConfirm: String {
        String(localized: "credential_backup_off_confirm", defaultValue: "Turn off", bundle: .module)
    }

    static var backupOnDone: String {
        String(
            localized: "credential_backup_on_done",
            defaultValue: "The backup is on. Confirm with your PIN and password now: recovery is possible from then on.",
            bundle: .module
        )
    }

    static var backupOffNotice: String {
        String(
            localized: "credential_backup_off_notice",
            defaultValue: """
                No recovery: if this phone is lost, broken, reset or replaced without a transfer, your vault cannot be \
                recovered.
                """,
            bundle: .module
        )
    }

    static var backupOffDone: String {
        String(localized: "credential_backup_off_done", defaultValue: "The sealed backup is off.", bundle: .module)
    }

    static var passwordLabel: String {
        String(localized: "credential_password_label", defaultValue: "Credential password", bundle: .module)
    }

    static var passwordCurrent: String {
        String(localized: "credential_password_current", defaultValue: "Current password", bundle: .module)
    }

    static var passwordNew: String {
        String(localized: "credential_password_new", defaultValue: "New password", bundle: .module)
    }

    static var passwordConfirm: String {
        String(localized: "credential_password_confirm", defaultValue: "New password again", bundle: .module)
    }

    static var passwordMismatch: String {
        String(localized: "credential_password_mismatch", defaultValue: "The passwords do not match.", bundle: .module)
    }

    static var passwordSame: String {
        String(localized: "credential_password_same", defaultValue: "Choose a password different from the current one.", bundle: .module)
    }

    static var windowDialogTitle: String {
        String(localized: "credential_window_dialog_title", defaultValue: "Open the unlock window", bundle: .module)
    }

    static var windowDialogBody: String {
        String(localized: "credential_window_dialog_body", defaultValue: "Enter your credential password.", bundle: .module)
    }

    static var open: String {
        String(localized: "credential_open", defaultValue: "Open", bundle: .module)
    }

    static var cancel: String {
        String(localized: "credential_cancel", defaultValue: "Cancel", bundle: .module)
    }

    static var changeTitle: String {
        String(localized: "credential_change_title", defaultValue: "Change your credential password", bundle: .module)
    }

    static var changeBody: String {
        String(
            localized: "credential_change_body",
            defaultValue: "Your credential is sealed again under the new password. Nobody, VettID included, can reset it, so keep it safe.",
            bundle: .module
        )
    }

    static var changeSubmit: String {
        String(localized: "credential_change_submit", defaultValue: "Change password", bundle: .module)
    }

    static var changeDone: String {
        String(localized: "credential_change_done", defaultValue: "Your credential password was changed.", bundle: .module)
    }

    static var alarmCardTitle: String {
        String(localized: "credential_alarm_card_title", defaultValue: "Credential alert", bundle: .module)
    }

    static var alarmCardFrozen: String {
        String(
            localized: "credential_alarm_card_frozen",
            defaultValue: "Another copy of your credential was presented. Credential use is frozen until you answer.",
            bundle: .module
        )
    }

    static var alarmCardRotate: String {
        String(localized: "credential_alarm_card_rotate", defaultValue: "Rotate your credential to end the alert.", bundle: .module)
    }

    static var done: String {
        String(localized: "credential_done", defaultValue: "Done", bundle: .module)
    }

    static var changePin: String {
        String(localized: "credential_change_pin", defaultValue: "Vault PIN", bundle: .module)
    }

    // ANDROID-PLAN 0.1.45 "A lost answer to a PIN or password change" (VAULT-MESSAGING §11.14.9), shared with the
    // Android app.

    static var passwordChecking: String {
        String(
            localized: "credential_password_checking",
            defaultValue: """
                Your vault hasn't answered yet, so VettID is checking whether your password was changed. Keep your new \
                password at hand.
                """,
            bundle: .module
        )
    }

    /// VAULT-MESSAGING 0.45.0 §11.14.9 step 3 (shared with the Android app): the check ended without a decision.
    static var passwordEnded: String {
        String(
            localized: "credential_change_ended",
            defaultValue: """
                VettID couldn't confirm whether your password was changed, because something else changed in your vault at \
                the same time. Either your previous or your new password may be the current one.
                """,
            bundle: .module
        )
    }

    static var passwordNotChanged: String {
        String(
            localized: "credential_password_not_changed", defaultValue: "Your password was not changed. You can try again.",
            bundle: .module
        )
    }

    static var passwordUnreachable: String {
        String(
            localized: "credential_password_unreachable",
            defaultValue: """
                VettID can't reach your vault right now, so it doesn't know yet whether your password was changed. It will \
                check as soon as it can. Keep both your old and your new password at hand.
                """,
            bundle: .module
        )
    }
}
