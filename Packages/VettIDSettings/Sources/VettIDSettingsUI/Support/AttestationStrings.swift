#if os(iOS)
import Foundation

/// The texts of Settings → Attestation in detail (ANDROID-PLAN 0.1.124 §4 "Attestation in detail", the refusal reasons
/// 0.1.125; IOS-PLAN §4.17): vettid-android's, word for word, under its keys; `ios_` for what the iPhone adds.
enum AttestationStrings {
    static var none: String {
        String(
            localized: "settings_attestation_none",
            defaultValue: "This phone hasn't verified your vault's enclave yet. It does at the next unlock.",
            bundle: .module
        )
    }

    static var failedTitle: String {
        String(localized: "settings_attestation_failed_title", defaultValue: "Verification failed", bundle: .module)
    }

    static var failedBody: String {
        String(
            localized: "settings_attestation_failed_body",
            defaultValue: "This phone couldn't verify your vault's enclave, so it sent it nothing. The check that failed is marked below.",
            bundle: .module
        )
    }

    static func refusedBody(_ reason: String) -> String {
        String(
            localized: "settings_attestation_refused_body",
            defaultValue: "Every check passed, but this phone refused the release: \(reason)",
            bundle: .module
        )
    }

    static var refusedNotActive: String {
        String(localized: "settings_attestation_refused_not_active", defaultValue: "it isn't offered to new phones.", bundle: .module)
    }

    static var refusedOlder: String {
        String(
            localized: "settings_attestation_refused_older",
            defaultValue: "it's older than a release this phone has already used.",
            bundle: .module
        )
    }

    static var refusedOtherInstance: String {
        String(
            localized: "settings_attestation_refused_other_instance",
            defaultValue: "your vault's address named a different enclave.",
            bundle: .module
        )
    }

    static var refusedTimeScale: String {
        String(
            localized: "settings_attestation_refused_time_scale",
            defaultValue: "its time setting is for test builds, not this app.",
            bundle: .module
        )
    }

    static func ends(_ date: String) -> String {
        String(localized: "settings_attestation_ends", defaultValue: ", ends \(date)", bundle: .module)
    }

    static var statusActive: String {
        String(localized: "settings_attestation_status_active", defaultValue: "Active", bundle: .module)
    }

    static var statusDeprecated: String {
        String(localized: "settings_attestation_status_deprecated", defaultValue: "Deprecated", bundle: .module)
    }

    static var statusRetired: String {
        String(localized: "settings_attestation_status_retired", defaultValue: "Retired", bundle: .module)
    }

    static var statusRemoved: String {
        String(localized: "settings_attestation_status_removed", defaultValue: "Removed", bundle: .module)
    }

    static var attestedAt: String {
        String(localized: "settings_attestation_attested_at", defaultValue: "Attested at", bundle: .module)
    }

    static var validUntil: String {
        String(localized: "settings_attestation_valid_until", defaultValue: "Valid until", bundle: .module)
    }

    static var notVerified: String {
        String(localized: "settings_attestation_not_verified", defaultValue: "Not verified", bundle: .module)
    }

    static var copy: String {
        String(localized: "settings_attestation_copy", defaultValue: "Copy", bundle: .module)
    }

    static var copied: String {
        String(localized: "settings_attestation_copied", defaultValue: "Copied", bundle: .module)
    }

    static var copyAll: String {
        String(localized: "settings_attestation_copy_all", defaultValue: "Copy all", bundle: .module)
    }

    static var sectionChecks: String {
        String(localized: "settings_attestation_section_checks", defaultValue: "Checks", bundle: .module)
    }

    static func asOf(_ time: String) -> String {
        String(localized: "settings_attestation_as_of", defaultValue: "as of \(time)", bundle: .module)
    }

    static var checkPassed: String {
        String(localized: "settings_attestation_check_passed", defaultValue: "Passed", bundle: .module)
    }

    static var checkFailed: String {
        String(localized: "settings_attestation_check_failed", defaultValue: "Failed", bundle: .module)
    }

    static var checkNotRun: String {
        String(localized: "settings_attestation_check_not_run", defaultValue: "Not checked", bundle: .module)
    }

    static var checkManifest: String {
        String(localized: "settings_attestation_check_manifest", defaultValue: "Release list signed by VettID", bundle: .module)
    }

    static var checkChain: String {
        String(localized: "settings_attestation_check_chain", defaultValue: "Certificate chain to the AWS Nitro root", bundle: .module)
    }

    static var checkSignature: String {
        String(localized: "settings_attestation_check_signature", defaultValue: "Signed by AWS Nitro hardware", bundle: .module)
    }

    static var checkKey: String {
        String(localized: "settings_attestation_check_key", defaultValue: "Covers the key this phone encrypts to", bundle: .module)
    }

    static var checkRecent: String {
        String(localized: "settings_attestation_check_recent", defaultValue: "Recent", bundle: .module)
    }

    static var checkNotDebug: String {
        String(localized: "settings_attestation_check_not_debug", defaultValue: "Not a debug enclave", bundle: .module)
    }

    static var checkOwnRelease: String {
        String(localized: "settings_attestation_check_own_release", defaultValue: "Names its own release", bundle: .module)
    }

    static var checkValidity: String {
        String(localized: "settings_attestation_check_validity", defaultValue: "Within its validity", bundle: .module)
    }

    static var checkMatch: String {
        String(localized: "settings_attestation_check_match", defaultValue: "Measurements match a signed release", bundle: .module)
    }

    static var rootFingerprint: String {
        String(localized: "settings_attestation_root_fingerprint", defaultValue: "Root fingerprint (SHA-256)", bundle: .module)
    }

    static var sectionRelease: String {
        String(localized: "settings_attestation_section_release", defaultValue: "Release", bundle: .module)
    }

    static var source: String {
        String(localized: "settings_attestation_source", defaultValue: "Source", bundle: .module)
    }

    static var reproducible: String {
        String(localized: "settings_attestation_reproducible", defaultValue: "Reproducible build", bundle: .module)
    }

    static var rebuildBody: String {
        String(
            localized: "settings_attestation_rebuild_body",
            defaultValue: "Anyone can rebuild this release from its tag and compare the measurements.",
            bundle: .module
        )
    }

    static var rebuild: String {
        String(localized: "settings_attestation_rebuild", defaultValue: "How to rebuild it", bundle: .module)
    }

    static var appVersion: String {
        String(localized: "settings_attestation_app_version", defaultValue: "App version", bundle: .module)
    }

    static func manifestKey(_ keyID: String, _ serial: Int) -> String {
        String(localized: "settings_attestation_manifest_key", defaultValue: "Key \(keyID) · serial \(serial)", bundle: .module)
    }

    static func checkSpoken(_ line: String, _ state: String) -> String {
        String(localized: "settings_attestation_check_spoken", defaultValue: "\(line): \(state)", bundle: .module)
    }

    static var iosVersion: String {
        String(localized: "ios_settings_attestation_ios_version", defaultValue: "iOS version", bundle: .module)
    }
}
#endif
