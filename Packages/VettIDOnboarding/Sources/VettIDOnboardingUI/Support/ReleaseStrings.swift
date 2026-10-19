#if os(iOS)
import Foundation

// The release update's and What's new's texts: vettid-android's `release_update_*` and `release_notes_*`, word for word.
extension OnboardingStrings {
    static func releaseNotesTitle(_ release: Int) -> String {
        String(localized: "release_notes_title", defaultValue: "What's new in release \(release)", bundle: .module)
    }
    static var releaseNotesLoading: String {
        String(localized: "release_notes_loading", defaultValue: "Loading the release notes…", bundle: .module)
    }
    static var releaseNotesUnavailable: String {
        String(localized: "release_notes_unavailable", defaultValue: "Release notes unavailable", bundle: .module)
    }
    static var releaseNotesSecurityNone: String {
        String(localized: "release_notes_security_none", defaultValue: "No security fix", bundle: .module)
    }
    static var releaseNotesSecurityRecommended: String {
        String(localized: "release_notes_security_recommended", defaultValue: "Security fix: update recommended", bundle: .module)
    }
    static var releaseNotesSecurityUrgent: String {
        String(localized: "release_notes_security_urgent", defaultValue: "Security fix: update urgently", bundle: .module)
    }
    static var releaseNotesEarlier: String {
        String(localized: "release_notes_earlier", defaultValue: "Also in earlier releases", bundle: .module)
    }
    static func releaseNotesEarlierItem(_ release: Int, _ summary: String) -> String {
        String(localized: "release_notes_earlier_item", defaultValue: "Release \(release): \(summary)", bundle: .module)
    }
    static func releaseNotesFrom(_ host: String) -> String {
        String(localized: "release_notes_from", defaultValue: "From \(host)", bundle: .module)
    }
    static var releaseNotesInformation: String {
        String(
            localized: "release_notes_information",
            defaultValue: """
                Release notes are information. What keeps your vault safe is the signed release list and the fingerprint \
                below.
                """,
            bundle: .module
        )
    }
    static var releaseNotesFull: String {
        String(localized: "release_notes_full", defaultValue: "Full release notes", bundle: .module)
    }
    static var releaseUpdateTitle: String {
        String(localized: "release_update_title", defaultValue: "Update your vault", bundle: .module)
    }
    static func releaseUpdateBody(_ release: Int) -> String {
        String(
            localized: "release_update_body",
            defaultValue: """
                Approve release \(release) for your vault with your vault PIN.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateApprove: String {
        String(localized: "release_update_approve", defaultValue: "Approve and update", bundle: .module)
    }
    static var releaseUpdateHow: String {
        String(
            localized: "release_update_how",
            defaultValue: """
                VettID locks your vault, opens it again with your approval, and then opens it on the new release. This \
                takes a moment; a release that has to start first can take a few minutes. Your vault stays locked \
                meanwhile.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateEndedBody: String {
        String(
            localized: "release_update_ended_body",
            defaultValue: """
                It has ended and is open only so that you can move your vault. Update now to keep it.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateCheckFirstTitle: String {
        String(localized: "release_update_check_first_title", defaultValue: "Daily check first", bundle: .module)
    }
    static var releaseUpdateCheckFirstBody: String {
        String(
            localized: "release_update_check_first_body",
            defaultValue: """
                Your vault is waiting for its daily PIN and password check. Do the check first, then update.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateNoneTitle: String {
        String(localized: "release_update_none_title", defaultValue: "Your vault is up to date", bundle: .module)
    }
    static var releaseUpdateNoneBody: String {
        String(localized: "release_update_none_body", defaultValue: "Your vault runs the newest release.", bundle: .module)
    }
    static func releaseUpdateRunningTitle(_ release: Int) -> String {
        String(localized: "release_update_running_title", defaultValue: "Updating your vault to release \(release)…", bundle: .module)
    }
    static func releaseUpdateReturningTitle(_ release: Int) -> String {
        String(localized: "release_update_returning_title", defaultValue: "Returning to release \(release)…", bundle: .module)
    }
    static var releaseUpdateStepLock: String {
        String(localized: "release_update_step_lock", defaultValue: "Lock your vault", bundle: .module)
    }
    static func releaseUpdateStepApprove(_ from: Int, _ to: Int) -> String {
        String(localized: "release_update_step_approve", defaultValue: "Move from release \(from) to release \(to)", bundle: .module)
    }
    static func releaseUpdateStepOpen(_ release: Int) -> String {
        String(localized: "release_update_step_open", defaultValue: "Open your vault on release \(release)", bundle: .module)
    }
    static func releaseUpdateStepReturn(_ release: Int) -> String {
        String(localized: "release_update_step_return", defaultValue: "Opening your vault on release \(release)", bundle: .module)
    }
    static func releaseUpdateStarting(_ release: Int) -> String {
        String(
            localized: "release_update_starting",
            defaultValue: """
                Release \(release) is starting. This can take a few minutes.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateKeepOpen: String {
        String(localized: "release_update_keep_open", defaultValue: "Keep VettID open until this is done.", bundle: .module)
    }
    static var releaseUpdateDoneTitle: String {
        String(localized: "release_update_done_title", defaultValue: "Your vault is updated", bundle: .module)
    }
    static func releaseUpdateDoneBody(_ release: Int, _ fingerprint: String) -> String {
        String(
            localized: "release_update_done_body",
            defaultValue: """
                Your vault now runs release \(release) (fingerprint \(fingerprint)) and is open.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateContinue: String {
        String(localized: "release_update_continue", defaultValue: "Continue", bundle: .module)
    }
    static var releaseUpdateRefusedTitle: String {
        String(localized: "release_update_refused_title", defaultValue: "The update was refused", bundle: .module)
    }
    static func releaseUpdateRefusedBody(_ release: Int) -> String {
        String(
            localized: "release_update_refused_body",
            defaultValue: """
                Your vault stayed on release \(release) and is open.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateRefusedWhy: String {
        String(localized: "release_update_refused_why", defaultValue: "Why", bundle: .module)
    }
    static func releaseUpdateRefusedTarget(_ release: Int) -> String {
        String(
            localized: "release_update_refused_target",
            defaultValue: """
                Release \(release) is not an active release in the release list your vault trusts.
                """,
            bundle: .module
        )
    }
    static func releaseUpdateRefusedDowngrade(_ release: Int) -> String {
        String(
            localized: "release_update_refused_downgrade",
            defaultValue: """
                Release \(release) is not newer than your vault's release.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateRefusedApproval: String {
        String(
            localized: "release_update_refused_approval",
            defaultValue: """
                Your vault could not verify this phone's approval.
                """,
            bundle: .module
        )
    }
    static func releaseUpdateRefusedSealKey(_ release: Int) -> String {
        String(
            localized: "release_update_refused_seal_key",
            defaultValue: """
                Your vault did not accept the sealing key of release \(release).
                """,
            bundle: .module
        )
    }
    static var releaseUpdateRefusedPending: String {
        String(
            localized: "release_update_refused_pending",
            defaultValue: """
                Another update is already under way for your vault.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateRefusedWrite: String {
        String(
            localized: "release_update_refused_write",
            defaultValue: """
                Your vault could not record the update. Try again later.
                """,
            bundle: .module
        )
    }
    static func releaseUpdateRefusedOther(_ code: String) -> String {
        String(localized: "release_update_refused_other", defaultValue: "Your vault did not move (\(code)).", bundle: .module)
    }
    static var releaseUpdateFailedTitle: String {
        String(localized: "release_update_failed_title", defaultValue: "The update did not go through", bundle: .module)
    }
    static func releaseUpdateFailedBodyOpen(_ release: Int) -> String {
        String(
            localized: "release_update_failed_body_open",
            defaultValue: """
                Nothing changed: your vault stays on release \(release) and is open.
                """,
            bundle: .module
        )
    }
    static func releaseUpdateFailedBodyLockPending(_ release: Int) -> String {
        String(
            localized: "release_update_failed_body_lock_pending",
            defaultValue: """
                Nothing changed: your vault stays on release \(release). It could not be reached to lock it, so it may \
                still be open. This phone is locked, and VettID keeps trying to lock the vault.
                """,
            bundle: .module
        )
    }
    static func releaseUpdateFailedBodyLocked(_ release: Int) -> String {
        String(
            localized: "release_update_failed_body_locked",
            defaultValue: """
                Nothing changed: your vault stays on release \(release). It is locked; enter your PIN to try again.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateRetry: String {
        String(localized: "release_update_retry", defaultValue: "Try again", bundle: .module)
    }
    static var releaseUpdateNotNow: String {
        String(localized: "release_update_not_now", defaultValue: "Not now", bundle: .module)
    }
    static var releaseUpdateUnlockOnly: String {
        String(localized: "release_update_unlock_only", defaultValue: "Unlock without updating", bundle: .module)
    }
    static var releaseUpdateBackoff: String {
        String(localized: "release_update_backoff", defaultValue: "Too many wrong PINs. Wait, then try again.", bundle: .module)
    }
    static var releaseUpdateStartFailed: String {
        String(localized: "release_update_start_failed", defaultValue: "The new release did not start. Try again later.", bundle: .module)
    }
    static func releaseUpdateNewFailedTitle(_ release: Int) -> String {
        String(localized: "release_update_new_failed_title", defaultValue: "Release \(release) did not open your vault", bundle: .module)
    }
    static func releaseUpdateNewFailedBody(_ to: Int, _ from: Int) -> String {
        String(
            localized: "release_update_new_failed_body",
            defaultValue: """
                Your vault was moved to release \(to) but did not open there. Try again, or return to release \(from): \
                that is possible until release \(to) has opened your vault once.
                """,
            bundle: .module
        )
    }
    static func releaseUpdateNewFailedBodyNoReturn(_ to: Int) -> String {
        String(
            localized: "release_update_new_failed_body_no_return",
            defaultValue: """
                Your vault was moved to release \(to) but did not open there. Try again with your PIN.
                """,
            bundle: .module
        )
    }
    static var releaseUpdateNewFailedWhy: String {
        String(localized: "release_update_new_failed_why", defaultValue: "What happened", bundle: .module)
    }
    static func releaseUpdateReturn(_ release: Int) -> String {
        String(localized: "release_update_return", defaultValue: "Return to release \(release)", bundle: .module)
    }
    static func releaseUpdateReturnConfirmTitle(_ release: Int) -> String {
        String(localized: "release_update_return_confirm_title", defaultValue: "Return to release \(release)?", bundle: .module)
    }
    static func releaseUpdateReturnConfirmBody(_ from: Int, _ to: Int) -> String {
        String(
            localized: "release_update_return_confirm_body",
            defaultValue: """
                Your vault goes back to release \(from) and opens there. You can approve release \(to) again later.
                """,
            bundle: .module
        )
    }
    static func releaseUpdateAbandonedTitle(_ release: Int) -> String {
        String(localized: "release_update_abandoned_title", defaultValue: "Back on release \(release)", bundle: .module)
    }
    static func releaseUpdateAbandonedBody(_ from: Int, _ to: Int) -> String {
        String(
            localized: "release_update_abandoned_body",
            defaultValue: """
                Your vault runs release \(from) again and is open. You can update to release \(to) later.
                """,
            bundle: .module
        )
    }
}
#endif
