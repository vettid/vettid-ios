import Foundation

/// New phone secret, Allow screenshots and Delete vault (vettid-android `feature/settings` `strings.xml`, word for word;
/// `ios_` keys are the iPhone's own: what Allow screenshots does on an iPhone, IOS-PLAN §4, and a deletion whose answer
/// was lost).
enum SecurityStrings {
    // MARK: - New phone secret (release R, VAULT-MESSAGING §11.14.9)

    static var newSecret: String {
        String(localized: "settings_security_new_secret", defaultValue: "New phone secret", bundle: .module)
    }

    static var newSecretRowBody: String {
        String(
            localized: "settings_security_new_secret_body", defaultValue: "If you fear that something ran as VettID on this phone",
            bundle: .module
        )
    }

    static var newSecretBody: String {
        String(
            localized: "settings_new_secret_body",
            defaultValue: """
                Your vault gives this phone a new secret. Your PIN stays the same, and the old secret opens nothing your \
                vault stores from now on. Enter your PIN and your password.
                """,
            bundle: .module
        )
    }

    static var newSecretNotEnough: String {
        String(
            localized: "settings_new_secret_not_enough",
            defaultValue: """
                If something ran as VettID on this phone, a new secret alone is not enough: move your vault to another \
                phone, or recover it.
                """,
            bundle: .module
        )
    }

    static var newSecretSubmit: String {
        String(localized: "settings_new_secret_submit", defaultValue: "Make a new secret", bundle: .module)
    }

    static var newSecretDone: String {
        String(localized: "settings_new_secret_done", defaultValue: "Your phone now uses a new secret for this vault.", bundle: .module)
    }

    // MARK: - Allow screenshots (IOS-PLAN §4)

    static var sectionApp: String {
        String(localized: "settings_section_app", defaultValue: "App", bundle: .module)
    }

    static var screenshots: String {
        String(localized: "settings_app_screenshots", defaultValue: "Allow screenshots", bundle: .module)
    }

    /// vettid-android's "app preview in Recents" has no iPhone counterpart: the app switcher's cover and capture hiding
    /// stay whatever this says (IOS-PLAN §4, §6.4).
    static var screenshotsOff: String {
        String(
            localized: "ios_settings_app_screenshots_off",
            defaultValue: "Off. Screens that hold your secrets are left out of screenshots.",
            bundle: .module
        )
    }

    static var screenshotsOn: String {
        String(
            localized: "settings_app_screenshots_on", defaultValue: "On. Turns itself off when the vault locks, and after 1 hour.",
            bundle: .module
        )
    }

    static var screenshotsOnDevelopment: String {
        String(
            localized: "settings_app_screenshots_on_development",
            defaultValue: "On. A development build: it stays on until you turn it off.",
            bundle: .module
        )
    }

    static var screenshotsConfirmTitle: String {
        String(localized: "settings_app_screenshots_confirm_title", defaultValue: "Allow screenshots?", bundle: .module)
    }

    static var screenshotsConfirmBody: String {
        String(
            localized: "ios_settings_app_screenshots_confirm_body",
            defaultValue: """
                Screenshots will show whatever is on screen, including messages and vault items. Anyone you show or send \
                them to sees the same. Screen recording and sharing stay hidden, and the app switcher still shows only the \
                VettID cover.

                This turns itself off when the vault locks, and after 1 hour. The screen for typing a recovery code stays \
                protected.
                """,
            bundle: .module
        )
    }

    static var screenshotsConfirm: String {
        String(localized: "settings_app_screenshots_confirm", defaultValue: "Allow screenshots", bundle: .module)
    }

    // MARK: - Delete vault (VAULT-MESSAGING §12.5)

    static var deleteVault: String {
        String(localized: "settings_delete_vault", defaultValue: "Delete vault", bundle: .module)
    }

    static var deleteVaultBody: String {
        String(localized: "settings_delete_vault_body", defaultValue: "Erase your vault and everything in it", bundle: .module)
    }

    static var deleteTitle: String {
        String(localized: "settings_delete_title", defaultValue: "Delete your vault", bundle: .module)
    }

    static var deleteBody: String {
        String(
            localized: "settings_delete_body",
            defaultValue: """
                This erases your vault for good: your messages, connections, items, critical items and Protean Credential. \
                Your connections are told the connection ended. It cannot be undone, and VettID cannot restore it.
                """,
            bundle: .module
        )
    }

    static var deletePhraseLabel: String {
        String(localized: "settings_delete_phrase_label", defaultValue: "Type: delete my vault", bundle: .module)
    }

    static var deletePhraseWrong: String {
        String(localized: "settings_delete_phrase_wrong", defaultValue: "Type the phrase exactly: delete my vault", bundle: .module)
    }

    static var deletePin: String {
        String(localized: "settings_delete_pin", defaultValue: "Vault PIN", bundle: .module)
    }

    static var deletePassword: String {
        String(localized: "settings_delete_password", defaultValue: "Credential password", bundle: .module)
    }

    static var deleteAck: String {
        String(
            localized: "settings_delete_ack",
            defaultValue: "I understand that my vault and everything in it will be erased and cannot be restored",
            bundle: .module
        )
    }

    static var deleteSubmit: String {
        String(localized: "settings_delete_submit", defaultValue: "Delete my vault", bundle: .module)
    }

    static var deleteConfirmTitle: String {
        String(localized: "settings_delete_confirm_title", defaultValue: "Delete your vault now?", bundle: .module)
    }

    static var deleteConfirmBody: String {
        String(
            localized: "settings_delete_confirm_body", defaultValue: "This is the last step. Your vault is erased immediately.",
            bundle: .module
        )
    }

    static var deleteConfirm: String {
        String(localized: "settings_delete_confirm", defaultValue: "Delete forever", bundle: .module)
    }

    static var deleteUnconfirmed: String {
        String(
            localized: "ios_settings_delete_unconfirmed",
            defaultValue: """
                Your vault did not answer, so this phone can't tell yet whether it was deleted. Check again in a moment. \
                VettID's data stays on this phone until the deletion is confirmed.
                """,
            bundle: .module
        )
    }

    static var deleteNotDeleted: String {
        String(
            localized: "ios_settings_delete_not_deleted", defaultValue: "Your vault was not deleted. You can try again.", bundle: .module
        )
    }

    static var deleteCheckAgain: String {
        String(localized: "ios_settings_delete_check_again", defaultValue: "Check again", bundle: .module)
    }
}
