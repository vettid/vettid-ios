import Foundation

/// Move to a new phone, the old phone's side (vettid-android `feature/settings` `strings.xml`, word for word; the signer
/// confirmation's own texts are `VettIDData`'s ``SignerText``).
enum TransferStrings {
    static var transferTitle: String {
        String(localized: "settings_transfer_title", defaultValue: "Move to a new phone", bundle: .module)
    }

    static var transferBody: String {
        String(
            localized: "settings_transfer_body",
            defaultValue: """
                Move VettID to a new phone: your credential moves there, and your vault and your connections then \
                work with the new phone. This phone then erases VettID and keeps nothing of it.
                """,
            bundle: .module
        )
    }

    static var transferStepsTitle: String {
        String(localized: "settings_transfer_steps_title", defaultValue: "How it works", bundle: .module)
    }

    static var transferStepsBody: String {
        String(
            localized: "settings_transfer_steps_body",
            defaultValue: """
                1. On the new phone, install VettID, choose Move from my old phone and sign in to your account.
                2. Show the code here and scan it with the new phone.
                3. Check that both phones show the same 6 digits, then approve here with your vault PIN and \
                credential password.
                """,
            bundle: .module
        )
    }

    static var transferLost: String {
        String(
            localized: "settings_transfer_lost",
            defaultValue: """
                Lost your old phone instead? Start a recovery on the account site.
                """,
            bundle: .module
        )
    }

    static var transferStart: String {
        String(localized: "settings_transfer_start", defaultValue: "Show the code", bundle: .module)
    }

    static var transferShowTitle: String {
        String(localized: "settings_transfer_show_title", defaultValue: "Scan this code with your new phone", bundle: .module)
    }

    static var transferShowBody: String {
        String(
            localized: "settings_transfer_show_body",
            defaultValue: """
                On the new phone, choose Move from my old phone, then scan. Only your new phone should see this \
                code.
                """,
            bundle: .module
        )
    }

    static var transferQrCd: String {
        String(localized: "settings_transfer_qr_cd", defaultValue: "Transfer code for your new phone", bundle: .module)
    }

    static func transferExpires(_ a: String) -> String {
        String(localized: "settings_transfer_expires", defaultValue: "Valid for \(a) more", bundle: .module)
    }

    static var transferLinkLabel: String {
        String(localized: "settings_transfer_link_label", defaultValue: "Or paste this code on the new phone", bundle: .module)
    }

    static var transferCopy: String {
        String(localized: "settings_transfer_copy", defaultValue: "Copy", bundle: .module)
    }

    static var transferCopied: String {
        String(localized: "settings_transfer_copied", defaultValue: "Copied", bundle: .module)
    }

    static var transferWaiting: String {
        String(localized: "settings_transfer_waiting", defaultValue: "Waiting for your new phone", bundle: .module)
    }

    static var transferCancel: String {
        String(localized: "settings_transfer_cancel", defaultValue: "Cancel the transfer", bundle: .module)
    }

    static var transferCompareTitle: String {
        String(localized: "settings_transfer_compare_title", defaultValue: "Compare the code", bundle: .module)
    }

    static func transferCompareBody(_ a: String) -> String {
        String(
            localized: "settings_transfer_compare_body",
            defaultValue: """
                \(a) wants to take over your vault. Continue only if it shows the same code.
                """,
            bundle: .module
        )
    }

    static var transferMatch: String {
        String(localized: "settings_transfer_match", defaultValue: "The codes match", bundle: .module)
    }

    static var transferReject: String {
        String(localized: "settings_transfer_reject", defaultValue: "Reject", bundle: .module)
    }

    static var transferRejectTitle: String {
        String(localized: "settings_transfer_reject_title", defaultValue: "Reject the transfer?", bundle: .module)
    }

    static var transferRejectBody: String {
        String(
            localized: "settings_transfer_reject_body",
            defaultValue: """
                Nothing changes: your vault stays with this phone. The new phone is told it was rejected.
                """,
            bundle: .module
        )
    }

    static var transferSignerTitle: String {
        String(
            localized: "settings_transfer_signer_title",
            defaultValue: """
                The new phone has another version of VettID
                """,
            bundle: .module
        )
    }

    static var transferSignerContinue: String {
        String(localized: "settings_transfer_signer_continue", defaultValue: "Continue", bundle: .module)
    }

    static var transferSignerCancel: String {
        String(localized: "settings_transfer_signer_cancel", defaultValue: "Cancel", bundle: .module)
    }

    static var transferSignerUnconfirmed: String {
        String(
            localized: "settings_transfer_signer_unconfirmed",
            defaultValue: """
                Your vault asked you to confirm the new phone's version of VettID first. Nothing was counted; enter \
                your PIN and password again.
                """,
            bundle: .module
        )
    }

    static var transferApproveTitle: String {
        String(localized: "settings_transfer_approve_title", defaultValue: "Approve the move", bundle: .module)
    }

