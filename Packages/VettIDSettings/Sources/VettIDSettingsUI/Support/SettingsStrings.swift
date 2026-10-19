import Foundation

// The package's texts, from `Resources/Localizable.xcstrings`. Keys are vettid-android's (`feature/settings`
// `strings.xml` and `strings_owner_check.xml`), the English values the same, word for word; `ios_` keys are the
// iPhone's own (Face ID, Touch ID and the passcode where Android names its phone's; IOS-PLAN ID15 and §14).

/// The Settings screen's texts and the owner-check rows'.
enum SettingsStrings {
    static var title: String {
        String(localized: "settings_title", defaultValue: "Settings", bundle: .module)
    }

    static var sectionVault: String {
        String(localized: "settings_section_vault", defaultValue: "Vault", bundle: .module)
    }

    static var vaultUpdate: String {
        String(localized: "settings_vault_update", defaultValue: "Update available", bundle: .module)
    }

    static func vaultUpdateBody(_ release: Int, _ current: Int) -> String {
        String(
            localized: "settings_vault_update_body", defaultValue: "Release \(release) (your vault runs release \(current))",
            bundle: .module
        )
    }

    static var vaultStatus: String {
        String(localized: "settings_vault_status", defaultValue: "Vault status", bundle: .module)
    }

    static var vaultLock: String {
        String(localized: "settings_vault_lock", defaultValue: "Lock vault", bundle: .module)
    }

    static var vaultLockBody: String {
        String(
            localized: "settings_vault_lock_body",
            defaultValue: "Locks your vault now. You need your PIN to open it again.",
            bundle: .module
        )
    }

    static var sectionSecurity: String {
        String(localized: "settings_section_security", defaultValue: "Security", bundle: .module)
    }

    static var securityAttestation: String {
        String(localized: "settings_security_attestation", defaultValue: "Attestation", bundle: .module)
    }

    static var securityAppLock: String {
        String(localized: "settings_security_app_lock", defaultValue: "App lock", bundle: .module)
    }

    static var securityLockMethod: String {
        String(localized: "settings_security_lock_method", defaultValue: "Unlock with", bundle: .module)
    }

    static var lockMethodNote: String {
        String(
            localized: "settings_lock_method_note",
            defaultValue: """
                The app lock only keeps others out of VettID on this phone. It never replaces your vault PIN or credential \
                password.
                """,
            bundle: .module
        )
    }

    static var securityLockTimeout: String {
        String(localized: "settings_security_lock_timeout", defaultValue: "Lock after", bundle: .module)
    }

    static var timeoutImmediately: String {
        String(localized: "settings_timeout_immediately", defaultValue: "Immediately", bundle: .module)
    }

    static var timeoutOneMinute: String {
        String(localized: "settings_timeout_1min", defaultValue: "1 minute", bundle: .module)
    }

    static var timeoutFiveMinutes: String {
        String(localized: "settings_timeout_5min", defaultValue: "5 minutes", bundle: .module)
    }

    static var timeoutFifteenMinutes: String {
        String(localized: "settings_timeout_15min", defaultValue: "15 minutes", bundle: .module)
    }

    static var timeoutOneHour: String {
        String(localized: "settings_timeout_1h", defaultValue: "1 hour", bundle: .module)
    }

    static var sectionAccount: String {
        String(localized: "settings_section_account", defaultValue: "Account", bundle: .module)
    }

    static var accountSite: String {
        String(localized: "settings_account_site", defaultValue: "Account site", bundle: .module)
    }

    static var accountDetail: String {
        String(localized: "settings_account_detail", defaultValue: "Membership and subscription", bundle: .module)
    }

    static var accountMember: String {
        String(localized: "settings_account_member", defaultValue: "Member", bundle: .module)
    }

    static var accountRegistered: String {
        String(localized: "settings_account_registered", defaultValue: "Registered, not yet a member", bundle: .module)
    }

    static var accountCanceled: String {
        String(localized: "settings_account_canceled", defaultValue: "Account cancelled", bundle: .module)
    }

    static var cancel: String {
        String(localized: "settings_cancel", defaultValue: "Cancel", bundle: .module)
    }

    static var done: String {
        String(localized: "settings_done", defaultValue: "Done", bundle: .module)
    }

    static var retry: String {
        String(localized: "settings_retry", defaultValue: "Try again", bundle: .module)
    }

    static var loading: String {
        String(localized: "settings_loading", defaultValue: "Loading", bundle: .module)
    }

