import Foundation
import VettIDData

/// The words of the Votes screens (ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes"): which text a state of the vault reads as.
/// The vault decides; this maps what it decided to the plan's table, and nothing here says more than the table. Mirrors
/// vettid-android `VoteTexts`.
public enum VoteTexts {
    public static func chip(_ c: VoteChip) -> String {
        switch c {
        case .notVoted: VoteStrings.voteChipNotVoted
        case .recorded: VoteStrings.voteChipRecorded
        case .waiting: VoteStrings.voteChipWaiting
        case .checking: VoteStrings.voteChipChecking
        case .results: VoteStrings.voteChipResults
        case .problem: VoteStrings.voteChipProblem
        case .missed: VoteStrings.voteChipMissed
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// The text of a note. [service] is the service's name (isolated), [time] the time ``VoteNote/notOpen`` names;
    /// a note whose text names neither ignores the arguments. A ``VoteNote/rejected`` note with a [rejected] reason says
    /// the reason.
    public static func text(_ n: VoteNote, service: String, time: String, rejected: RejectedWhy? = nil) -> String {
        if n == .rejected, let rejected { return rejectedText(rejected) }
        switch n {
        case .sending: return VoteStrings.voteStateSending(service)
        case .waiting: return VoteStrings.voteStateWaiting(service)
        case .recorded: return VoteStrings.voteStateRecorded(service)
        case .inResults: return VoteStrings.voteStateInResults
        case .inResultsConflict: return VoteStrings.voteConflictAfterVerified(service)
        case .unconfirmed: return VoteStrings.voteStateUnconfirmed(service)
        case .didntVote: return VoteStrings.voteStateDidntVote
        case .checkPending: return VoteStrings.voteCheckPending
        case .checkResultsProblem: return VoteStrings.voteCheckResultsProblem
        case .checkResultsTooLarge: return VoteStrings.voteCheckResultsTooLarge
        case .checkGaveUpSite: return VoteStrings.voteCheckGaveUpSite
        case .checkGaveUpUnpublished: return VoteStrings.voteCheckGaveUpUnpublished
        case .checkGaveUp: return VoteStrings.voteCheckGaveUp
        case .failed: return VoteStrings.voteFailedBody
        case .conflict: return VoteStrings.voteConflictBody(service)
        case .disputed: return VoteStrings.voteDisputedBody(service)
        case .latePending: return VoteStrings.voteStateLatePending(service)
        case .refusedLate: return VoteStrings.voteRefusedLate
        case .refusedNotActive: return VoteStrings.voteRefusedNotActive(service)
        case .refusedNotEligible: return VoteStrings.voteRefusedNotEligible(service)
        case .refusedBadBallot: return VoteStrings.voteRefusedBadBallot(service)
        case .refusedEnded: return VoteStrings.voteRefusedEnded(service)
        case .notSignedIn: return VoteStrings.voteNotSignedIn(service)
        case .closingSoon: return VoteStrings.voteClosingSoon
        case .notOpen: return VoteStrings.voteNotOpen(time)
        case .closed: return VoteStrings.voteClosedBanner
        case .checkingList: return VoteStrings.voteCheckingList
        case .checkingSite: return VoteStrings.voteCheckingSite
        case .checkingTrust: return VoteStrings.voteCheckingTrust
        case .checkingClock: return VoteStrings.voteCheckingClock
        case .checkingRestore: return VoteStrings.voteCheckingRestore(service)
        case .checkingOther: return VoteStrings.voteCheckingOther
        case .noConnection: return VoteStrings.voteNoConnection(service)
        case .cannotCastOther: return VoteStrings.voteCannotCastOther
        case .rejected: return VoteStrings.voteRejectedOther
        case .notPublished: return VoteStrings.voteNotPublished
        case .siteUnreachable: return VoteStrings.voteSiteUnreachable
        case .siteMismatch: return VoteStrings.voteSiteMismatch
        case .siteMismatchAfter: return VoteStrings.voteSiteMismatchAfter
        case .unpublished: return VoteStrings.voteUnpublished
        case .notListedLate: return VoteStrings.voteNotListedLate
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// A heading over a note's body, for the two that have one.
    public static func title(_ n: VoteNote) -> String? {
        switch n {
        case .failed: VoteStrings.voteFailedTitle
        case .rejected: VoteStrings.voteRejectedTitle
        default: nil
        }
    }

    public static func rejectedText(_ why: RejectedWhy) -> String {
        switch why {
        case .signature: VoteStrings.voteRejectedSignature
        case .anchor: VoteStrings.voteRejectedAnchor
        case .record: VoteStrings.voteRejectedRecord
        case .other: VoteStrings.voteRejectedOther
        }
    }

    /// The unlock window notice (``WindowNotClosed``): the vault's unlock time in whole minutes, rounded up ("1 minute" up
    /// to 60 s), else the plain text when the setting could not be read.
    public static func windowNotClosed(_ w: WindowNotClosed) -> String {
        guard let seconds = w.ttlSeconds else { return VoteStrings.voteWindowNotClosedPlain }
        return VoteStrings.voteWindowNotClosed(minutes: max(1, (seconds + 59) / 60))
    }
}

/// `**bold**` in a text of the table, as bold; the asterisks are never shown (`vote_conflict_after_verified`). An unmatched
/// marker is shown as it is rather than swallowing text.
public func boldMarked(_ text: String) -> AttributedString {
    var out = AttributedString()
    var rest = Substring(text)
    while true {
        guard let a = rest.range(of: "**"), let b = rest[a.upperBound...].range(of: "**") else {
            out += AttributedString(String(rest))
            return out
        }
        out += AttributedString(String(rest[..<a.lowerBound]))
        var bold = AttributedString(String(rest[a.upperBound..<b.lowerBound]))
        bold.inlinePresentationIntent = .stronglyEmphasized
        out += bold
        rest = rest[b.upperBound...]
    }
}

/// The same text as the screen reader reads it: without the markers.
public func plainText(_ text: String) -> String { text.replacingOccurrences(of: "**", with: "") }
