import Foundation

// The texts of a lost answer to a PIN or password change (ANDROID-PLAN 0.1.45 and 0.1.46 "A lost answer to a PIN or
// password change", VAULT-MESSAGING §11.14.9), shared with the Android app.
extension DataStrings {
    /// ANDROID-PLAN 0.1.45 "A lost answer to a PIN or password change": another action while a change is unresolved and
    /// the vault cannot be reached (shared with the Android app).
    static var failureChangeUnresolved: String {
        String(
            localized: "data_failure_change_unresolved",
            defaultValue: """
                VettID is still checking whether your last change went through. Try again when your vault can be reached.
                """,
            bundle: .module
        )
    }

    /// VAULT-MESSAGING 0.45.0 §11.14.9 step 2 "The gate", ANDROID-PLAN 0.1.46 (shared with the Android app): another
    /// action while a PIN change is undecided and the vault answers.
    static var failureChangeChecking: String {
        String(
            localized: "data_failure_change_undecided",
            defaultValue: """
                VettID is still checking whether your last PIN change went through. This can take up to about 10 minutes. \
                Try again then.
                """,
            bundle: .module
        )
    }

    /// The same, after a password change (shared with the Android app).
    static var failureChangeCheckingPassword: String {
        String(
            localized: "data_failure_change_undecided_password",
            defaultValue: """
                VettID is still checking whether your last password change went through. This can take up to about 10 \
                minutes. Try again then.
                """,
            bundle: .module
        )
    }

    /// VAULT-MESSAGING 0.45.0 §11.14.9 step 1 (shared with the Android app): a change refused with nothing sent while an
    /// earlier credential operation is not settled.
    static var failureCredentialUnsettled: String {
        String(
            localized: "data_failure_credential_unsettled",
            defaultValue: "VettID is still finishing an earlier request to your vault. Nothing was changed. Try again in a minute.",
            bundle: .module
        )
    }

    /// VAULT-MESSAGING 0.45.0 §11.14.9 step 3 (shared with the Android app): an operation that carries the PIN while the
    /// PIN is uncertain.
    static var failurePinUncertain: String {
        String(
            localized: "data_failure_pin_uncertain",
            defaultValue: """
                VettID couldn't confirm whether your PIN was changed, because something else changed in your vault at the \
                same time. To find out without using an attempt, lock your vault and unlock it again: VettID will ask for \
                each PIN in turn.
                """,
            bundle: .module
        )
    }

    /// VAULT-MESSAGING 0.46.0 §11.14.9 step 1, ANDROID-PLAN 0.1.47 (shared with the Android app): a PIN change while a new
    /// phone secret whose answer was lost cannot be decided.
    static var failureRenewUnconfirmed: String {
        String(
            localized: "data_failure_renew_unconfirmed",
            defaultValue: """
                VettID couldn't confirm your last new phone secret. Before you change your PIN, lock your vault and unlock \
                it again: your PIN hasn't changed, so this doesn't use an attempt.
                """,
            bundle: .module
        )
    }
}
