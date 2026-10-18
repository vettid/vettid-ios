import Foundation

/// The texts of Vault status and Attestation (vettid-android `feature/settings` `strings.xml`; IOS-PLAN ID15 and §14).
extension SettingsStrings {
    static var statusTitle: String {
        String(localized: "settings_status_title", defaultValue: "Vault status", bundle: .module)
    }

    static var statusState: String {
        String(localized: "settings_status_state", defaultValue: "State", bundle: .module)
    }

    static var statusStateUnlocked: String {
        String(localized: "settings_status_state_unlocked", defaultValue: "Unlocked", bundle: .module)
    }

    static var statusStateLocked: String {
        String(localized: "settings_status_state_locked", defaultValue: "Locked", bundle: .module)
    }

    static var statusStateEnrolling: String {
        String(localized: "settings_status_state_enrolling", defaultValue: "Being set up", bundle: .module)
    }

    static var statusVaultId: String {
        String(localized: "settings_status_vault_id", defaultValue: "Vault ID", bundle: .module)
    }

    static var statusRelease: String {
        String(localized: "settings_status_release", defaultValue: "Release", bundle: .module)
    }

    static func statusReleaseValue(_ a0: Int, _ a1: String) -> String {
        String(localized: "settings_status_release_value", defaultValue: "Release \(a0) (\(a1))", bundle: .module)
    }

    static var statusReleaseLast: String {
        String(localized: "settings_status_release_last", defaultValue: "This phone last unlocked into", bundle: .module)
    }

    static func statusReleaseLastValue(_ n: Int) -> String {
        String(localized: "settings_status_release_last_value", defaultValue: "Release \(n)", bundle: .module)
    }

    static var statusRecovery: String {
        String(localized: "settings_status_recovery", defaultValue: "Recovery", bundle: .module)
    }

    static var statusRecoveryNone: String {
        String(localized: "settings_status_recovery_none", defaultValue: "None", bundle: .module)
    }

    static var statusDevices: String {
        String(localized: "settings_status_devices", defaultValue: "Devices", bundle: .module)
    }

    static var statusConnections: String {
        String(localized: "settings_status_connections", defaultValue: "Connections", bundle: .module)
    }

    static var statusProvisional: String {
        String(localized: "settings_status_provisional", defaultValue: "Confirmed", bundle: .module)
    }

    static var statusAdvisory: String {
        String(
            localized: "settings_status_advisory",
            defaultValue: "Status comes from the account service and is for information only; your vault's own answers decide.",
            bundle: .module
        )
    }

    static func noticeUpdateAvailable(_ n: Int) -> String {
        String(
            localized: "settings_notice_update_available",
            defaultValue: "An update is available: release \(n). Update it from Settings → Vault → Update available.",
            bundle: .module
        )
    }

    static func noticeFinalWarning(_ s: String) -> String {
        String(
            localized: "settings_notice_final_warning",
            defaultValue: """
                Your vault's release ends on \(s). Update it before then (Settings → Vault → Update available), or the \
                vault can no longer be opened.
                """,
            bundle: .module
        )
    }

    static var noticeEnded: String {
        String(
            localized: "settings_notice_ended",
            defaultValue: "Your vault's release has ended. The vault can no longer be opened.",
            bundle: .module
        )
    }

    static var noticeRescue: String {
        String(
            localized: "settings_notice_rescue",
            defaultValue: "Your vault's release has ended but is open for a rescue: unlock and approve the move to a current release.",
            bundle: .module
        )
    }

    static var noticeUnavailable: String {
        String(localized: "settings_notice_unavailable", defaultValue: "Your vault's release is not available.", bundle: .module)
    }

    static var noticeTitle: String {
        String(localized: "settings_notice_title", defaultValue: "Release notice", bundle: .module)
    }

    static func recoveryStatusArmed(_ n: Int) -> String {
        String(localized: "settings_recovery_status_armed", defaultValue: "Recovery: on. Attempts used: \(n) of 10.", bundle: .module)
    }

    static func recoveryStatusUsed(_ n: Int) -> String {
        String(
            localized: "settings_recovery_status_used",
            defaultValue: """
                Recovery attempts used: \(n) of 10. If that was not you, change your password now, and your PIN as well. \
                That gives you 10 new attempts and ends the old ones.
                """,
            bundle: .module
        )
    }

    static var recoveryStatusExhausted: String {
        String(
            localized: "settings_recovery_status_exhausted",
            defaultValue: "All 10 recovery attempts were used. Recovery is off until you change your PIN or your password.",
            bundle: .module
        )
    }

