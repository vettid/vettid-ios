#if os(iOS)
import Foundation
import VettIDData

// The unlock screen's texts for a refused update and a refused way back, and the start screen's slow state.
extension OnboardingStrings {
    /// Android's `unlock_update_refused`, with the code filtered (never a raw word of the wire).
    static func unlockUpdateRefused(code: String) -> String {
        String(
            localized: "unlock_update_refused",
            defaultValue: "The update was refused (\(FailureKind.shownCode(code))). Your vault stayed on its current release.",
            bundle: .module
        )
    }
    /// The iPhone's text for a refusal it can say in words (``refusalText(_:_:)``); [why] is that sentence (chosen; not in the
    /// spec, where vettid-android shows the code).
    static func unlockUpdateRefusedWhy(_ why: String) -> String {
        String(
            localized: "ios_unlock_update_refused_why",
            defaultValue: "The update was refused. \(why) Your vault stayed on its current release.",
            bundle: .module
        )
    }

    /// The codes ``refusalText(_:_:)`` has a sentence for, and whether that sentence names the release.
    private static let refusalNeedsRelease: [String: Bool] = [
        "target": true, "downgrade": true, "seal_key": true, "approval": false, "pending": false, "write": false,
    ]

    /// What the unlock screen says of a refused update: the sentence for a code it knows (with the refused release's own
    /// number), else Android's text with the filtered code.
    static func unlockUpdateRefusedText(code: String, release: Int?) -> String {
        if let needs = refusalNeedsRelease[code], !needs || release != nil {
            return unlockUpdateRefusedWhy(refusalText(code, release ?? 0))
        }
        return unlockUpdateRefused(code: code)
    }

    static var rootStartingSlowTitle: String {
        String(localized: "ios_root_starting_slow_title", defaultValue: "Still opening your vault", bundle: .module)
    }
    static var rootStartingSlowBody: String {
        String(
            localized: "ios_root_starting_slow_body",
            defaultValue: "This is taking longer than usual. VettID keeps trying, or you can try again.",
            bundle: .module
        )
    }

    static var returnRefusedUpdateRunning: String {
        String(
            localized: "ios_unlock_return_update_running",
            defaultValue: "An update is already running. Try again when it has ended.",
            bundle: .module
        )
    }
    static var returnRefusedCheckFirst: String {
        String(
            localized: "ios_unlock_return_check_first",
            defaultValue: "Your daily check comes first. Do it, then return to the earlier release.",
            bundle: .module
        )
    }
    static var returnRefusedChangeHeld: String {
        String(
            localized: "ios_unlock_return_change_held",
            defaultValue: "A change of your PIN or password is still being decided. Try again when it has been.",
            bundle: .module
        )
    }
    static var returnRefusedGone: String {
        String(
            localized: "ios_unlock_return_gone",
            defaultValue: "There is no earlier release to return to any more.",
            bundle: .module
        )
    }
    static func returnRefused(_ r: ReturnRefusal) -> String {
        switch r {
        case .updateRunning: returnRefusedUpdateRunning
        case .ownerCheckFirst: returnRefusedCheckFirst
        case .changeHeld: returnRefusedChangeHeld
        case .nothingToReturnTo: returnRefusedGone
        }
    }
}
#endif
