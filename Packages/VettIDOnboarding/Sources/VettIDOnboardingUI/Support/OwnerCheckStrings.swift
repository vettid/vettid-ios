import Foundation

// The owner-check screen (vettid-android `feature/onboarding` `strings_owner_check.xml`), the app lock's screen
// (`strings.xml` `app_lock_*`), and the way out of a wipe that did not finish (the app's `root_clear_data*`), word for
// word; the iPhone's own texts (`ios_`) where Android names its phone's settings.
extension OnboardingStrings {
    static var ownerCheckTitleGated: String {
        String(localized: "ownercheck_title_gated", defaultValue: "Daily check", bundle: .module)
    }
    static func ownerCheckBodyGated(_ interval: String) -> String {
        String(
            localized: "ownercheck_body_gated",
            defaultValue: """
                Your vault asks for your PIN and your credential password together at least once every \(interval). \
                Until you check, the app shows nothing from your vault.
                """,
            bundle: .module
        )
    }
    static var ownerCheckTitleVoluntary: String {
        String(localized: "ownercheck_title_voluntary", defaultValue: "Check now", bundle: .module)
    }
    static func ownerCheckBodyVoluntary(_ interval: String) -> String {
        String(
            localized: "ownercheck_body_voluntary",
            defaultValue: "Enter your PIN and your credential password. Your next check is then due \(interval) from now.",
            bundle: .module
        )
    }
    static var ownerCheckTitleHoldOff: String {
        String(localized: "ownercheck_title_hold_off", defaultValue: "Turn the hold off", bundle: .module)
    }
    static var ownerCheckBodyHoldOff: String {
        String(
            localized: "ownercheck_body_hold_off",
            defaultValue: "Turning the hold off is part of a check: enter your PIN and your credential password.",
            bundle: .module
        )
    }
    static var ownerCheckHoldOffWarningTitle: String {
        String(localized: "ownercheck_hold_off_warning_title", defaultValue: "What this gives up", bundle: .module)
    }
    static var ownerCheckHoldOffWarning: String {
        String(
            localized: "ownercheck_hold_off_warning",
            defaultValue: """
                When a check is late, your vault normally holds: your desktops and agents stop, calls do not ring and you \
                do not appear online. With the hold off they keep running until the hold is back on, your vault locks or \
                you check. Someone with your unlocked phone could keep a desktop or agent working for you. This phone \
                still asks for the check before you can use it.
                """,
            bundle: .module
        )
    }
    static var ownerCheckHoldOffUntil: String {
        String(localized: "ownercheck_hold_off_until", defaultValue: "Turn the hold back on", bundle: .module)
    }
    static var ownerCheckHoldOffNever: String {
        String(localized: "ownercheck_hold_off_never", defaultValue: "When I turn it back on", bundle: .module)
    }
    static var ownerCheckHoldOff1d: String {
        String(localized: "ownercheck_hold_off_1d", defaultValue: "After 1 day", bundle: .module)
    }
    static var ownerCheckHoldOff3d: String {
        String(localized: "ownercheck_hold_off_3d", defaultValue: "After 3 days", bundle: .module)
    }
    static var ownerCheckHoldOff1w: String {
        String(localized: "ownercheck_hold_off_1w", defaultValue: "After 1 week", bundle: .module)
    }
    static var ownerCheckHoldOff30d: String {
        String(localized: "ownercheck_hold_off_30d", defaultValue: "After 30 days", bundle: .module)
    }
    static var ownerCheckWaitingTitle: String {
        String(localized: "ownercheck_waiting_title", defaultValue: "Waiting in your vault", bundle: .module)
    }
    static func ownerCheckWaitingMessages(_ n: Int) -> String {
        String(localized: "ownercheck_waiting_messages", defaultValue: "\(n) new messages", bundle: .module)
    }
    static func ownerCheckWaitingRequests(_ n: Int) -> String {
        String(localized: "ownercheck_waiting_requests", defaultValue: "\(n) connection requests", bundle: .module)
    }
    static func ownerCheckWaitingCalls(_ n: Int) -> String {
        String(localized: "ownercheck_waiting_calls", defaultValue: "\(n) missed calls", bundle: .module)
    }
    static func ownerCheckWaitingOther(_ n: Int) -> String {
        String(localized: "ownercheck_waiting_other", defaultValue: "\(n) other updates", bundle: .module)
    }
    static var ownerCheckWaitingNone: String {
        String(localized: "ownercheck_waiting_none", defaultValue: "Nothing new has arrived since your check was due.", bundle: .module)
    }
    static var ownerCheckWaitingUnknown: String {
        String(
            localized: "ownercheck_waiting_unknown",
            defaultValue: "Checking what is waiting… Something may have arrived since your check was due; your vault has not said yet.",
            bundle: .module
        )
    }
    static var ownerCheckHeldNote: String {
        String(
            localized: "ownercheck_held_note",
            defaultValue: """
                Your vault is held: it keeps receiving for you, but your desktops and agents wait for your check and calls \
                do not ring.
                """,
            bundle: .module
        )
    }
    static var ownerCheckDueNote: String {
        String(
            localized: "ownercheck_due_note",
            defaultValue: "The hold is off: your desktops and agents keep running. This phone needs the check first.",
            bundle: .module
        )
    }
    static var ownerCheckPinLabel: String {
        String(localized: "ownercheck_pin_label", defaultValue: "Vault PIN", bundle: .module)
    }
    static var ownerCheckPasswordLabel: String {
        String(localized: "ownercheck_password_label", defaultValue: "Credential password", bundle: .module)
    }
    static var ownerCheckBadPin: String {
        String(localized: "ownercheck_bad_pin", defaultValue: "Wrong PIN.", bundle: .module)
    }
    static var ownerCheckBadPassword: String {
        String(localized: "ownercheck_bad_password", defaultValue: "Wrong credential password.", bundle: .module)
    }
    static func ownerCheckChecksLeft(_ n: Int) -> String {
        String(localized: "ownercheck_checks_left", defaultValue: "\(n) wrong checks left before your vault locks.", bundle: .module)
    }
    static func ownerCheckBackoffWait(_ wait: String) -> String {
        String(localized: "ownercheck_backoff_wait", defaultValue: "Too many wrong entries. Try again in \(wait).", bundle: .module)
    }
    static var ownerCheckBackoff: String {
        String(
            localized: "ownercheck_backoff", defaultValue: "Too many wrong entries. Wait a few minutes, then try again.", bundle: .module
        )
    }
    static var ownerCheckSubmit: String {
        String(localized: "ownercheck_submit", defaultValue: "Check", bundle: .module)
    }
    static var ownerCheckSubmitHoldOff: String {
        String(localized: "ownercheck_submit_hold_off", defaultValue: "Check and turn the hold off", bundle: .module)
    }
    static var ownerCheckLock: String {
        String(localized: "ownercheck_lock", defaultValue: "Lock vault", bundle: .module)
    }
    static var ownerCheckCancel: String {
        String(localized: "ownercheck_cancel", defaultValue: "Cancel", bundle: .module)
    }
    static var ownerCheckPresenceTitle: String {
        String(localized: "ownercheck_presence_title", defaultValue: "Your vault could not record that you were here.", bundle: .module)
    }
    /// [quiet]: the recovery quiet period at the vault's time scale (STAGING-TIME-SCALE S7).
    static func ownerCheckPresenceBody(_ quiet: String) -> String {
        String(
            localized: "ownercheck_presence_body",
            defaultValue: """
                If this stays for \(quiet), your vault is no longer protected against a recovery started by someone \
                else. Try again later. If it does not go away, contact VettID.
                """,
            bundle: .module
        )
    }
}

