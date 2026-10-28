import Foundation
import VettIDData

// The unlock screen, the root screens and the stuck screens: vettid-android `feature/onboarding` `strings.xml`,
// `strings_owner_check.xml`, the app's `root_*` and core/ui's `core_ui_erase_phone_body`, word for word.
extension OnboardingStrings {
    static var unlockTitle: String {
        String(localized: "unlock_title", defaultValue: "Unlock your vault", bundle: .module)
    }
    static var unlockBody: String {
        String(localized: "unlock_body", defaultValue: "Enter your vault PIN.", bundle: .module)
    }
    static func unlockBodyAccount(_ email: String) -> String {
        String(localized: "unlock_body_account", defaultValue: "Enter the vault PIN for \(email).", bundle: .module)
    }
    /// ANDROID-PLAN 0.1.45 "A lost answer to a PIN or password change" (shared with the Android app): the unlock's first
    /// step while a PIN change is unresolved.
    static var unlockPreviousPinTitle: String {
        String(localized: "unlock_previous_pin_title", defaultValue: "Enter your previous PIN", bundle: .module)
    }
    static var unlockPreviousPinBody: String {
        String(
            localized: "unlock_previous_pin_body",
            defaultValue: "Your last PIN change got no answer. If it went through, VettID will ask for your new PIN next.",
            bundle: .module
        )
    }
    /// The same, after the vault answered `device_secret` to the previous PIN.
    static var unlockNewPinTitle: String {
        String(localized: "unlock_new_pin_title", defaultValue: "Your PIN change went through.", bundle: .module)
    }
    static var unlockNewPinBody: String {
        String(localized: "unlock_new_pin_body", defaultValue: "Enter your new PIN.", bundle: .module)
    }
    static var unlockSubmit: String {
        String(localized: "unlock_submit", defaultValue: "Unlock", bundle: .module)
    }
    static var unlockChecking: String {
        String(localized: "unlock_checking", defaultValue: "Checking your vault's software", bundle: .module)
    }
    static var unlockRetry: String {
        String(localized: "unlock_retry", defaultValue: "Try again", bundle: .module)
    }
    static var unlockReleaseUnknownTitle: String {
        String(localized: "unlock_release_unknown_title", defaultValue: "This app does not know your vault's release", bundle: .module)
    }
    static var unlockEnclaveTitle: String {
        String(localized: "unlock_enclave_title", defaultValue: "Your vault's software could not be verified", bundle: .module)
    }
    static var unlockUpdatedTitle: String {
        String(localized: "unlock_updated_title", defaultValue: "Vault software was updated", bundle: .module)
    }
    static func unlockUpdatedBody(_ release: Int, _ fingerprint: String, _ last: Int) -> String {
        String(
            localized: "unlock_updated_body",
            defaultValue: """
                Your vault now runs release \(release) (fingerprint \(fingerprint)); this phone last used release \
                \(last). Another of your devices approved this update. Continue only if you expected it.
                """,
            bundle: .module
        )
    }
    static var unlockUpdatedAck: String {
        String(localized: "unlock_updated_ack", defaultValue: "Continue", bundle: .module)
    }
    static var unlockRollbackTitle: String {
        String(localized: "unlock_rollback_title", defaultValue: "Older vault software", bundle: .module)
    }
    static func unlockRollbackBody(_ release: Int, _ last: Int) -> String {
        String(
            localized: "unlock_rollback_body",
            defaultValue: """
                Your vault is served by release \(release), older than release \(last) that this phone last used. VettID \
                will not send your PIN to it.
                """,
            bundle: .module
        )
    }
    static func unlockStatusTitle(_ release: Int, _ status: String) -> String {
        String(localized: "unlock_status_title", defaultValue: "Release \(release) is \(status)", bundle: .module)
    }
    static func unlockStatusBodyEnds(_ date: String) -> String {
        String(
            localized: "unlock_status_body_ends",
            defaultValue: """
                It ends on \(date). Update to keep your vault working.
                """,
            bundle: .module
        )
    }
    static var unlockStatusBody: String {
        String(localized: "unlock_status_body", defaultValue: "Update to the newest release to keep your vault working.", bundle: .module)
    }
    static func unlockOfferTitle(_ release: Int) -> String {
        String(localized: "unlock_offer_title", defaultValue: "Update available: release \(release)", bundle: .module)
    }
    static func unlockOfferBody(_ release: Int, _ offer: Int, _ fingerprint: String) -> String {
        String(
            localized: "unlock_offer_body",
            defaultValue: """
                Your vault runs release \(release). Release \(offer) (fingerprint \(fingerprint)) is available. Anyone \
                can rebuild it and compare the fingerprint.
                """,
            bundle: .module
        )
    }
    static var unlockOfferApprove: String {
        String(localized: "unlock_offer_approve", defaultValue: "Approve the update with this unlock", bundle: .module)
    }
    static var unlockBadPin: String {
        String(localized: "unlock_bad_pin", defaultValue: "That PIN is not correct.", bundle: .module)
    }
    static func unlockWait(_ wait: String) -> String {
        String(localized: "unlock_wait", defaultValue: "Too many wrong PINs. Try again in \(wait).", bundle: .module)
    }
    static func unlockServiceWait(_ wait: String) -> String {
        String(localized: "unlock_service_wait", defaultValue: "Try again in \(wait).", bundle: .module)
    }
    static var unlockRecoveryTitle: String {
        String(localized: "unlock_recovery_title", defaultValue: "A recovery is in progress", bundle: .module)
    }
    static var unlockRecoveryBody: String {
        String(
            localized: "unlock_recovery_body",
            defaultValue: """
                Someone started a recovery of this vault from the account site, so it is locked for this phone. If that \
                was you on a new phone, let it finish there. If it was not you, cancel it now: unlocking here with your \
                PIN cancels the recovery.
                """,
            bundle: .module
        )
    }
    static var unlockRecoveryCancel: String {
        String(localized: "unlock_recovery_cancel", defaultValue: "Cancel the recovery and unlock", bundle: .module)
    }
    static var unlockRollbackStateTitle: String {
        String(localized: "unlock_rollback_state_title", defaultValue: "Your vault's state is older than expected", bundle: .module)
    }
    static var unlockRollbackStateBody: String {
        String(
            localized: "unlock_rollback_state_body",
            defaultValue: """
                The vault's stored state is older than state this phone has already seen. Someone may have restored an \
                old copy. Contact VettID support before you continue.
                """,
            bundle: .module
        )
    }
    static func unlockUpdateRefused(_ code: String) -> String {
        String(
            localized: "unlock_update_refused",
            defaultValue: """
                The update was refused (\(code)). Your vault stayed on its current release.
                """,
            bundle: .module
        )
    }
    static var unlockNoUserGuid: String {
        String(
            localized: "unlock_no_user_guid",
            defaultValue: """
                This phone cannot unlock your vault yet: it was moved here while your vault ran an older release. It can \
                unlock once your vault is updated.
                """,
            bundle: .module
        )
    }
    static var unlockUnreadable: String {
        String(
            localized: "unlock_unreadable",
            defaultValue: """
                Your vault did not recognise this phone. It may have been replaced by a recovery or a transfer.
                """,
            bundle: .module
        )
    }
    static var unlockNotRecognisedTitle: String {
        String(localized: "unlock_not_recognised_title", defaultValue: "Your vault did not recognise this phone", bundle: .module)
    }
    static var unlockNotRecognisedBody: String {
        String(
            localized: "unlock_not_recognised_body",
            defaultValue: """
                This phone may have been replaced by a recovery or a transfer while it was offline. If your vault now \
                works on another phone, you can erase VettID from this one.
                """,
            bundle: .module
        )
    }
    static var unlockErase: String {
        String(localized: "unlock_erase", defaultValue: "Erase VettID from this phone", bundle: .module)
    }
    static var unlockStuckTitle: String {
        String(localized: "unlock_stuck_title", defaultValue: "This phone cannot open your vault", bundle: .module)
    }
    static var unlockStuckBody: String {
        String(
            localized: "unlock_stuck_body",
            defaultValue: """
                This phone no longer holds your vault's keys. Before you erase VettID here, check on your account site \
                that your vault can be recovered, and start the recovery there. When it is ready, erase VettID and \
                choose "I lost my phone: recover my vault".
                """,
            bundle: .module
        )
    }
    static var unlockRecoverOnlyBody: String {
        String(
            localized: "unlock_recover_only_body",
            defaultValue: """
                Erasing VettID from this phone would not help. Recover your vault from your account site, or contact \
                VettID support at support@vettid.org.
                """,
            bundle: .module
        )
    }
    static var unlockContactSupport: String {
        String(localized: "unlock_contact_support", defaultValue: "Contact support", bundle: .module)
    }
    static var unlockRecover: String {
        String(localized: "unlock_recover", defaultValue: "Recover your vault", bundle: .module)
    }
    static var unlockSignerRefusedTitle: String {
        String(localized: "unlock_signer_refused_title", defaultValue: "This installation is not accepted", bundle: .module)
    }
    static var unlockSignerRefusedBody: String {
        String(
            localized: "unlock_signer_refused_body",
            defaultValue: """
                This vault no longer accepts this installation of VettID. Update the app, or recover your vault with a \
                current version.
                """,
            bundle: .module
        )
    }
    static var unlockSignerRefusedHelp: String {
        String(localized: "unlock_signer_refused_help", defaultValue: "How to recover your vault", bundle: .module)
    }
    static var unlockSignerRefusedHelpHide: String {
        String(localized: "unlock_signer_refused_help_hide", defaultValue: "Hide", bundle: .module)
    }
    static var unlockSignerRefusedHelpTitle: String {
        String(localized: "unlock_signer_refused_help_title", defaultValue: "Recovering or moving your vault", bundle: .module)
    }
    /// [recovery]: the recovery's delay at the vault's time scale (STAGING-TIME-SCALE S5).
    static func unlockSignerRefusedHelpBody(_ recovery: String) -> String {
        String(
            localized: "unlock_signer_refused_help_body",
            defaultValue: """
                First update VettID from where you installed it and try again: your PIN was not counted as wrong.

                If that does not help, recover your vault. Start a recovery on the account site, install a current \
                version of VettID (on this phone after removing this one, or on another phone) and choose "I lost my \
                phone: recover my vault" on its first screen, then scan or type the recovery code. A recovery takes \
                \(recovery) and needs your PIN and your credential password.

                Moving your vault to a new phone directly is not possible while this phone cannot open it.
                """,
            bundle: .module
        )
    }
    static var unlockRefusedTitle: String {
        String(localized: "unlock_refused_title", defaultValue: "Your vault is refusing this phone", bundle: .module)
    }
    static var unlockRefusedBody: String {
        String(
            localized: "unlock_refused_body",
            defaultValue: """
                Messages from this phone to your vault keep being refused. If you moved VettID to another phone, this \
                one may have been replaced. Enter your PIN to check with your vault.
                """,
            bundle: .module
        )
    }
    static var unlockEraseConfirmTitle: String {
        String(localized: "unlock_erase_confirm_title", defaultValue: "Erase VettID from this phone?", bundle: .module)
    }
    static var unlockEraseConfirmBody: String {
        String(
            localized: "unlock_erase_confirm_body",
            defaultValue: """
                This erases VettID's data on this phone only: its keys, your account details and the app's settings. \
                Nothing else on the phone is touched, and it works without a connection.

                It cannot be undone. If this phone still holds your vault, you will need a recovery on another phone to \
                use it again.
                """,
            bundle: .module
        )
    }
    static var unlockEraseConfirm: String {
        String(localized: "unlock_erase_confirm", defaultValue: "Erase", bundle: .module)
    }
    static var unlockErasing: String {
        String(localized: "unlock_erasing", defaultValue: "Erasing VettID from this phone…", bundle: .module)
    }
    static var unlockLockLocking: String {
        String(localized: "unlock_lock_locking", defaultValue: "Locking your vault…", bundle: .module)
    }
    static var unlockLockUnconfirmedTitle: String {
        String(localized: "unlock_lock_unconfirmed_title", defaultValue: "Your vault may still be open", bundle: .module)
    }
    static var unlockLockUnconfirmedBody: String {
        String(
            localized: "unlock_lock_unconfirmed_body",
            defaultValue: """
                Your vault could not be reached, so it may still be open. This phone is locked, and VettID keeps trying \
                to lock the vault.
                """,
            bundle: .module
        )
    }
    static var unlockLockTryAgain: String {
        String(localized: "unlock_lock_try_again", defaultValue: "Try again", bundle: .module)
    }
    static var unlockLockConfirmed: String {
        String(localized: "unlock_lock_confirmed", defaultValue: "Your vault is locked.", bundle: .module)
    }
    // Release L (VAULT-MESSAGING 0.56.4 §10.2 "Locks"): the vault answered that the unlock this lock was for is over
    // (stale_lock / stale). The texts are vettid-android's (approved by the owner 2026-10-24).
    static var unlockLockOpenedAgainTitle: String {
        String(localized: "unlock_lock_opened_again_title", defaultValue: "Your vault was opened again", bundle: .module)
    }
    static var unlockLockOpenedAgainBody: String {
        String(
            localized: "unlock_lock_opened_again_body",
            defaultValue: """
                Your vault was unlocked again after you locked it, so it did not lock and may be open now. This phone is locked.
                """,
            bundle: .module
        )
    }
    static var unlockLockAgain: String {
        String(localized: "unlock_lock_again", defaultValue: "Lock it now", bundle: .module)
    }
    static var unlockLockOk: String {
        String(localized: "unlock_lock_ok", defaultValue: "OK", bundle: .module)
    }
    static var unlockOwnerCheckTitle: String {
        String(localized: "unlock_owner_check_title", defaultValue: "Unlock and check in", bundle: .module)
    }
    static var unlockOwnerCheckBody: String {
        String(
            localized: "unlock_owner_check_body",
            defaultValue: """
                Your daily check is due, so your vault needs your PIN and your credential password.
                """,
            bundle: .module
        )
    }
    /// The primary action of the check screen's password-only retry after an unlock (IOS-PLAN §6.6; VAULT-MESSAGING §3.6.5).
    static var unlockCheckIn: String {
        String(localized: "unlock_check_in", defaultValue: "Check in", bundle: .module)
    }
    /// The PIN unlocked the vault and the check failed on the password; [left]: tries before the vault locks again
    /// (approved by the owner 2026-10-28, ANDROID-PLAN §6 owner check item 6).
    static func unlockCheckPasswordWrong(_ left: Int) -> String {
        String(
            localized: "unlock_check_password_wrong",
            defaultValue: """
                Your vault is unlocked, but the credential password was wrong, so your daily check didn't pass. \(left) tries \
                left before your vault locks again.
                """,
            bundle: .module
        )
    }
    /// A backoff used no try: the vault is open and the check waits (approved by the owner 2026-10-28; IOS-PLAN 0.1.48,
    /// VAULT-MESSAGING 0.71.1 §3.6.5), under vettid-android's key.
    static var unlockCheckOpenWaiting: String {
        String(
            localized: "unlock_check_open_waiting",
            defaultValue: "Your vault is unlocked. Enter your credential password to check in.",
            bundle: .module
        )
    }
    static var unlockPasswordLabel: String {
        String(localized: "unlock_password_label", defaultValue: "Credential password", bundle: .module)
    }
    static var unlockOwnerCheckLockedTitle: String {
        String(localized: "unlock_owner_check_locked_title", defaultValue: "Locked after ten wrong checks", bundle: .module)
    }
    /// The ten-failure lock, on the unlock screen and the check screen (approved by the owner 2026-10-28; IOS-PLAN 0.1.48,
    /// VAULT-MESSAGING 0.71.1 §3.6.5), under vettid-android's key.
    static var unlockOwnerCheckLockedBody: String {
        String(
            localized: "unlock_owner_check_locked_body",
            defaultValue: """
                Your vault locked itself after ten wrong daily checks in a row. Unlock it with your PIN and your credential \
                password.
                """,
            bundle: .module
        )
    }
    /// Release L (VAULT-MESSAGING §3.6.8): the vault locked itself. Title and body as ANDROID-PLAN §4 "Locking the vault"
    /// part 2 (approved by the owner 2026-10-24), under vettid-android's keys.
    static var unlockIdleLockedTitle: String {
        String(localized: "unlock_idle_locked_title", defaultValue: "Your vault locked itself", bundle: .module)
    }
    /// [after]: how long past the deadline that was, as the vault ran it ("7 days", "7 hours" on staging); nil: not known.
    static func unlockIdleLocked(_ after: Int64?) -> String {
        guard let after else {
            return String(
                localized: "unlock_idle_locked_body_unknown",
                defaultValue: """
                    You hadn't checked in, so your vault locked. Unlock it with your PIN and your credential password to carry on. \
                    New messages wait for up to 14 days.
                    """,
                bundle: .module
            )
        }
        let time = IdleLockText.duration(after)
        return String(
            localized: "unlock_idle_locked_body",
            defaultValue: """
                You hadn't checked in for \(time), so your vault locked. Unlock it with your PIN and your credential password to \
                carry on. New messages wait for up to 14 days.
                """,
            bundle: .module
        )
    }
    static var moveDidntFinish: String {
        String(localized: "onboarding_move_didnt_finish", defaultValue: "The move didn't finish", bundle: .module)
    }
    /// [keep]: the old phone's keep period at the vault's time scale (STAGING-TIME-SCALE S10).
    static func keptTransfer(_ keep: String) -> String {
        String(
            localized: "onboarding_kept_transfer",
            defaultValue: """
                Finish the move on your new phone. This phone keeps your vault's keys until your new phone has finished \
                the move, for at most \(keep). Before you give this phone away, remove VettID from it or reset it.
                """,
            bundle: .module
        )
    }
    static var moveDidntFinishBody: String {
        String(
            localized: "onboarding_move_didnt_finish_body",
            defaultValue: """
                Use this if your new phone cannot open your vault. If your new phone opens the vault, ignore this.
                """,
            bundle: .module
        )
    }
    static var moveBackFailed: String {
        String(
            localized: "onboarding_move_back_failed",
            defaultValue: """
                Your vault could not be opened from this phone. Contact VettID within a day of the failed move: it may \
                be repairable.
                """,
            bundle: .module
        )
    }
    static var finishMoveTitle: String {
        String(localized: "onboarding_finish_move_title", defaultValue: "Finish the move", bundle: .module)
    }
    /// [recovery]: the recovery's delay at the vault's time scale (STAGING-TIME-SCALE S5).
    static func erasePhoneBody(_ recovery: String) -> String {
        String(
            localized: "core_ui_erase_phone_body",
            defaultValue: """
                Everything VettID keeps on this phone is erased, including its keys for your vault, and VettID goes back \
                to the start. Your vault itself is not changed.

                To get back into it you then need a recovery from the account site (it takes \(recovery) and needs your PIN \
                and credential password, and the credential backup must be on), or a move from another phone that still \
                holds your vault.
                """,
            bundle: .module
        )
    }
    static var rootStarting: String {
        String(localized: "root_starting", defaultValue: "Opening VettID", bundle: .module)
    }
    static var rootUnreachableTitle: String {
        String(localized: "root_unreachable_title", defaultValue: "VettID cannot connect", bundle: .module)
    }
    static var rootRetry: String {
        String(localized: "root_retry", defaultValue: "Try again", bundle: .module)
    }
    static var rootClockTitle: String {
        String(localized: "root_clock_title", defaultValue: "Check this phone's date and time", bundle: .module)
    }
    static var rootNoVaultTitle: String {
        String(localized: "root_no_vault_title", defaultValue: "Your account has no vault", bundle: .module)
    }
    static var rootLocalStateTitle: String {
        String(localized: "root_local_state_title", defaultValue: "VettID cannot read its keys on this phone", bundle: .module)
    }
    static var rootEraseFailedTitle: String {
        String(localized: "root_erase_failed_title", defaultValue: "VettID could not erase this phone", bundle: .module)
    }
    static var rootRecover: String {
        String(localized: "root_recover", defaultValue: "Recover your vault", bundle: .module)
    }
    static var rootRecoverLine: String {
        String(
            localized: "root_recover_line",
            defaultValue: """
                Before you erase VettID here, check on your account site that your vault can be recovered, and start the \
                recovery there. When it is ready, erase VettID and choose "I lost my phone: recover my vault".
                """,
            bundle: .module
        )
    }
    /// [wait]: 7 days at the vault's time scale (STAGING-TIME-SCALE S12).
    static func rootLongUnreachable(_ wait: String) -> String {
        String(localized: "root_long_unreachable", defaultValue: "VettID has not reached your vault for \(wait) or more.", bundle: .module)
    }
    static var rootStartOver: String {
        String(localized: "root_start_over", defaultValue: "Start over on this phone", bundle: .module)
    }
    static var rootStartOverTitle: String {
        String(localized: "root_start_over_title", defaultValue: "Start over on this phone?", bundle: .module)
    }
    static var rootStartOverBody: String {
        String(
            localized: "root_start_over_body",
            defaultValue: """
                VettID asks the account service once more. If it still says that your account has no vault, VettID \
                forgets its keys for that vault on this phone and goes back to the start, where you can set up a new \
                vault with a setup code.

                Only do this if you deleted your vault or closed your account. If the vault still exists, this phone \
                could afterwards get back into it only with a recovery.
                """,
            bundle: .module
        )
    }
    static var rootErase: String {
        String(localized: "root_erase", defaultValue: "Erase VettID from this phone", bundle: .module)
    }
    static var rootEraseTitle: String {
        String(localized: "root_erase_title", defaultValue: "Erase VettID from this phone?", bundle: .module)
    }

}

// iPhone only (chosen; not in the spec): the earlier-secret step of IOS-PLAN §6.3 item 5.
extension OnboardingStrings {
    static var unlockEarlierSecret: String {
        String(localized: "ios_unlock_earlier_secret", defaultValue: "Try this phone's earlier keys", bundle: .module)
    }

}
