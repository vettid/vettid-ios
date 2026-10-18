import Foundation

/// The PIN change's texts and the Settings rows of IOS-PLAN §8 I1.8b (vettid-android `feature/settings` `strings.xml`, word
/// for word; `ios_` keys are the iPhone's own: the keypad's steps). The lost-answer texts are ANDROID-PLAN 0.1.45's.
enum PinStrings {
    static var vaultPin: String {
        String(localized: "settings_vault_pin", defaultValue: "Change vault PIN", bundle: .module)
    }

    static var securityCredential: String {
        String(localized: "settings_security_credential", defaultValue: "Credential", bundle: .module)
    }

    static var securityCredentialBody: String {
        String(localized: "settings_security_credential_body", defaultValue: "Password, rotation, backup, unlock window", bundle: .module)
    }

    static var pinTitle: String {
        String(localized: "settings_pin_title", defaultValue: "Change your vault PIN", bundle: .module)
    }

    static var pinBody: String {
        String(
            localized: "settings_pin_body",
            defaultValue: "Your vault re-derives its key from the new PIN. Use at least 6 digits.",
            bundle: .module
        )
    }

    static var pinCurrent: String {
        String(localized: "settings_pin_current", defaultValue: "Current PIN", bundle: .module)
    }

    static var pinNew: String {
        String(localized: "settings_pin_new", defaultValue: "New PIN", bundle: .module)
    }

    static var pinConfirm: String {
        String(localized: "settings_pin_confirm", defaultValue: "New PIN again", bundle: .module)
    }

    static var pinMismatch: String {
        String(localized: "settings_pin_mismatch", defaultValue: "The PINs do not match.", bundle: .module)
    }

    static var pinSame: String {
        String(localized: "settings_pin_same", defaultValue: "Choose a PIN different from the current one.", bundle: .module)
    }

    static var pinSubmit: String {
        String(localized: "settings_pin_submit", defaultValue: "Change PIN", bundle: .module)
    }

    static var pinDone: String {
        String(localized: "settings_pin_done", defaultValue: "Your vault PIN was changed.", bundle: .module)
    }

    static var pinPassword: String {
        String(localized: "settings_pin_password", defaultValue: "Credential password", bundle: .module)
    }

    static var pinDoneRecovery: String {
        String(
            localized: "settings_pin_done_recovery",
            defaultValue: "Your PIN was changed. Your vault's recovery now has 10 new attempts for the new PIN and your password.",
            bundle: .module
        )
    }

    static var pinPasswordToo: String {
        String(
            localized: "settings_pin_password_too",
            defaultValue: "Changing only the PIN gives whoever is guessing ten new tries at the same password. Change your password too.",
            bundle: .module
        )
    }

    static var pinContinue: String {
        String(localized: "ios_settings_pin_continue", defaultValue: "Continue", bundle: .module)
    }

    // ANDROID-PLAN 0.1.45 "A lost answer to a PIN or password change" (VAULT-MESSAGING §11.14.9), shared with the
    // Android app.

    static var pinChecking: String {
        String(
            localized: "settings_pin_checking",
            defaultValue: """
                Your vault hasn't answered yet, so VettID is checking whether your PIN was changed. Keep your new PIN at hand.
                """,
            bundle: .module
        )
    }

    static var pinNotChanged: String {
        String(localized: "settings_pin_not_changed", defaultValue: "Your PIN was not changed. You can try again.", bundle: .module)
    }

    static var pinUnreachable: String {
        String(
            localized: "settings_pin_unreachable",
            defaultValue: """
                VettID can't reach your vault right now, so it doesn't know yet whether your PIN was changed. It will check \
                as soon as it can. Keep both your old and your new PIN at hand.
                """,
            bundle: .module
        )
    }
}