    static var recoveryStatusNeedsCheck: String {
        String(localized: "settings_recovery_status_needs_check", defaultValue: "Recovery: set up at your next check.", bundle: .module)
    }

    static var recoveryStatusOff: String {
        String(localized: "settings_recovery_status_off", defaultValue: "Recovery: off (credential backup is off).", bundle: .module)
    }

    static var recoveryStatusUnknown: String {
        String(localized: "settings_recovery_status_unknown", defaultValue: "Recovery: cannot be checked right now.", bundle: .module)
    }

    static var recoveryNotOffered: String {
        String(localized: "settings_recovery_not_offered", defaultValue: "This vault's release does not offer recovery.", bundle: .module)
    }

    static var recoveryStatusChangeRequired: String {
        String(
            localized: "settings_recovery_status_change_required",
            defaultValue: "Recovery is off until you choose a new password that meets the rules.",
            bundle: .module
        )
    }

    static var installedApple: String {
        String(localized: "ios_settings_installed_apple", defaultValue: "Installed from: Apple (App Store or TestFlight)", bundle: .module)
    }

    static var installedAppAttest: String {
        String(
            localized: "ios_settings_installed_app_attest",
            defaultValue: "Apple App Attest confirms this is the VettID app.",
            bundle: .module
        )
    }

    static var attestationTitle: String {
        String(localized: "settings_attestation_title", defaultValue: "Attestation", bundle: .module)
    }

    static var attestationBody: String {
        String(
            localized: "settings_attestation_body",
            defaultValue: """
                Your vault checks this phone's hardware key attestation at every enrollment and unlock, and this phone \
                checks the vault's enclave against VettID's signed release list.
                """,
            bundle: .module
        )
    }

    static var attestationDevice: String {
        String(localized: "settings_attestation_device", defaultValue: "This phone", bundle: .module)
    }

    static var attestationKey: String {
        String(localized: "settings_attestation_key", defaultValue: "Device attestation key", bundle: .module)
    }

    static var attestationKeyNone: String {
        String(localized: "settings_attestation_key_none", defaultValue: "Not created yet", bundle: .module)
    }

    static var attestationStrongbox: String {
        String(localized: "settings_attestation_strongbox", defaultValue: "StrongBox available", bundle: .module)
    }

    static var attestationVersion: String {
        String(localized: "settings_attestation_version", defaultValue: "Attestation version", bundle: .module)
    }

    static var attestationBoot: String {
        String(localized: "settings_attestation_boot", defaultValue: "Verified boot", bundle: .module)
    }

    static var attestationLocked: String {
        String(localized: "settings_attestation_locked", defaultValue: "Bootloader locked", bundle: .module)
    }

    static var attestationBootKey: String {
        String(localized: "settings_attestation_boot_key", defaultValue: "Boot key", bundle: .module)
    }

    static var attestationEnclave: String {
        String(localized: "settings_attestation_enclave", defaultValue: "Vault enclave", bundle: .module)
    }

    static var attestationRelease: String {
        String(localized: "settings_attestation_release", defaultValue: "Last verified release", bundle: .module)
    }

    static func attestationReleaseValue(_ a0: Int, _ a1: String) -> String {
        String(localized: "settings_attestation_release_value", defaultValue: "Release \(a0) · \(a1)", bundle: .module)
    }

    static var attestationEnvironment: String {
        String(localized: "settings_attestation_environment", defaultValue: "Environment", bundle: .module)
    }

    static var iosAttestationBody: String {
        String(
            localized: "ios_settings_attestation_body",
            defaultValue: """
                Your vault checks this iPhone's App Attest key at every enrollment and unlock, and this iPhone checks the \
                vault's enclave against VettID's signed release list.
                """,
            bundle: .module
        )
    }

    static var iosAttestationDevice: String {
        String(localized: "ios_settings_attestation_device", defaultValue: "This iPhone", bundle: .module)
    }

    static var iosAttestationKey: String {
        String(localized: "ios_settings_attestation_key", defaultValue: "App Attest key", bundle: .module)
    }

    static var attestationKeyAccepted: String {
        String(localized: "ios_settings_attestation_key_accepted", defaultValue: "Accepted by your vault", bundle: .module)
    }

    static var attestationKeyNotAccepted: String {
        String(localized: "ios_settings_attestation_key_not_accepted", defaultValue: "Not accepted yet", bundle: .module)
    }
}
