import Foundation

/// The PIN change's texts and the Settings rows of IOS-PLAN §8 I1.8b (vettid-android `feature/settings` `strings.xml`, word
/// for word; `ios_` keys are the iPhone's own: the keypad's steps).
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

    static var pinUnanswered: String {
        String(
            localized: "ios_settings_pin_unanswered",
            defaultValue: """
                Your vault did not answer, so your PIN may already be the new one. Lock your vault and unlock it with the \
                new PIN. If the new PIN does not work, unlock with your current PIN and try again.
                """,
            bundle: .module
        )
    }
}