    static func transferApproveBody(_ a: String) -> String {
        String(
            localized: "settings_transfer_approve_body",
            defaultValue: """
                Your vault checks your PIN and your credential password, then moves your credential to \(a). This \
                phone then erases VettID and returns to the welcome screen, as if freshly installed.
                """,
            bundle: .module
        )
    }

    static var transferPin: String {
        String(localized: "settings_transfer_pin", defaultValue: "Vault PIN", bundle: .module)
    }

    static var transferPassword: String {
        String(localized: "settings_transfer_password", defaultValue: "Credential password", bundle: .module)
    }

    static var transferApprove: String {
        String(localized: "settings_transfer_approve", defaultValue: "Move to the new phone", bundle: .module)
    }

    /// The new phone in a sentence when its name is nothing but invisible characters (chosen; not in the spec; mirrors
    /// vettid-android `settings_transfer_unnamed_device`).
    static var transferUnnamedDevice: String {
        String(localized: "settings_transfer_unnamed_device", defaultValue: "The other phone", bundle: .module)
    }

    static func transferApproveConfirmTitle(_ a: String) -> String {
        String(localized: "settings_transfer_approve_confirm_title", defaultValue: "Move VettID to \(a)?", bundle: .module)
    }

    static var transferApproveConfirmBody: String {
        String(
            localized: "settings_transfer_approve_confirm_body",
            defaultValue: """
                This phone will no longer hold your credential or open your vault, and VettID erases everything it \
                kept here. You cannot undo this from here.
                """,
            bundle: .module
        )
    }

    static var transferApproveConfirm: String {
        String(localized: "settings_transfer_approve_confirm", defaultValue: "Move", bundle: .module)
    }

    static func transferWindow(_ a: String) -> String {
        String(localized: "settings_transfer_window", defaultValue: "\(a) left to approve", bundle: .module)
    }

    static var transferBadPin: String {
        String(localized: "settings_transfer_bad_pin", defaultValue: "That PIN is not correct.", bundle: .module)
    }

    static var transferBadPassword: String {
        String(localized: "settings_transfer_bad_password", defaultValue: "That password is not correct.", bundle: .module)
    }

    static func transferWait(_ a: String) -> String {
        String(localized: "settings_transfer_wait", defaultValue: "Too many wrong tries. Try again in \(a).", bundle: .module)
    }

    static var transferExpiredTitle: String {
        String(localized: "settings_transfer_expired_title", defaultValue: "The code expired", bundle: .module)
    }

    static var transferExpiredBody: String {
        String(
            localized: "settings_transfer_expired_body",
            defaultValue: """
                Nothing changed: your vault stays with this phone. Show a new code to try again.
                """,
            bundle: .module
        )
    }

    static var transferAgain: String {
        String(localized: "settings_transfer_again", defaultValue: "Show a new code", bundle: .module)
    }

    static var transferRejectedTitle: String {
        String(localized: "settings_transfer_rejected_title", defaultValue: "Transfer rejected", bundle: .module)
    }

    static var transferRejectedBody: String {
        String(
            localized: "settings_transfer_rejected_body",
            defaultValue: """
                Nothing changed: your vault stays with this phone.
                """,
            bundle: .module
        )
    }

    static var transferMovedTitle: String {
        String(localized: "settings_transfer_moved_title", defaultValue: "VettID has moved", bundle: .module)
    }

    static func transferMovedBody(_ a: String) -> String {
        String(
            localized: "settings_transfer_moved_body",
            defaultValue: """
                Your vault works with \(a) now. This phone erases VettID as soon as your vault confirms the move; \
                keep it online for a moment.
                """,
            bundle: .module
        )
    }

    static var transferExists: String {
        String(
            localized: "settings_transfer_exists",
            defaultValue: """
                Another transfer is already open. It ends within 10 minutes; try again then.
                """,
            bundle: .module
        )
    }

    static var transferAlarm: String {
        String(
            localized: "settings_transfer_alarm",
            defaultValue: """
                Your credential has an open clone alarm. Resolve it in Credential before moving to a new phone.
                """,
            bundle: .module
        )
    }

    static var transferMovedKeptBody: String {
        String(
            localized: "settings_transfer_moved_kept_body",
            defaultValue: """
                Finish the move on your new phone. This phone keeps your vault's keys until your new phone has \
                finished the move, and until your vault has confirmed it. Once your new phone works, you can remove \
                VettID from this phone. Before you give this phone away, remove VettID from it or reset it.
                """,
            bundle: .module
        )
    }

    static var securityTransfer: String {
        String(localized: "settings_security_transfer", defaultValue: "Move to a new phone", bundle: .module)
    }

    static var securityTransferBody: String {
        String(
            localized: "settings_security_transfer_body",
            defaultValue: """
                Direct transfer: no waiting, with your PIN and password
                """,
            bundle: .module
        )
    }

    static var securityRecovery: String {
        String(localized: "settings_security_recovery", defaultValue: "Recovery", bundle: .module)
    }
}
