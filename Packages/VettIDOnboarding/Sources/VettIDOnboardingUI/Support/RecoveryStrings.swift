import Foundation

/// The texts of the recovery's code (vettid-android `feature/onboarding` `strings.xml`, word for word): the refusals of a scanned
/// or typed code and the typed entry's problems. The screens' own labels come with I3.4b.
enum RecoveryStrings {
    static var recoverScanNotCode: String {
        String(localized: "recover_scan_not_code", defaultValue: "That is not a VettID recovery code.", bundle: .module)
    }

    static func recoverScanOtherEnvironment(_ api: String) -> String {
        String(
            localized: "recover_scan_other_environment",
            defaultValue: """
                That code is from another VettID environment (\(api)), not the one this app uses.
                """,
            bundle: .module
        )
    }

    static var recoverScanNoApi: String {
        String(
            localized: "recover_scan_no_api",
            defaultValue: """
                That recovery code is from an older account site. Reload the recovery page on the account site and scan the \
                new code.
                """,
            bundle: .module
        )
    }

    static func recoverNotAvailable(_ delay: String) -> String {
        String(
            localized: "recover_not_available",
            defaultValue: """
                This recovery is not available: its code may not be ready yet (\(delay) after the request), or the recovery \
                was cancelled, used or has expired. Check the account site.
                """,
            bundle: .module
        )
    }

    static var recoverNotOffered: String {
        String(localized: "recover_not_offered", defaultValue: "This vault's release does not offer recovery.", bundle: .module)
    }

    static func recoverBadCode(_ wrong: Int) -> String {
        String(
            localized: "recover_bad_code",
            defaultValue: """
                That code is not right. After 5 wrong codes the recovery is cancelled. Wrong codes from this phone: \(wrong)\
                 of 5.
                """,
            bundle: .module
        )
    }

    static var recoverVoided: String {
        String(
            localized: "recover_voided",
            defaultValue: """
                That was the fifth wrong code, so the recovery was cancelled. Start a new recovery on the account site.
                """,
            bundle: .module
        )
    }

    static var recoverCodeExpired: String {
        String(
            localized: "recover_code_expired",
            defaultValue: """
                This code has expired. Start a new recovery on the account site.
                """,
            bundle: .module
        )
    }

    static var recoverCodeEarlyUnknown: String {
        String(localized: "recover_code_early_unknown", defaultValue: "This code is not valid yet. Try again later.", bundle: .module)
    }

    static var recoverCodeGone: String {
        String(
            localized: "recover_code_gone",
            defaultValue: """
                This recovery is no longer active: it was cancelled, already used, or voided after wrong codes. Start a new \
                recovery on the account site.
                """,
            bundle: .module
        )
    }

    static var recoverCodeAttestation: String {
        String(
            localized: "recover_code_attestation",
            defaultValue: """
                Your vault could not verify this phone (device attestation). The code is still valid; this phone may not be \
                supported.
                """,
            bundle: .module
        )
    }

    static var recoverCodeRetry: String {
        String(localized: "recover_code_retry", defaultValue: "Your vault could not answer just now. Try again.", bundle: .module)
    }

    static var recoverTypeLetterU: String {
        String(localized: "recover_type_letter_u", defaultValue: "The code has no letter U. Check whether it is a V.", bundle: .module)
    }

    static var recoverTypeOtherCharacter: String {
        String(localized: "recover_type_other_character", defaultValue: "The code uses only digits and letters.", bundle: .module)
    }

    static func recoverTypeInGroup(_ text: String, _ group: Int) -> String {
        String(localized: "recover_type_in_group", defaultValue: "\(text) Look at group \(group).", bundle: .module)
    }

    static func recoverTypeBadCheck(_ host: String) -> String {
        String(
            localized: "recover_type_bad_check",
            defaultValue: """
                That code doesn't match. Compare it with the account site group by group, and check that the site is \
                \(host).
                """,
            bundle: .module
        )
    }

    static var recoverTypeShortCode: String {
        String(
            localized: "recover_type_short_code",
            defaultValue: """
                That is the short code of an older page. Reload the recovery page on the account site: it shows 12 groups.
                """,
            bundle: .module
        )
    }

    static var recoverTypeIncomplete: String {
        String(
            localized: "recover_type_incomplete",
            defaultValue: """
                The code has 12 groups of four characters. Type them all.
                """,
            bundle: .module
        )
    }

    // (IOS-PLAN 0.1.33 §4.9, "A phone that could not tell"; approved by the owner on 2026-10-24.) The keys are the spec's.

    static var recoverCouldNotTell: String {
        String(
            localized: "recover_could_not_tell",
            defaultValue: """
                We could not tell whether your last attempt recovered the vault. You can start a new recovery on the account \
                site and use this phone for it; nothing on this phone is deleted.
                """,
            bundle: .module
        )
    }

    /// (Owner decision of 2026-10-25) After both recoveries ended and a day of refusals to the unlock. An interim wording: the text
    /// awaits the owner's; an iPhone-only key until then.
    static var iosRecoverCouldNotFinish: String {
        String(
            localized: "ios_recover_could_not_finish",
            defaultValue: "VettID could not finish recovering your vault on this phone. Contact VettID.",
            bundle: .module
        )
    }

    static var onboardingOpenTookPhone: String {
        String(
            localized: "onboarding_open_took_phone",
            defaultValue: "Your vault took this phone, but it cannot be unlocked right now. Contact VettID.",
            bundle: .module
        )
    }

    static func recoverRateLimitedWait(_ wait: String) -> String {
        String(localized: "recover_rate_limited_wait", defaultValue: "Too many attempts. Try again in \(wait).", bundle: .module)
    }

}
