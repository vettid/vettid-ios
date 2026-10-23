import Foundation

/// The move to this phone: the transfer from the old phone and "Finish the move" (vettid-android `feature/onboarding`
/// `strings.xml`, word for word). The key `onboarding_moved_recovered_body` comes with the recovery screens.
enum MoveStrings {
    static var transferInTitle: String {
        String(localized: "transfer_in_title", defaultValue: "Move from your old phone", bundle: .module)
    }

    static var transferInBody: String {
        String(
            localized: "transfer_in_body",
            defaultValue: """
                On your old phone, open VettID, then Settings, then Move to a new phone. It shows a code: scan it \
                with this phone.
                """,
            bundle: .module
        )
    }

    static var transferInNeedBody: String {
        String(
            localized: "transfer_in_need_body",
            defaultValue: """
                You will approve the move on the old phone with your vault PIN and credential password. The old \
                phone then erases VettID.
                """,
            bundle: .module
        )
    }

    static var transferInScan: String {
        String(localized: "transfer_in_scan", defaultValue: "Scan the code", bundle: .module)
    }

    static var transferInPaste: String {
        String(localized: "transfer_in_paste", defaultValue: "Paste the code instead", bundle: .module)
    }

    static var transferInScanTitle: String {
        String(localized: "transfer_in_scan_title", defaultValue: "Scan your old phone's code", bundle: .module)
    }

    static var transferInScanBody: String {
        String(
            localized: "transfer_in_scan_body",
            defaultValue: """
                Point the camera at the code your old phone shows.
                """,
            bundle: .module
        )
    }

    static var transferInPasteTitle: String {
        String(localized: "transfer_in_paste_title", defaultValue: "Paste the code", bundle: .module)
    }

    static var transferInPasteBody: String {
        String(
            localized: "transfer_in_paste_body",
            defaultValue: """
                On the old phone, copy the code under the QR code and paste it here.
                """,
            bundle: .module
        )
    }

    static var transferInPasteLabel: String {
        String(localized: "transfer_in_paste_label", defaultValue: "Transfer code", bundle: .module)
    }

    static var transferInPasteSubmit: String {
        String(localized: "transfer_in_paste_submit", defaultValue: "Continue", bundle: .module)
    }

    static var transferInNotTransfer: String {
        String(
            localized: "transfer_in_not_transfer",
            defaultValue: """
                That is not a transfer code. On your old phone, open Settings, then Move to a new phone.
                """,
            bundle: .module
        )
    }

    static var transferInExpiredCode: String {
        String(
            localized: "transfer_in_expired_code",
            defaultValue: """
                That code has expired. Show a new one on your old phone.
                """,
            bundle: .module
        )
    }

    static var transferInConnecting: String {
        String(localized: "transfer_in_connecting", defaultValue: "Connecting to your vault", bundle: .module)
    }

    static var transferInCompareTitle: String {
        String(localized: "transfer_in_compare_title", defaultValue: "Compare the code", bundle: .module)
    }

    static var transferInCompareBody: String {
        String(
            localized: "transfer_in_compare_body",
            defaultValue: """
                Your old phone shows a code too. If they are the same, approve the move there with your PIN and \
                credential password.
                """,
            bundle: .module
        )
    }

    static func transferInWaiting(_ a: String) -> String {
        String(localized: "transfer_in_waiting", defaultValue: "Waiting for your old phone (\(a) left)", bundle: .module)
    }

    static var transferInCancel: String {
        String(localized: "transfer_in_cancel", defaultValue: "Cancel", bundle: .module)
    }

    static var transferInRejectedTitle: String {
        String(localized: "transfer_in_rejected_title", defaultValue: "Rejected on your phone", bundle: .module)
    }

    static var transferInRejectedBody: String {
        String(
            localized: "transfer_in_rejected_body",
            defaultValue: """
                The move was rejected on your old phone. Nothing changed: your vault stays with your old phone. To \
                try again, show a new code on the old phone.
                """,
            bundle: .module
        )
    }

    static var transferInTimeoutTitle: String {
        String(localized: "transfer_in_timeout_title", defaultValue: "The transfer timed out", bundle: .module)
    }

    static var transferInTimeoutBody: String {
        String(
            localized: "transfer_in_timeout_body",
            defaultValue: """
                It was not approved within 10 minutes. Nothing changed. Show a new code on your old phone to try \
                again.
                """,
            bundle: .module
        )
    }

    static var transferInNoAnswer: String {
        String(
            localized: "transfer_in_no_answer",
            defaultValue: """
                Your vault did not answer. The code may have been used already, or this phone could not be verified. \
                Show a new code on your old phone.
                """,
            bundle: .module
        )
    }

    static var transferInAgain: String {
        String(localized: "transfer_in_again", defaultValue: "Try again", bundle: .module)
    }

    static var transferInNoAnswerTitle: String {
        String(localized: "transfer_in_no_answer_title", defaultValue: "No answer from your vault", bundle: .module)
    }

    static var transferInScanNew: String {
        String(localized: "transfer_in_scan_new", defaultValue: "Scan a new code", bundle: .module)
    }

    static var onboardingFinishMoveBody: String {
        String(
            localized: "onboarding_finish_move_body",
            defaultValue: """
                Enter your PIN on this phone to finish moving your vault.
                """,
            bundle: .module
        )
    }

    static var onboardingFinishMoveDone: String {
        String(localized: "onboarding_finish_move_done", defaultValue: "Your vault is on this phone now.", bundle: .module)
    }

    static var onboardingFinishMoveLater: String {
        String(localized: "onboarding_finish_move_later", defaultValue: "Later", bundle: .module)
    }

    static var onboardingMovedTitle: String {
        String(localized: "onboarding_moved_title", defaultValue: "Your vault is connected to this phone now", bundle: .module)
    }

    static var onboardingMovedTransferredBody: String {
        String(
            localized: "onboarding_moved_transferred_body",
            defaultValue: """
                Your vault now works with the credential on this phone. Your old phone erases VettID as soon as it \
                hears from your vault. Unlock with the same PIN and credential password as before.
                """,
            bundle: .module
        )
    }

    static var onboardingMovedTransferredNoGuidBody: String {
        String(
            localized: "onboarding_moved_transferred_no_guid_body",
            defaultValue: """
                Your vault now works with the credential on this phone. Your old phone erases VettID as soon as it \
                hears from your vault. Your vault runs an older release, so this phone cannot unlock it after it \
                locks until your vault is updated.
                """,
            bundle: .module
        )
    }

    static var onboardingMovedGo: String {
        String(localized: "onboarding_moved_go", defaultValue: "Go to VettID", bundle: .module)
    }

    static var moveBack: String {
        String(localized: "move_back", defaultValue: "Back", bundle: .module)
    }

    static var recoverNeedTitle: String {
        String(localized: "recover_need_title", defaultValue: "You will need", bundle: .module)
    }

    static var recoverFailedTitle: String {
        String(localized: "recover_failed_title", defaultValue: "Something went wrong", bundle: .module)
    }
}