    static var unknown: String {
        String(localized: "settings_unknown", defaultValue: "Unknown", bundle: .module)
    }

    static var yes: String {
        String(localized: "settings_yes", defaultValue: "Yes", bundle: .module)
    }

    static var no: String {
        String(localized: "settings_no", defaultValue: "No", bundle: .module)
    }

    static var securityAppLockBody: String {
        String(
            localized: "ios_settings_security_app_lock_body",
            defaultValue: "Ask for Face ID or Touch ID when opening VettID",
            bundle: .module
        )
    }

    static var securityAppLockBodyPasscode: String {
        String(
            localized: "ios_settings_security_app_lock_body_passcode",
            defaultValue: "Ask for the iPhone passcode when opening VettID",
            bundle: .module
        )
    }

    static var lockMethodBiometrics: String {
        String(localized: "ios_settings_lock_method_biometrics", defaultValue: "Face ID or Touch ID", bundle: .module)
    }

    static var lockMethodBiometricsBody: String {
        String(
            localized: "ios_settings_lock_method_biometrics_body",
            defaultValue: "Face ID or Touch ID only. If they stop working, unlock your iPhone with its passcode and try again.",
            bundle: .module
        )
    }

    static var lockMethodPasscode: String {
        String(localized: "ios_settings_lock_method_passcode", defaultValue: "iPhone passcode", bundle: .module)
    }

    static var lockMethodPasscodeBody: String {
        String(
            localized: "ios_settings_lock_method_passcode_body",
            defaultValue: "The iPhone passcode only, never Face ID or Touch ID",
            bundle: .module
        )
    }

    static var securityAppLockInvalidated: String {
        String(
            localized: "ios_settings_security_app_lock_invalidated",
            defaultValue: "The app lock was turned off because Face ID or Touch ID changed on this iPhone. Turn it on again if you like.",
            bundle: .module
        )
    }

    static var appLockUsePasscode: String {
        String(
            localized: "ios_app_lock_use_passcode",
            defaultValue: """
                Face ID and Touch ID are not set up on this iPhone. Choose iPhone passcode under Unlock with to use the \
                app lock with the passcode.
                """,
            bundle: .module
        )
    }

    static var appLockEnableFailed: String {
        String(
            localized: "ios_app_lock_enable_failed",
            defaultValue: "The app lock cannot be used on this iPhone (it needs Face ID, Touch ID or a passcode).",
            bundle: .module
        )
    }

    static var ownerCheck: String {
        String(localized: "settings_owner_check", defaultValue: "Daily check", bundle: .module)
    }

    static func ownerCheckEvery(_ n: Int) -> String {
        String(localized: "settings_owner_check_every", defaultValue: "Every \(n) hours", bundle: .module)
    }

    static func ownerCheckNext(_ s: String) -> String {
        String(localized: "settings_owner_check_next", defaultValue: "next by \(s)", bundle: .module)
    }

    static var ownerCheckNow: String {
        String(localized: "settings_owner_check_now", defaultValue: "Check now", bundle: .module)
    }

    static var ownerCheckNowBody: String {
        String(
            localized: "settings_owner_check_now_body",
            defaultValue: "Your PIN and your credential password together; resets the clock",
            bundle: .module
        )
    }

    static var ownerCheckHold: String {
        String(localized: "settings_owner_check_hold", defaultValue: "Hold the vault when a check is late", bundle: .module)
    }

    static var ownerCheckHoldOnBody: String {
        String(
            localized: "settings_owner_check_hold_on_body",
            defaultValue: "On: a late check pauses your desktops, agents and calls until you check",
            bundle: .module
        )
    }

    static var ownerCheckHoldOffBody: String {
        String(
            localized: "settings_owner_check_hold_off_body",
            defaultValue: "Off until you turn it back on. Turning it off needs a check.",
            bundle: .module
        )
    }

    static func ownerCheckHoldOffUntil(_ s: String) -> String {
        String(localized: "settings_owner_check_hold_off_until", defaultValue: "Off until \(s)", bundle: .module)
    }

    static var ownerCheckOfferTitle: String {
        String(localized: "settings_owner_check_offer_title", defaultValue: "Check now?", bundle: .module)
    }

    static var ownerCheckOfferBody: String {
        String(
            localized: "settings_owner_check_offer_body",
            defaultValue: "A shorter interval can put your vault on hold at once. A check now starts the new interval from now.",
            bundle: .module
        )
    }
}
