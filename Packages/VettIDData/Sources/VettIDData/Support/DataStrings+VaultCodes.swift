import Foundation

// The texts of the vault error codes the app did not map (IOS-PLAN §4.4, §4.5; ANDROID-PLAN 0.1.57 §4 "Vault error codes
// the app does not map"), approved by the owner (2026-10-20) and shared with the Android app.

extension DataStrings {
    /// "Your vault moved to a new phone": the title of `vault_not_holder` and of the notices that say another phone became
    /// the holder (vettid-android `data_feed_device_replaced`).
    static var feedDeviceReplaced: String {
        String(localized: "data_feed_device_replaced", defaultValue: "Your vault moved to a new phone", bundle: .module)
    }
    static var notHolder: String {
        String(
            localized: "vault_not_holder",
            defaultValue: """
                Another phone now holds your vault's credential, so this phone can't do this. Nothing was disclosed. Use VettID \
                on the phone that holds it now. If you no longer have that phone, start a recovery on the account site.
                """,
            bundle: .module
        )
    }
    static var credentialRequiredTitle: String {
        String(localized: "vault_credential_required_title", defaultValue: "This phone can't use your vault", bundle: .module)
    }
    static var credentialRequiredBody: String {
        String(
            localized: "vault_credential_required_body",
            defaultValue: """
                Your vault does not count this phone as the one that holds its credential, so it refused the request. Nothing \
                was disclosed, and your PIN and password were not checked. This usually means a recovery of your vault was \
                started and has not finished. If you recovered your vault on another phone, open VettID on that phone and \
                unlock it to finish. Otherwise, start a recovery on the account site: it takes one to three days, and you \
                need your PIN and your password. If another phone of yours now opens your vault, use 'Move to a new phone' \
                there instead.
                """,
            bundle: .module
        )
    }
    /// ``credentialRequiredBody`` on a scaled vault (STAGING-TIME-SCALE §5.2): [from] and [to], a recovery's shortest and
    /// longest time at the vault's time scale, as ``failureDeviceSecretScaled`` says them. The key is chosen; not in the
    /// spec.
    static func credentialRequiredBodyScaled(_ from: String, _ to: String) -> String {
        String(
            localized: "vault_credential_required_body_scaled",
            defaultValue: """
                Your vault does not count this phone as the one that holds its credential, so it refused the request. Nothing \
                was disclosed, and your PIN and password were not checked. This usually means a recovery of your vault was \
                started and has not finished. If you recovered your vault on another phone, open VettID on that phone and \
                unlock it to finish. Otherwise, start a recovery on the account site: it takes \(from) to \(to), and you \
                need your PIN and your password. If another phone of yours now opens your vault, use 'Move to a new phone' \
                there instead.
                """,
            bundle: .module
        )
    }
    /// [code] is already checked (``VaultFailures/shownCode(_:)``).
    static func errorVaultCode(_ code: String) -> String {
        String(
            localized: "error_vault_code",
            defaultValue: """
                Something went wrong (code: \(code)). Try again. If it keeps happening, contact VettID and give this code.
                """,
            bundle: .module
        )
    }
}
