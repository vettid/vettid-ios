import Foundation

// The texts of a lost answer to a PIN or password change (ANDROID-PLAN 0.1.45 "A lost answer to a PIN or password
// change", VAULT-MESSAGING §11.14.9), shared with the Android app.
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

    /// IOS-PLAN §14 draft (iPhone only, chosen; not in the spec: ANDROID-PLAN 0.1.45 has no text for it): another action
    /// while a change is undecided and the vault answers.
    static var failureChangeChecking: String {
        String(
            localized: "data_failure_ios_change_checking",
            defaultValue: "VettID is still checking whether your last change went through. Try again in a few minutes.",
            bundle: .module
        )
    }
}
