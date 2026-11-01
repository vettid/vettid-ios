import Foundation
import VettIDData

/// A note with its words (``VoteTexts``): [heading] over the body for the two notes that have one.
public struct VoteNoteLine: Equatable, Hashable, Sendable {
    public let note: VoteNote
    public let heading: String?
    public let text: String

    public init(note: VoteNote, heading: String?, text: String) {
        self.note = note
        self.heading = heading
        self.text = text
    }
}

/// A message with an optional title.
public struct VoteMessage: Equatable, Sendable {
    public let title: String?
    public let text: String

    public init(title: String?, text: String) {
        self.title = title
        self.text = text
    }
}

/// What a vote screen says and offers, in the order it does (ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes", screens 2 to 7),
/// decided here, in one place, from the vault's state and the app's hints, so that the screen only draws it and a test reads
/// it. Mirrors the composition of vettid-android `VoteScreen`'s `VoteContent`.
public struct VoteFacts: Equatable, Sendable {
    public var title: String
    /// "Example · Service" and the line under it that the name is the service's own.
    public var serviceLine: String
    public var serviceNote = VoteStrings.voteNameByService
    public var proposalText: String?
    public var writtenBy: String?
    public var quorum: String?
    public var binding: String?
    public var closes: String?
    public var extended: String?
    /// The states in words, in order.
    public var notes: [VoteNoteLine] = []
    /// The lock after a cast failed: its title, its words with the unlock time, and **Close it now**'s failure when it failed.
    public var windowNotClosed: VoteMessage?
    /// `already_voted`: told, with the recorded choice.
    public var alreadyVoted: String?
    /// A cast the vault refused or did not answer: its title and words. The only action is to put it away.
    public var castProblem: VoteMessage?
    public var checkProblem: String?
    public var checkOutcome: VoteMessage?
    /// "Your choice: …", once cast.
    public var yourChoice: String?
    /// The verified results' lines (a title, then rows, turnout, quorum and the unhandled messages); nil before the check.
    public var results: [String]?
    /// The choices in the order sent, with their labels as sent.
    public var choices: [String] = []
    /// Whether the choices and **Cast your vote** are shown, and whether they are enabled.
    public var choosing = false
    public var castEnabled = false
    public var checkWithService = false
    public var checkAgain = false
    public var saveProof = false
    public var proofProblem: String?
    public var proofSaved = false
    public var proofSaveFailed = false
    public var release = false
    public var released = false

    /// [timeScale]: the vault's, for the failures that name a wait.
    public static func of(_ s: VoteScreenState, summary: VoteSummary, now: Date, timeScale: UInt64 = 1) -> VoteFacts { // swiftlint:disable:this function_body_length
        let service = AccountNames.isolateOrNull(s.serviceName) ?? VoteStrings.voteServiceFallback
        let time = summary.opensAt.map(VoteFormat.full) ?? ""
        var f = VoteFacts(
            title: AccountNames.isolateOrNull(summary.title) ?? "",
            serviceLine: "\(service) · \(VoteStrings.voteServiceLabel)"
        )
        if let d = s.detail {
            f.proposalText = d.text
            f.writtenBy = VoteStrings.voteWrittenBy(service)
            f.quorum = d.quorumText.map { VoteStrings.voteQuorumLine(AccountNames.isolateOrNull($0) ?? "") }
            f.binding = d.binding.map { $0 ? VoteStrings.voteBindingYes : VoteStrings.voteBindingNo }
            f.closes = summary.closesAt.map { VoteStrings.voteClosesLine(VoteFormat.full($0)) }
            if d.extensions > 0, let closes = summary.closesAt { f.extended = VoteStrings.voteExtended(VoteFormat.full(closes)) }
            f.yourChoice = s.choiceLabel.map { VoteStrings.voteYourChoice(AccountNames.isolateOrNull($0) ?? "") }
            f.results = results(d, service)
            f.choices = d.choices.map { AccountNames.isolateOrNull($0.label) ?? $0.id }
        }
        f.notes = VoteRules.notes(
            summary, gaveUp: s.hint.gaveUp, resultsProblem: s.hint.resultsProblem, notListedLate: s.hint.notListedLate(now),
            resultsTooLarge: s.hint.resultsTooLarge
        ).map { n in
            let why = n == .rejected ? VoteRules.rejectedWhy(summary.reason) : nil
            return VoteNoteLine(note: n, heading: VoteTexts.title(n), text: VoteTexts.text(n, service: service, time: time, rejected: why))
        }
        f.windowNotClosed = s.windowNotClosed.map { w in
            let failure = s.windowCloseProblem.map { "\n" + $0.kind.message(timeScale: timeScale) } ?? ""
            return VoteMessage(title: VoteStrings.voteWindowNotClosedTitle, text: VoteTexts.windowNotClosed(w) + failure)
        }
        if s.alreadyVoted {
            f.alreadyVoted = AccountNames.isolateOrNull(s.choiceLabel).map { VoteStrings.voteAlreadyVoted($0) } ?? VoteStrings.voteAlreadyVotedAny
        }
        f.castProblem = s.castProblem.map { castProblem($0, service, time, timeScale) }
        f.checkProblem = s.checkProblem.map { $0.kind.message(timeScale: timeScale) }
        switch s.checkOutcome {
        case .siteUnreachable?: f.checkOutcome = VoteMessage(title: VoteStrings.voteCheckWithService, text: VoteStrings.voteCheckSiteUnreachableNow)
        case .notPublished?: f.checkOutcome = VoteMessage(title: VoteStrings.voteCheckWithService, text: VoteStrings.voteCheckNotPublishedNow)
        default: break
        }
        buttons(&f, s, summary)
        return f
    }

