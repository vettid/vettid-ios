import Foundation

// swiftlint:disable line_length

/// The texts of pairing an agent (ANDROID-PLAN 0.1.53 AA2, approved by the owner 2026-10-26) and of "Pair a desktop" (vettid-android
/// #291, owner decision 2026-11-05: its texts are new and not yet approved there): every string of vettid-android
/// `feature/devices` `strings.xml` of those two, word for word under the same names, in `Localizable.xcstrings`. A changed text is
/// the owner's to approve (``DeviceStringsTests``). "Choose what it may use" and "Later" (AA4) are not here.
extension DeviceStrings {
    public static var devicesPair: String {
        String(localized: "devices_pair", defaultValue: "Pair an agent", bundle: .module)
    }

    public static var pairTitle: String {
        String(localized: "pair_title", defaultValue: "Pair an agent", bundle: .module)
    }

    public static var pairCodeBody: String {
        String(localized: "pair_code_body", defaultValue: "Copy this code to the computer where the agent runs. It works once and expires in 10 minutes.", bundle: .module)
    }

    public static var pairQrCd: String {
        String(localized: "pair_qr_cd", defaultValue: "Pairing code as a QR code", bundle: .module)
    }

    public static var pairCreating: String {
        String(localized: "pair_creating", defaultValue: "Making a pairing code", bundle: .module)
    }

    public static var pairClipLabel: String {
        String(localized: "pair_clip_label", defaultValue: "Pairing code", bundle: .module)
    }

    public static var pairCopy: String {
        String(localized: "pair_copy", defaultValue: "Copy", bundle: .module)
    }

    public static var pairCopied: String {
        String(localized: "pair_copied", defaultValue: "Copied", bundle: .module)
    }

    public static var pairShare: String {
        String(localized: "pair_share", defaultValue: "Share", bundle: .module)
    }

    public static var pairShareTitle: String {
        String(localized: "pair_share_title", defaultValue: "Send it only to yourself.", bundle: .module)
    }

    public static func pairExpiresIn(_ a1: String) -> String {
        String(localized: "pair_expires_in", defaultValue: "Expires in \(a1)", bundle: .module)
    }

    public static var pairExpired: String {
        String(localized: "pair_expired", defaultValue: "This code expired.", bundle: .module)
    }

    public static var pairNewCode: String {
        String(localized: "pair_new_code", defaultValue: "New code", bundle: .module)
    }

    public static var pairCancel: String {
        String(localized: "pair_cancel", defaultValue: "Cancel", bundle: .module)
    }

    public static var pairCreateFailed: String {
        String(localized: "pair_create_failed", defaultValue: "A pairing code could not be made. Try again.", bundle: .module)
    }

    public static var pairTryAgain: String {
        String(localized: "pair_try_again", defaultValue: "Try again", bundle: .module)
    }

    public static var pairCheckNow: String {
        String(localized: "pair_check_now", defaultValue: "Check now", bundle: .module)
    }

    public static var pairCompareTitle: String {
        String(localized: "pair_compare_title", defaultValue: "Compare the code", bundle: .module)
    }

    public static func pairCompareBody(_ a1: String) -> String {
        String(localized: "pair_compare_body", defaultValue: "Does the agent show \(a1)? Approve only if the codes match.", bundle: .module)
    }

    public static func pairCallsItself(_ a1: String) -> String {
        String(localized: "pair_calls_itself", defaultValue: "It calls itself \(a1).", bundle: .module)
    }

    public static var pairCallsItselfNote: String {
        String(localized: "pair_calls_itself_note", defaultValue: "The code proves this phone talks to the agent you just gave the code to. The name is only what the agent says about itself.", bundle: .module)
    }

    public static var pairCodesMatch: String {
        String(localized: "pair_codes_match", defaultValue: "The codes match", bundle: .module)
    }

    public static var pairCodesDiffer: String {
        String(localized: "pair_codes_differ", defaultValue: "They don't match", bundle: .module)
    }

    public static var pairReject: String {
        String(localized: "pair_reject", defaultValue: "Reject", bundle: .module)
    }

    public static var pairCannotCompare: String {
        String(localized: "pair_cannot_compare", defaultValue: "This phone can't show a code to compare for this pairing, so it can't be approved. Reject it.", bundle: .module)
    }

    public static var pairRejectedTitle: String {
        String(localized: "pair_rejected_title", defaultValue: "Pairing rejected", bundle: .module)
    }

    public static var pairRejectedBody: String {
        String(localized: "pair_rejected_body", defaultValue: "The agent is told it was rejected. If you did not expect a code, someone else may have the pairing code; it no longer works.", bundle: .module)
    }

    public static var pairRejectedUnsent: String {
        String(localized: "pair_rejected_unsent", defaultValue: "Nothing is paired. Your vault could not be told, so the pairing ends by itself within 10 minutes. If you did not expect a code, someone else may have the pairing code.", bundle: .module)
    }

    public static var pairDone: String {
        String(localized: "pair_done", defaultValue: "Done", bundle: .module)
    }

    public static var pairLostTitle: String {
        String(localized: "pair_lost_title", defaultValue: "A device asks to pair", bundle: .module)
    }