// The app lock's screen (ANDROID-PLAN D6; IOS-PLAN ID17).
extension OnboardingStrings {
    static var appLockTitle: String {
        String(localized: "app_lock_title", defaultValue: "VettID is locked", bundle: .module)
    }
    /// iPhone: Face ID, Touch ID or the passcode (Android: "fingerprint, face or screen lock").
    static var appLockBody: String {
        String(
            localized: "ios_app_lock_body", defaultValue: "Use Face ID, Touch ID or your iPhone passcode to open VettID.", bundle: .module
        )
    }
    static var appLockBodyPasscode: String {
        String(localized: "ios_app_lock_body_passcode", defaultValue: "Use your iPhone passcode to open VettID.", bundle: .module)
    }
    /// iPhone: Face ID or Touch ID locked after too many attempts (not on Android, whose prompt offers the screen lock).
    static var appLockLockedOut: String {
        String(
            localized: "ios_app_lock_locked_out", defaultValue: "Unlock your iPhone with its passcode, then try again.", bundle: .module
        )
    }
    static var appLockUnlock: String {
        String(localized: "app_lock_unlock", defaultValue: "Unlock", bundle: .module)
    }
    /// What iOS shows in its prompt (`LAContext.localizedReason`).
    static var appLockPromptTitle: String {
        String(localized: "app_lock_prompt_title", defaultValue: "Unlock VettID", bundle: .module)
    }
}

// The way out of a wipe that did not finish (vettid-android `AppDataClear`).
extension OnboardingStrings {
    static var rootClearData: String {
        String(localized: "root_clear_data", defaultValue: "Erase VettID's data on this phone", bundle: .module)
    }
    static var rootClearDataTitle: String {
        String(localized: "root_clear_data_title", defaultValue: "Erase VettID's data?", bundle: .module)
    }
    /// iPhone: VettID cannot close itself, and starts afresh instead (Android: "… and closes VettID.").
    static var rootClearDataBody: String {
        String(
            localized: "ios_root_clear_data_body",
            defaultValue: "This removes everything VettID keeps on this iPhone. VettID then starts afresh.",
            bundle: .module
        )
    }
    static var rootClearDataConfirm: String {
        String(localized: "root_clear_data_confirm", defaultValue: "Erase", bundle: .module)
    }
    /// iPhone: there is no "storage" to clear in Settings; the app is removed and installed again.
    static var rootClearDataFailed: String {
        String(
            localized: "ios_root_clear_data_failed",
            defaultValue: "VettID could not erase its data. Remove VettID from this iPhone and install it again.",
            bundle: .module
        )
    }
}

/// The app lock's prompt text (`LAContext.localizedReason`), for the app's root.
public enum AppLockTexts {
    public static var reason: String { OnboardingStrings.appLockPromptTitle }
}
