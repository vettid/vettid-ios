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
            defaultValue: "Your vault can no longer be opened, but VettID has not finished deleting it yet. Check back later.",
            bundle: .module
        )
    }
    static var vaultDeletingCheckAgain: String {
        String(localized: "vault_deleting_check_again", defaultValue: "Check again", bundle: .module)
    }
    static var vaultDeletingStill: String {
        String(localized: "vault_deleting_still", defaultValue: "Not finished yet. Try again later.", bundle: .module)
    }
    static var vaultDeletingUnreachable: String {
        String(
            localized: "vault_deleting_unreachable", defaultValue: "VettID couldn't be reached. Check your connection and try again.",
            bundle: .module
        )
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