    public static var pairLostBody: String {
        String(localized: "pair_lost_body", defaultValue: "This pairing can't be checked on this phone any more. Let it expire: it ends by itself within 10 minutes and nothing is paired. If you want to pair, start again.", bundle: .module)
    }

    public static var pairAllowTitle: String {
        String(localized: "pair_allow_title", defaultValue: "Allow access now?", bundle: .module)
    }

    public static var pairAllowBody: String {
        String(localized: "pair_allow_body", defaultValue: "Agents act only while you allow access, and only within the permissions you give them.", bundle: .module)
    }

    public static var pairSessionNone: String {
        String(localized: "pair_session_none", defaultValue: "No access yet", bundle: .module)
    }

    public static var pairSession15m: String {
        String(localized: "pair_session_15m", defaultValue: "15 minutes", bundle: .module)
    }

    public static var pairSession1h: String {
        String(localized: "pair_session_1h", defaultValue: "1 hour", bundle: .module)
    }

    public static var pairSession4h: String {
        String(localized: "pair_session_4h", defaultValue: "4 hours", bundle: .module)
    }

    public static var pairSession8h: String {
        String(localized: "pair_session_8h", defaultValue: "8 hours", bundle: .module)
    }

    public static var pairSession24h: String {
        String(localized: "pair_session_24h", defaultValue: "24 hours", bundle: .module)
    }

    public static var pairConfirm: String {
        String(localized: "pair_confirm", defaultValue: "Pair", bundle: .module)
    }

    public static var pairEndedTitle: String {
        String(localized: "pair_ended_title", defaultValue: "Not paired", bundle: .module)
    }

    public static var pairEnded: String {
        String(localized: "pair_ended", defaultValue: "This pairing has ended. Start again from Devices & agents.", bundle: .module)
    }

    public static var pairUnconfirmedTitle: String {
        String(localized: "pair_unconfirmed_title", defaultValue: "Pairing not confirmed", bundle: .module)
    }

    public static func pairUnconfirmedBody(_ a1: String) -> String {
        String(localized: "pair_unconfirmed_body", defaultValue: "Your vault did not answer. If \(a1) is listed in Devices & agents, it was paired; if not, start again.", bundle: .module)
    }

    public static func pairPairedTitle(_ a1: String) -> String {
        String(localized: "pair_paired_title", defaultValue: "\(a1) is paired", bundle: .module)
    }

    public static var pairPairedBody: String {
        String(localized: "pair_paired_body", defaultValue: "It can't use any of your items yet.", bundle: .module)
    }

    public static var pairOpenPage: String {
        String(localized: "pair_open_page", defaultValue: "Open its page", bundle: .module)
    }

    // Pair a desktop (vettid-android #291): new texts, not in the plan, not yet approved there.

    public static var devicesPairNew: String {
        String(localized: "devices_pair_new", defaultValue: "Pair an agent or desktop", bundle: .module)
    }

    public static var devicesEmptyTitleAny: String {
        String(localized: "devices_empty_title_any", defaultValue: "Nothing paired yet", bundle: .module)
    }

    public static var devicesEmptyBodyAny: String {
        String(localized: "devices_empty_body_any", defaultValue: "Pair VettID on your computer, or pair an agent to let an AI assistant use items you choose. They act only while you allow access.", bundle: .module)
    }

    public static var devicesPairDesktop: String {
        String(localized: "devices_pair_desktop", defaultValue: "Pair a desktop", bundle: .module)
    }

    public static var pairTitleDesktop: String {
        String(localized: "pair_title_desktop", defaultValue: "Pair a desktop", bundle: .module)
    }

    public static var pairCodeBodyDesktop: String {
        String(localized: "pair_code_body_desktop", defaultValue: "Copy this code into VettID on your computer. It works once and expires in 10 minutes.", bundle: .module)
    }

    public static func pairCompareBodyDesktop(_ a1: String) -> String {
        String(localized: "pair_compare_body_desktop", defaultValue: "Does the desktop show \(a1)? Approve only if the codes match.", bundle: .module)
    }

    public static var pairCallsItselfNoteDesktop: String {
        String(localized: "pair_calls_itself_note_desktop", defaultValue: "The code proves this phone talks to the desktop you just gave the code to. The name is only what the desktop says about itself.", bundle: .module)
    }

    public static var pairRejectedBodyDesktop: String {
        String(localized: "pair_rejected_body_desktop", defaultValue: "The desktop is told it was rejected. If you did not expect a code, someone else may have the pairing code; it no longer works.", bundle: .module)
    }

    public static var pairAllowBodyDesktop: String {
        String(localized: "pair_allow_body_desktop", defaultValue: "A desktop acts only while you allow access.", bundle: .module)
    }

    public static var pairPairedBodyDesktop: String {
        String(localized: "pair_paired_body_desktop", defaultValue: "When it asks for access, the request comes to Approvals.", bundle: .module)
    }

    /// "N minute(s) left": said once a minute to a screen reader while the code counts down.
    public static func pairMinutesLeft(_ a1: Int) -> String {
        String(localized: "pair_minutes_left", defaultValue: "\(a1) minutes left", bundle: .module)
    }
}
// swiftlint:enable line_length
