#if os(iOS)
import Foundation

// A vault being deleted (IOS-PLAN §4.2) and the way back to release N (IOS-PLAN §4.3): the texts of their tables, word
// for word, under the ids vettid-android names (ANDROID-PLAN 0.1.54 §4). "Check again" has no id in the table:
// `vault_deleting_check_again` (chosen; not in the spec).
extension OnboardingStrings {
    static var vaultDeletingTitle: String {
        String(localized: "vault_deleting_title", defaultValue: "Your vault is being deleted", bundle: .module)
    }
    static var vaultDeletingBody: String {
        String(
            localized: "vault_deleting_body",
            defaultValue: """
                VettID is erasing everything in your vault. This usually takes a few minutes. Nothing in it can be opened or \
                restored. You will get an email when it is done.
                """,
            bundle: .module
        )
    }
    static var vaultDeletingSlowTitle: String {
        String(localized: "vault_deleting_slow_title", defaultValue: "Still finishing", bundle: .module)
    }
    static var vaultDeletingSlowBody: String {
        String(
            localized: "vault_deleting_slow_body",
            defaultValue: """
                Your vault can no longer be opened, but this phone cannot confirm that VettID has finished deleting it. When \
                you get the email that your vault was deleted, or the account site offers to set up a new vault, remove VettID from \
                this phone.
                """,
            bundle: .module
        )
    }
    static var vaultDeletingCheckAgain: String {
        String(localized: "vault_deleting_check_again", defaultValue: "Check again", bundle: .module)
    }
    static var vaultDeletingStill: String {
        String(
            localized: "vault_deleting_still",
            defaultValue: "VettID has not finished yet. Tap Check again later, or check the account site.", bundle: .module
        )
    }
    static var vaultDeletingUnreachable: String {
        String(
            localized: "vault_deleting_unreachable", defaultValue: "VettID couldn't be reached. Check your connection and try again.",
            bundle: .module
        )
    }
    // The texts of vettid-android's unmerged branch `fix/no-erase-on-401` (drafts for the owner's approval).
    static var vaultDeletingUnconfirmed: String {
        String(localized: "vault_deleting_unconfirmed", defaultValue: "This phone can't confirm it yet.", bundle: .module)
    }
    static var vaultDeletingCannotConfirm: String {
        String(
            localized: "vault_deleting_cannot_confirm",
            defaultValue: """
                VettID answered, but this phone cannot confirm that the deletion is finished. When you get the \
                email that your vault was deleted, or the account site offers to set up a new vault, remove VettID from this phone.
                """,
            bundle: .module
        )
    }
    static var vaultDeletingClockHint: String {
        String(
            localized: "vault_deleting_clock_hint",
            defaultValue: "Also check that the date and time on this phone are right.", bundle: .module
        )
    }
    static var vaultDeletingRemove: String {
        String(localized: "vault_deleting_remove", defaultValue: "Remove from this phone", bundle: .module)
    }
    static var vaultDeletingRemoveConfirmTitle: String {
        String(localized: "vault_deleting_remove_confirm_title", defaultValue: "Remove VettID from this phone?", bundle: .module)
    }
    static var vaultDeletingRemoveConfirmBody: String {
        String(
            localized: "vault_deleting_remove_confirm_body",
            defaultValue: """
                Your vault can never be opened again, and nothing on this phone is needed to finish deleting it. \
                This removes VettID's data on this phone only: its keys, your account details and the app's settings. It works without a \
                connection and cannot be undone.
                """,
            bundle: .module
        )
    }
    static var vaultDeletingRemoveConfirm: String {
        String(localized: "vault_deleting_remove_confirm", defaultValue: "Remove", bundle: .module)
    }
    static var vaultDeletingAccountSite: String {
        String(localized: "vault_deleting_account_site", defaultValue: "Open the account site", bundle: .module)
    }
    static var vaultDeletedNotice: String {
        String(
            localized: "vault_deleted_notice",
            defaultValue: "Your vault was deleted. To start again, get a setup code on the account site.",
            bundle: .module
        )
    }

    static func unlockMoveUnconfirmed(_ to: Int, _ from: Int) -> String {
        String(
            localized: "unlock_move_unconfirmed",
            defaultValue: """
                Your vault moved to release \(to) and has not opened there yet. You can try again with your PIN, or return to \
                release \(from).
                """,
            bundle: .module
        )
    }
    static func releaseUpdateRoutePending(_ to: Int) -> String {
        String(
            localized: "release_update_route_pending",
            defaultValue: "Your vault moved to release \(to), but VettID is not ready to open it there yet. Try again in a minute.",
            bundle: .module
        )
    }
    static func releaseUpdateReturnConfirmed(_ to: Int, _ from: Int) -> String {
        String(
            localized: "release_update_return_confirmed",
            defaultValue: "Release \(to) has already opened your vault, so it can't go back to release \(from). Unlock it with your PIN.",
            bundle: .module
        )
    }
    static func releaseUpdateReturnUnavailable(_ from: Int) -> String {
        String(
            localized: "release_update_return_unavailable",
            defaultValue: """
                Release \(from) is no longer available, so your vault can't go back to it. Try again with your PIN, or contact \
                VettID.
                """,
            bundle: .module
        )
    }
}
#endif
