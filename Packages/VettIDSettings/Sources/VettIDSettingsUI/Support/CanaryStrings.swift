import Foundation
import VettIDData

// The canary manifest's texts (VAULT-RELEASES §10.1 step 9): the dialog's keys are vettid-android's app module
// `canary_*`, the Attestation section's its `feature/settings` `settings_canary_*`, the English values the same, word for
// word; `ios_settings_canary_*` are the iPhone's own (the file importer, Files and AirDrop).

/// The texts of the canary manifest dialog and of its section on Attestation.
enum CanaryStrings {
    static var confirmTitle: String {
        String(localized: "canary_confirm_title", defaultValue: "Use a test release manifest?", bundle: .module)
    }

    static func confirmBody(_ serial: Int, _ key: String, _ releases: String) -> String {
        String(
            localized: "canary_confirm_body",
            defaultValue: """
                This file is a list of vault releases signed by VettID (serial \(serial), key \(key)) that VettID has not \
                published yet. It lists \(releases). Use it only if VettID asked you to test a new vault release. The app \
                uses it instead of the published list until VettID publishes this list or a newer one.
                """,
            bundle: .module
        )
    }

    static var confirm: String {
        String(localized: "canary_confirm", defaultValue: "Use it", bundle: .module)
    }

    static func release(_ number: Int, _ status: String) -> String {
        String(localized: "canary_release", defaultValue: "release \(number) (\(status))", bundle: .module)
    }

    static var ok: String {
        String(localized: "canary_ok", defaultValue: "OK", bundle: .module)
    }

    static var installedTitle: String {
        String(localized: "canary_installed_title", defaultValue: "Test release manifest in use", bundle: .module)
    }

    static func installedBody(_ serial: Int) -> String {
        String(
            localized: "canary_installed_body",
            defaultValue: "The app now uses the test release manifest (serial \(serial)). You can stop using it in Settings, Attestation.",
            bundle: .module
        )
    }

    static var refusedTitle: String {
        String(localized: "canary_refused_title", defaultValue: "This file cannot be used", bundle: .module)
    }

    static var refusedSignature: String {
        String(localized: "canary_refused_signature", defaultValue: "It is not signed with a key this app trusts.", bundle: .module)
    }

    static var refusedOlder: String {
        String(
            localized: "canary_refused_older", defaultValue: "It is older than the release list this phone already uses.", bundle: .module
        )
    }

    static var refusedPublished: String {
        String(
            localized: "canary_refused_published",
            defaultValue: "VettID has already published this release list or a newer one, so it is not needed.",
            bundle: .module
        )
    }

    static var refusedFormat: String {
        String(localized: "canary_refused_format", defaultValue: "It is not a VettID release manifest.", bundle: .module)
    }

    static var refusedOther: String {
        String(localized: "canary_refused_other", defaultValue: "It could not be checked. Try again.", bundle: .module)
    }

    /// The refusal's text for [code] (vettid-android `refusedText`).
    static func refused(_ code: String?) -> String {
        switch code {
        case CanaryManifestCodes.signature: refusedSignature
        case CanaryManifestCodes.older: refusedOlder
        case CanaryManifestCodes.published: refusedPublished
        case CanaryManifestCodes.format, CanaryManifestCodes.tooLarge: refusedFormat
        default: refusedOther
        }
    }

    /// [v]'s releases, each with its status ("release 3 (deprecated), release 4 (active)").
    static func releases(_ v: CanaryManifestView) -> String {
        v.releases.map { release(Int($0.number), $0.status) }.joined(separator: ", ")
    }

    // MARK: - Settings → Attestation

    static var sectionTitle: String {
        String(localized: "settings_canary_title", defaultValue: "Test release manifest", bundle: .module)
    }

    static var serial: String {
        String(localized: "settings_canary_serial", defaultValue: "Serial and signing key", bundle: .module)
    }

    static func serialValue(_ serial: Int, _ key: String) -> String {
        String(localized: "settings_canary_serial_value", defaultValue: "Serial \(serial) · key \(key)", bundle: .module)
    }

    static var releasesLabel: String {
        String(localized: "settings_canary_releases", defaultValue: "Releases it lists", bundle: .module)
    }

    static func settingsRelease(_ number: Int, _ status: String) -> String {
        String(localized: "settings_canary_release", defaultValue: "release \(number) (\(status))", bundle: .module)
    }

    /// [v]'s releases as the Attestation row lists them.
    static func settingsReleases(_ v: CanaryManifestView) -> String {
        v.releases.map { settingsRelease(Int($0.number), $0.status) }.joined(separator: ", ")
    }

    static var remove: String {
        String(localized: "settings_canary_remove", defaultValue: "Stop using the test manifest", bundle: .module)
    }

    static var removeTitle: String {
        String(localized: "settings_canary_remove_title", defaultValue: "Stop using the test manifest?", bundle: .module)
    }

    static var removeBody: String {
        String(
            localized: "settings_canary_remove_body",
            defaultValue: """
                VettID's published release list is used again. A vault on a release that is not published yet cannot be \
                unlocked from this phone until VettID publishes it.
                """,
            bundle: .module
        )
    }

    static var load: String {
        String(localized: "ios_settings_canary_load", defaultValue: "Load a test release manifest", bundle: .module)
    }

    static var loadBody: String {
        String(
            localized: "ios_settings_canary_load_body",
            defaultValue: """
                Only if VettID asked you to test a new vault release: choose the file VettID sent you, or open it with VettID \
                from Files or AirDrop.
                """,
            bundle: .module
        )
    }
}