    private static func buttons(_ f: inout VoteFacts, _ s: VoteScreenState, _ summary: VoteSummary) {
        f.choosing = s.detail != nil && VoteRules.choosing(summary)
        f.castEnabled = s.canCast
        let ballot = summary.ballot?.state
        let waiting = ballot == .sending || ballot == .waiting
        let pending = summary.check?.state == .pending || summary.check?.state == .gaveUp
        f.checkWithService = waiting && !summary.closed
        f.checkAgain = summary.closed && (pending || waiting)
        f.saveProof = VoteRules.hasProof(summary)
        guard f.saveProof else { return }
        f.proofProblem = s.proofProblem.map { $0.kind.message(timeScale: 1) }
        f.proofSaved = s.proofSaved
        f.proofSaveFailed = s.proofSaveFailed
        // A problem record, once its proof is saved: Release (the vault refuses it until then, and for an open vote).
        f.release = s.proofExported && (summary.closed || summary.state == .rejected) && !s.released
        f.released = s.released
    }

    private static func results(_ d: VoteDetail, _ service: String) -> [String]? {
        guard let tally = d.tally else { return nil }
        var lines = [VoteStrings.voteResultsTitle]
        for c in d.choices {
            if let n = tally[c.id] { lines.append(VoteStrings.voteResultsRow(AccountNames.isolateOrNull(c.label) ?? c.id, Int(n))) }
        }
        if let c = d.counts {
            lines.append(VoteStrings.voteResultsTurnout(Int(c.ballots), Int(c.eligible)))
            if let min = d.minBallots {
                lines.append(c.ballots >= min ? VoteStrings.voteQuorumMet(Int(c.ballots), Int(min)) : VoteStrings.voteQuorumNotMet(Int(c.ballots), Int(min)))
            }
            if c.unhandled > 0 { lines.append(VoteStrings.voteResultsUnhandled(Int(c.unhandled), service)) }
        }
        return lines
    }

    /// A cast the vault refused or did not answer: said plainly (the plan's words for each code), never silent. No answer:
    /// the vote may have been sent, so it is not "not sent".
    static func castProblem(_ p: VoteProblem, _ service: String, _ time: String, _ timeScale: UInt64) -> VoteMessage {
        let unknown = p.kind == .noResponse || p.kind == .network
        let title = unknown ? VoteStrings.voteCastUnknownTitle : VoteStrings.voteCastFailedTitle
        if let note = castNote(p.code) { return VoteMessage(title: title, text: VoteTexts.text(note, service: service, time: time)) }
        return VoteMessage(title: title, text: unknown ? VoteStrings.voteCastUnanswered : p.kind.message(timeScale: timeScale))
    }

    private static func castNote(_ code: String?) -> VoteNote? {
        switch code {
        case "not_open": .notOpen
        case "closed": .closed
        case "closing": .closingSoon
        case "site_mismatch": .siteMismatch
        case "not_signed_in": .notSignedIn
        case "connection_unavailable": .noConnection
        case "checking": .checkingOther
        default: nil
        }
    }
}

/// Dates and times as the Votes screens show them, in the iPhone's zone and locale (vettid-android `Times.full`).
public enum VoteFormat {
    public static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}

/// A row of the Votes list, as it is read (screen 1).
public struct VoteRowFacts: Equatable, Sendable {
    public let title: String
    public let supporting: String?
    public let chip: VoteChip
    public let chipText: String
    /// The row read whole: "Adopt the budget, from the service Example, you voted, Closes …".
    public let spoken: String

    public init(title: String, supporting: String?, chip: VoteChip, chipText: String, spoken: String) {
        self.title = title
        self.supporting = supporting
        self.chip = chip
        self.chipText = chipText
        self.spoken = spoken
    }

    public static func of(_ v: VoteSummary, serviceName: String) -> VoteRowFacts {
        let chip = VoteRules.chip(v)
        let chipText = VoteTexts.chip(chip)
        let service = AccountNames.isolateOrNull(serviceName) ?? ""
        let title = AccountNames.isolateOrNull(v.title) ?? VoteStrings.votesTitle
        let time = timeLine(v)
        let supporting = [service.isEmpty ? nil : "\(service) · \(VoteStrings.voteServiceLabel)", time].compactMap { $0 }.joined(separator: " · ")
        return VoteRowFacts(
            title: title, supporting: supporting.isEmpty ? nil : supporting, chip: chip, chipText: chipText,
            spoken: VoteStrings.voteRowDescription(title, service, chipText) + (time.map { ", \($0)" } ?? "")
        )
    }

    /// A row's written time: when it closed, opens or closes.
    static func timeLine(_ v: VoteSummary) -> String? {
        switch v.state {
        case .closed: v.closesAt.map { VoteStrings.voteRowClosed(VoteFormat.full($0)) }
        case .upcoming: v.opensAt.map { VoteStrings.voteRowOpens(VoteFormat.full($0)) }
        default: v.closesAt.map { VoteStrings.voteRowCloses(VoteFormat.full($0)) }
        }
    }
}
