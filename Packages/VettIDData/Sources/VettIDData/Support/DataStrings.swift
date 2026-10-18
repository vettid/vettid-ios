import Foundation

/// The package's texts, from `Resources/Localizable.xcstrings`. Keys are the Android string names
/// (vettid-android `core/data/src/main/res/values/strings.xml`); the English values are the same. A count Android
/// formats with `%,d` is grouped as the member's locale groups digits.
enum DataStrings {
    static var failureNetwork: String {
        String(
            localized: "data_failure_network",
            defaultValue: """
                VettID could not reach the service. Check your connection and try again.
                """,
            bundle: .module
        )
    }
    static var failureUnauthorized: String {
        String(
            localized: "data_failure_unauthorized",
            defaultValue: """
                VettID's account service does not accept this phone for your vault any more. If you moved VettID to another \
                phone, this one was replaced. If a setup took longer than an hour, start again with a new code.
                """,
            bundle: .module
        )
    }
    static var failureSetupCode: String {
        String(
            localized: "data_failure_setup_code",
            defaultValue: """
                That setup code did not work. Get a new one on the account site.
                """,
            bundle: .module
        )
    }
    static var failureTerms: String {
        String(
            localized: "data_failure_terms",
            defaultValue: """
                Accept the current membership terms on the account site first.
                """,
            bundle: .module
        )
    }
    static var failureRateLimited: String {
        String(localized: "data_failure_rate_limited", defaultValue: "Too many attempts. Wait a little and try again.", bundle: .module)
    }
    static var failureVaultUnavailable: String {
        String(
            localized: "data_failure_vault_unavailable",
            defaultValue: """
                The vault service is not available yet. Try again later.
                """,
            bundle: .module
        )
    }
    static var failureServicePaused: String {
        String(
            localized: "data_failure_service_paused",
            defaultValue: """
                The vault service is paused for maintenance. Try again later.
                """,
            bundle: .module
        )
    }
    static var failureReleaseEnded: String {
        String(
            localized: "data_failure_release_ended",
            defaultValue: """
                The vault software release your vault is sealed to has ended. The vault can no longer be opened.
                """,
            bundle: .module
        )
    }
    static var failureBadPin: String {
        String(localized: "data_failure_bad_pin", defaultValue: "That PIN is not correct.", bundle: .module)
    }
    static var failureBadPassword: String {
        String(localized: "data_failure_bad_password", defaultValue: "That credential password is not correct.", bundle: .module)
    }
    static var failureBackoff: String {
        String(localized: "data_failure_backoff", defaultValue: "Too many wrong attempts. Wait before trying again.", bundle: .module)
    }
    static var failureFrozen: String {
        String(
            localized: "data_failure_frozen",
            defaultValue: """
                Your credential is frozen after a clone alert. Answer the alert first.
                """,
            bundle: .module
        )
    }
    static var failureRotationRequired: String {
        String(
            localized: "data_failure_rotation_required",
            defaultValue: """
                Your credential must be rotated before it can be used again.
                """,
            bundle: .module
        )
    }
    static var failureNotSupported: String {
        String(
            localized: "data_failure_not_supported",
            defaultValue: """
                Your vault's software release does not support this yet.
                """,
            bundle: .module
        )
    }
    static var failureNoResponse: String {
        String(localized: "data_failure_no_response", defaultValue: "Your vault did not answer in time. Try again.", bundle: .module)
    }
    static var failureVaultExists: String {
        String(
            localized: "data_failure_vault_exists",
            defaultValue: """
                Your account already has a vault, held by another app.
                """,
            bundle: .module
        )
    }
    static var failureAttestation: String {
        String(
            localized: "data_failure_attestation",
            defaultValue: """
                This phone could not be verified. VettID needs a phone with hardware key attestation and a locked, verified \
                boot.
                """,
            bundle: .module
        )
    }
    static var failureRollback: String {
        String(
            localized: "data_failure_rollback",
            defaultValue: """
                The vault is served by an older software release than this phone last used. VettID did not send your PIN.
                """,
            bundle: .module
        )
    }
    static var failureManifest: String {
        String(
            localized: "data_failure_manifest",
            defaultValue: """
                The vault software list could not be verified. Try again later.
                """,
            bundle: .module
        )
    }
    static var failureManifestUnavailable: String {
        String(
            localized: "data_failure_manifest_unavailable",
            defaultValue: """
                The list of vault releases could not be loaded, so your vault's software could not be checked. Nothing was \
                sent to your vault. Check your connection and try again.
                """,
            bundle: .module
        )
    }
    static var failureReleaseUnknown: String {
        String(
            localized: "data_failure_release_unknown",
            defaultValue: """
                Your vault runs a release that is not in this app's list of vault releases, so VettID did not ask for your PIN \
                and sent nothing. The app loads the list again each time you try. Try again; if this keeps happening, update \
                VettID.
                """,
            bundle: .module
        )
    }
    static var failureEnclave: String {
        String(
            localized: "data_failure_enclave",
            defaultValue: """
                Your vault's software could not be verified. Nothing was sent to it: not your PIN, nor anything else. Try \
                again; if this keeps happening, do not enter your PIN anywhere else and contact VettID support.
                """,
            bundle: .module
        )
    }
    static var failureNotFound: String { String(localized: "data_failure_not_found", defaultValue: "Nothing was found.", bundle: .module) }
    static var failureDeviceSecret: String {
        String(
            localized: "data_failure_device_secret",
            defaultValue: """
                This phone no longer holds the keys of your vault. That happens when the app's data was cleared or the phone \
                was set up again from a backup. Nothing was disclosed. Whether you can get back into the vault depends on one \
                of its settings. If its credential backup was on (the usual case), you can recover it: start a recovery on the \
                account site. It takes one to three days, and you need your PIN and your password. If you had turned \
                credential backup off, this vault cannot be brought back; you can delete it on the account site and start a \
                new one. If you still have a phone on which VettID works, use 'Move to a new phone' there instead. The account \
                site tells you which of these applies.
                """,
            bundle: .module
        )
    }
    static var failureTransferIncomplete: String {
        String(
            localized: "data_failure_transfer_incomplete",
            defaultValue: """
                The move to this phone did not finish. Approve it again on your old phone.
                """,
            bundle: .module
        )
    }
    static var failureBusy: String {
        String(
            localized: "data_failure_busy",
            defaultValue: """
                The service is busy right now. Nothing was used or changed. Try again in a minute.
                """,
            bundle: .module
        )
    }
    static var failureRetry: String {
        String(
            localized: "data_failure_retry",
            defaultValue: """
                The service was too slow just now. Nothing was used or changed. Try again.
                """,
            bundle: .module
        )
    }
    static var failureCounterUnavailable: String {
        String(
            localized: "data_failure_counter_unavailable",
            defaultValue: """
                We cannot check the attempt record now. Nothing was used or changed. Try again later.
                """,
            bundle: .module
        )
    }
    static var failureStoredMismatch: String {
        String(
            localized: "data_failure_stored_mismatch",
            defaultValue: """
                The vault's stored data could not be opened. Contact VettID.
                """,
            bundle: .module
        )
    }
    static var failureWeakPassword: String {
        String(localized: "data_failure_weak_password", defaultValue: "This password is not strong enough.", bundle: .module)
    }
    static var failureCapabilityRollback: String {
        String(
            localized: "data_failure_capability_rollback",
            defaultValue: """
                This vault's software is older than the software this phone last used with it. Contact VettID.
                """,
            bundle: .module
        )
    }
    static var failureHardwareKeys: String {
        String(
            localized: "data_failure_hardware_keys",
            defaultValue: """
                This phone cannot keep your vault's keys in its secure hardware.
                """,
            bundle: .module
        )
    }
    static var failureResponseTooLarge: String {
        String(
            localized: "data_failure_response_too_large",
            defaultValue: """
                Your vault's answer was too large to send to this phone. Nothing was changed. Try again later.
                """,
            bundle: .module
        )
    }
    static var failureConnectionUnavailable: String {
        String(
            localized: "data_failure_connection_unavailable",
            defaultValue: """
                This connection cannot be reached right now. Try again later.
                """,
            bundle: .module
        )
    }
    static var failureInviteInvalid: String {
        String(
            localized: "data_failure_invite_invalid",
            defaultValue: """
                That is not a VettID invitation. Check the link or code and try again.
                """,
            bundle: .module
        )
    }
    static var failureInviteExpired: String {
        String(localized: "data_failure_invite_expired", defaultValue: "This invitation has expired. Ask for a new one.", bundle: .module)
    }
    static var failureInviteNotConnection: String {
        String(localized: "data_failure_invite_not_connection", defaultValue: "That code is not a connection invitation.", bundle: .module)
    }
    static var failureInviteUnavailable: String {
        String(
            localized: "data_failure_invite_unavailable",
            defaultValue: """
                This invitation is no longer available: it was used, cancelled or has expired. Ask for a new one.
                """,
            bundle: .module
        )
    }
    static var failureBlocked: String {
        String(
            localized: "data_failure_blocked",
            defaultValue: """
                You blocked the vault that sent this invitation. Unblock it first to connect.
                """,
            bundle: .module
        )
    }
    static var failureCredentialLocked: String {
        String(
            localized: "data_failure_credential_locked",
            defaultValue: """
                Your credential is locked. Enter your credential password to continue.
                """,
            bundle: .module
        )
    }
    static var failureConflict: String {
        String(localized: "data_failure_conflict", defaultValue: "This changed on another device. Look again and retry.", bundle: .module)
    }
    static var failureRejected: String {
        String(localized: "data_failure_rejected", defaultValue: "Rejected on your phone.", bundle: .module)
    }
    static var failureOwnerCheckRequired: String {
        String(
            localized: "data_failure_owner_check_required",
            defaultValue: """
                Your daily check is due. What you entered is kept: the check opens when you leave this screen.
                """,
            bundle: .module
        )
    }
    static var failureInUse: String {
        String(
            localized: "data_failure_in_use",
            defaultValue: """
                A sharing rule uses this tag. Change or delete the rule first.
                """,
            bundle: .module
        )
    }
    static var failureLimit: String {
        String(localized: "data_failure_limit", defaultValue: "A limit was reached. Remove something first.", bundle: .module)
    }
    static var failureSignerRefused: String {
        String(
            localized: "data_failure_signer_refused",
            defaultValue: """
                This vault no longer accepts this installation of VettID. Update the app, or recover your vault with a current \
                version.
                """,
            bundle: .module
        )
    }
    static var failureClock: String {
        String(
            localized: "data_failure_clock",
            defaultValue: """
                VettID's account service refused this phone's requests because the phone's date and time are more than a few \
                minutes off. Turn on automatic date and time in the phone's settings, then try again.
                """,
            bundle: .module
        )
    }
    static var failureNoVault: String {
        String(
            localized: "data_failure_no_vault",
            defaultValue: """
                VettID's account service says that your account has no vault. That is what it says after a vault was deleted \
                or an account closed, and it can also be a fault of the service. If you did not delete your vault, do not \
                start over: try again later.
                """,
            bundle: .module
        )
    }
    static var failureEraseFailed: String {
        String(
            localized: "data_failure_erase_failed",
            defaultValue: """
                VettID could not remove your vault's keys from this phone. Try again. If it keeps failing, erase VettID's data \
                on this phone. Your vault itself is not affected: afterwards you can set VettID up again or recover your vault \
                from your account.
                """,
            bundle: .module
        )
    }
    static var failureLocalState: String {
        String(
            localized: "data_failure_local_state",
            defaultValue: """
                VettID could not read the keys it keeps on this phone for your vault. Nothing was deleted or changed. Try \
                again, or restart the phone and open VettID again. If it stays like this, this phone cannot open your vault \
                any more, and the way back is to erase VettID here and recover your vault.
                """,
            bundle: .module
        )
    }
    static var failureOther: String {
        String(localized: "data_failure_other", defaultValue: "Something went wrong. Try again.", bundle: .module)
    }

    /// An integer with the locale's digit grouping (Android's `%,d`).
    static func grouped(_ n: Int64) -> String { n.formatted(.number.grouping(.automatic)) }
}
