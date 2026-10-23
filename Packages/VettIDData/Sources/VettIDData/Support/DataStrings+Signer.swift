import Foundation

// The texts of the confirmation a transfer asks for when it changes the vault's signer (VAULT-MESSAGING 0.27.0 §11.7.1;
// the wording is ANDROID-PLAN 0.1.36 §7 "What members are told", as vettid-android `settings_transfer_signer_*`). The vault
// names a class; the app supplies every word.
extension DataStrings {
    static func transferSignerBody(_ new: String, _ current: String) -> String {
        String(
            localized: "data_transfer_signer_body",
            defaultValue: "The new phone's VettID \(new); this one \(current). Continue only if you installed it yourself.",
            bundle: .module
        )
    }

    /// (chosen; not in the spec) The body when this phone has no signer to name (an iPhone, which App Attest reports none
    /// for): the vault compares the new Android app with the signer it kept for its last Android app (VAULT-MESSAGING
    /// §11.7.1 "Across an iOS app"), which this phone cannot see.
    static func transferSignerBodyIPhone(_ new: String) -> String {
        String(
            localized: "data_transfer_signer_body_iphone",
            defaultValue: """
                The new phone's VettID \(new). That is not the version your vault used on Android before. \
                Continue only if you installed it yourself.
                """,
            bundle: .module
        )
    }

    static var transferSignerNewGooglePlay: String {
        String(
            localized: "data_transfer_signer_new_google_play",
            defaultValue: "was installed from Google Play (signed by Google)",
            bundle: .module
        )
    }

    static var transferSignerNewVettid: String {
        String(
            localized: "data_transfer_signer_new_vettid",
            defaultValue: "was installed from F-Droid or direct (signed by VettID)",
            bundle: .module
        )
    }

    static var transferSignerNewDevelopment: String {
        String(localized: "data_transfer_signer_new_development", defaultValue: "is a development build", bundle: .module)
    }

    static var transferSignerNewOther: String {
        String(localized: "data_transfer_signer_new_other", defaultValue: "has a different signer", bundle: .module)
    }

    static var transferSignerThisGooglePlay: String {
        String(
            localized: "data_transfer_signer_this_google_play",
            defaultValue: "is from Google Play (signed by Google)",
            bundle: .module
        )
    }

    static var transferSignerThisVettid: String {
        String(
            localized: "data_transfer_signer_this_vettid",
            defaultValue: "is from F-Droid or direct (signed by VettID)",
            bundle: .module
        )
    }

    static var transferSignerThisDevelopment: String {
        String(localized: "data_transfer_signer_this_development", defaultValue: "is a development build", bundle: .module)
    }
}
