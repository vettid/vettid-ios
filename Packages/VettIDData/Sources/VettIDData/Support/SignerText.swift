import Foundation

/// The member-facing texts of the signer binding in a transfer (VAULT-MESSAGING 0.27.0 §11.7.1; the wording is
/// ANDROID-PLAN 0.1.36 §7). The vault names a class; the app supplies every word. Mirrors vettid-android `SignerText.kt`
/// (`signerChangeText`); "Installed from" is the build's own on an iPhone (IOS-PLAN ID15), so it has no counterpart here.
public enum SignerText {
    /// The confirmation before the PIN when a transfer changes the vault's signer (`signer_changed`): "The new phone's
    /// VettID was installed from Google Play (signed by Google); this one is from F-Droid or direct (signed by VettID).
    /// Continue only if you installed it yourself." (or the reverse; a development build and an unknown signer have their
    /// own halves). [new]: the class the vault named for the new phone's app (nil: a class this app does not know);
    /// [current]: this phone's own (nil: it has none, as an iPhone; the body then names only the new phone's, chosen; not
    /// in the spec).
    public static func changeBody(new: SignerClass?, current: SignerClass?) -> String {
        guard let current else { return DataStrings.transferSignerBodyIPhone(newPhone(new)) }
        return DataStrings.transferSignerBody(newPhone(new), thisPhone(current))
    }

    /// "was installed from …", for the new phone's VettID; nil: a class this app does not know.
    static func newPhone(_ c: SignerClass?) -> String {
        switch c {
        case .googlePlay: DataStrings.transferSignerNewGooglePlay
        case .vettid: DataStrings.transferSignerNewVettid
        case .development: DataStrings.transferSignerNewDevelopment
        case nil: DataStrings.transferSignerNewOther
        }
    }

    /// "is from …", for this phone's VettID.
    static func thisPhone(_ c: SignerClass) -> String {
        switch c {
        case .googlePlay: DataStrings.transferSignerThisGooglePlay
        case .vettid: DataStrings.transferSignerThisVettid
        case .development: DataStrings.transferSignerThisDevelopment
        }
    }
}
