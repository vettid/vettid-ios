#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

// The notices of the recovery's code steps. Mirrors the private composables of vettid-android `MoveScreens.kt`
// (`CodeRefusalNotice`, `ClaimFailure`, `Failure`).

/// Why the code was refused, if it was (§11.11.3). Announced politely when it appears.
struct CodeRefusalNotice: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: RecoverState

    var body: some View {
        if let r = state.refusal {
            let mild = r == .badCode || r == .notACode || r == .retry
            NoticeCard(
                mild ? .warning : .urgent, title: MoveStrings.recoverFailedTitle,
                message: RecoveryTexts.refusal(r, state, timeScale: timeScale), announce: .polite
            )
            .accessibilityIdentifier("code_refused")
        }
    }
}

/// A failure of the claim or the register: the guidance of the data layer's refusals, else the failure's own text, with
/// the wait a `429` asked for.
struct ClaimFailure: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: RecoverState
    /// "Go to the recovery", for the guidance that continues on the open step; nil there.
    var onGoToOpen: (@MainActor () -> Void)?

    var body: some View {
        if let guidance = state.guidance {
            GuidanceNotice(guidance: guidance, onGoToOpen: onGoToOpen)
        } else if let kind = state.error {
            let waits = kind == .rateLimited && state.retrySeconds > 0
            let text = waits ? RecoveryStrings.recoverRateLimitedWait(formatWait(state.retrySeconds)) : kind.message(timeScale: timeScale)
            // The wait counts down in the text: the failure's own text is what is said, once.
            NoticeCard(
                .urgent, title: MoveStrings.recoverFailedTitle, message: text, announce: .assertive,
                announcement: "\(MoveStrings.recoverFailedTitle). \(kind.message(timeScale: timeScale))",
                spokenMessage: waits ? RecoveryStrings.recoverRateLimitedWait(spokenDuration(state.retrySeconds)) : nil
            )
                .accessibilityIdentifier("error")
        }
    }
}

/// What the data layer's refusal of a registration or a start over asks of the member (``RecoverGuidance``; the texts are the
/// iPhone's own: chosen; not in the spec). [onGoToOpen]: to the open step, from a code step. [onFinishWithPin]: the open step's
/// "Finish with your PIN" (the lost-ok finish).
struct GuidanceNotice: View {
    let guidance: RecoverGuidance
    var onGoToOpen: (@MainActor () -> Void)?
    var onFinishWithPin: (@MainActor () -> Void)?

    private var message: String {
        switch guidance {
        case .finishWithPin: RecoveryScreenStrings.iosRecoverGuidanceFinishWithPin
        case .alreadyRecovered: RecoveryScreenStrings.iosRecoverGuidanceAlreadyRecovered
        case .tryOpenAgain: RecoveryScreenStrings.iosRecoverGuidanceTryOpenAgain
        case .retry: RecoveryScreenStrings.iosRecoverGuidanceRetry
        case .startOverFirst: RecoveryScreenStrings.iosRecoverGuidanceStartOverFirst
        }
    }

    private var identifier: String {
        switch guidance {
        case .finishWithPin: "guidance_finish_with_pin"
        case .alreadyRecovered: "guidance_already_recovered"
        case .tryOpenAgain: "guidance_try_open_again"
        case .retry: "guidance_retry"
        case .startOverFirst: "guidance_start_over_first"
        }
    }

    /// The guidance that offers the lost-ok finish with the PIN (an open went out, or the recovery already succeeded).
    static func offersFinish(_ g: RecoverGuidance) -> Bool { g == .finishWithPin || g == .tryOpenAgain || g == .alreadyRecovered }

    /// The guidance that goes on at the open step; "retry" has nothing to go to.
    private var goesOn: Bool { guidance != .retry }

    var body: some View {
        NoticeCard(.warning, title: RecoveryOpenStrings.onboardingOpenAnswerTitle, message: message, announce: .assertive) {
            VStack(alignment: .leading, spacing: 0) {
                if let onFinishWithPin, Self.offersFinish(guidance) {
                    TextLink(RecoveryScreenStrings.onboardingOpenLostTitle, identifier: "guidance_finish", action: onFinishWithPin)
                }
                if let onGoToOpen, goesOn {
                    TextLink(RecoveryScreenStrings.iosRecoverGuidanceGo, identifier: "guidance_go", action: onGoToOpen)
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// The typed code in groups of four, four groups to a row (`7ZK3 M9QX 2HTD CDEF`), as vettid-android's
/// `TypedCodeTransformation` draws it. The canonical characters are the model's; separators typed or pasted are dropped by
/// the model's own reading of them.
enum TypedCodeFormat {
    static let groupsPerRow = 4

    /// The groups to a row that fit a line [width] wide in the monospaced [font]: four, else (at the larger text sizes) two,
    /// else one, so a row never wraps on its own into a ragged 3 + 1 and each row is a whole row, or half of one, of the
    /// account site's grid.
    static func groupsPerRow(fitting width: CGFloat, font: UIFont) -> Int {
        let character = ("0" as NSString).size(withAttributes: [.font: font]).width
        let fits = { (groups: Int) in
            (CGFloat(groups * (RecoverState.codeGroup + 1) - 1) * character).rounded(.up) <= width.rounded(.down)
        }
        return [groupsPerRow, 2].first(where: fits) ?? 1
    }

    /// [canonical] in groups, [perRow] groups to a row.
    static func grouped(_ canonical: String, perRow: Int = groupsPerRow) -> String {
        var out = ""
        var group = 0
        var index = canonical.startIndex
        while index < canonical.endIndex {
            let end = canonical.index(index, offsetBy: RecoverState.codeGroup, limitedBy: canonical.endIndex) ?? canonical.endIndex
            if group > 0 { out += group % perRow == 0 ? "\n" : " " }
            out += canonical[index..<end]
            group += 1
            index = end
        }
        return out
    }
}
#endif
