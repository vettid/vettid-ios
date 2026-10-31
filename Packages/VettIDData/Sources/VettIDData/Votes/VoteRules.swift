import Foundation

/// The status chip of a row of Votes (ANDROID-PLAN 0.1.102 §4 "Votes", screen 1): always with its words, never colour
/// alone.
public enum VoteChip: Sendable, CaseIterable {
    case notVoted, recorded, waiting, checking, results, problem, missed
}

/// What a vote screen says, in the order it says it (the texts are the screens' catalog: `vote_*`). Severity is
/// ``Severity``: a conflict found after a verified check is a note, never an error (``inResultsConflict``). Mirrors
/// vettid-android `VoteNote`.
public enum VoteNote: Sendable, CaseIterable {
    case sending, waiting, recorded, inResults
    /// `vote_conflict_after_verified`, under ``inResults``: the check is `verified` and the vault holds conflict evidence.
    case inResultsConflict
    case unconfirmed, didntVote, checkPending
    /// A check the vault leaves `pending` with reason `input`, or the app's own check of the results failed: never "failed".
    case checkResultsProblem
    /// The same for results too large for the vault to ever take: nothing to try again.
    case checkResultsTooLarge
    case checkGaveUpSite, checkGaveUpUnpublished, checkGaveUp
    case failed, conflict, disputed
    case latePending, refusedLate, refusedNotActive, refusedNotEligible, refusedBadBallot, refusedEnded
    case notSignedIn, closingSoon, notOpen, closed
    case checkingList, checkingSite, checkingTrust, checkingClock, checkingRestore, checkingOther
    case noConnection, cannotCastOther, rejected
    case notPublished, siteUnreachable, siteMismatch, siteMismatchAfter, unpublished, notListedLate

    public enum Severity: Sendable { case info, note, warning, error }

    public var severity: Severity {
        switch self {
        case .inResultsConflict: .note
        case .unconfirmed, .checkResultsProblem, .checkResultsTooLarge, .checkGaveUpSite, .checkGaveUpUnpublished, .checkGaveUp,
             .refusedLate, .refusedNotActive, .refusedEnded, .notSignedIn, .closingSoon, .noConnection, .cannotCastOther,
             .notListedLate:
            .warning
        case .failed, .conflict, .disputed, .refusedNotEligible, .refusedBadBallot, .rejected, .siteMismatch, .siteMismatchAfter,
             .unpublished:
            .error
        default: .info
        }
    }
}

/// Why a rejected proposal was set aside, in the words of the screens (`reason` of a `rejected` vote, §10.19.3).
public enum RejectedWhy: Sendable { case signature, anchor, record, other }

/// Why the app's last attempt at a vote's results failed (a `gave_up` check says which of two things).
public enum GaveUpWhy: Sendable { case site, unpublished }

/// The drawer's Votes entry: whether it is shown, and its badge.
public struct VotesEntry: Equatable, Sendable {
    public var shown = false
    public var badge = 0

    public init(shown: Bool = false, badge: Int = 0) {
        self.shown = shown
        self.badge = badge
    }
}

/// The rules of how a vote reads (IOS-PLAN §4.16, ANDROID-PLAN 0.1.108 §4 "Votes"), pure and in one place. The vault
/// decides everything that matters; these say what it decided in the member's words, and fail secure: a state or a code
/// the app does not know is shown as being checked or as a refusal, never as a vote that counts. Mirrors vettid-android
/// `VoteRules`.
public enum VoteRules {
    /// A ballot or check problem, a rejected proposal, or a site difference the vault set apart: "Needs your attention".
    public static func needsAttention(_ s: VoteSummary) -> Bool {
        let b = s.ballot?.state
        return s.state == .rejected || b == .conflict || b == .disputed || b == .refused || s.check?.state == .failed
            || s.conflictEvidence || s.site == .mismatch || s.site == .unpublished
    }

    private static let plainRefusals: Set<String> = ["closed", "late", "connection_ended"]

    /// Whether **Save the proof** is offered (screen 6): `failed`, `conflict`, `disputed`, `rejected`, `refused` (except a
    /// plain final `closed`, `late` or `connection_ended`, which hold nothing to show), conflict evidence and a site
    /// difference.
    public static func hasProof(_ s: VoteSummary) -> Bool {
        let b = s.ballot
        let refusedWithProof = b?.state == .refused && !plainRefusals.contains(b?.code ?? "")
        return s.state == .rejected || b?.state == .conflict || b?.state == .disputed || refusedWithProof
            || s.check?.state == .failed || s.conflictEvidence || s.site == .mismatch || s.site == .unpublished
    }

    /// A row's chip.
    public static func chip(_ s: VoteSummary) -> VoteChip {
        let b = s.ballot?.state
        if needsAttention(s) { return .problem }
        // Refused with a plain code is not a problem to show a proof for, but it is not "You voted" either.
        if b == .refused { return .problem }
        if s.state == .checking || s.state == .unknown { return .checking }
        if s.state == .closed { return closedChip(s) }
        guard let b else { return .notVoted }
        return b == .recorded ? .recorded : .waiting
    }

    private static func closedChip(_ s: VoteSummary) -> VoteChip {
        guard let b = s.ballot?.state else { return .missed }
        switch s.check?.state {
        case .verified?, .unconfirmed?: return .results
        case .pending?, .gaveUp?: return .checking
        default: return b == .recorded ? .recorded : .waiting
        }
    }

    /// Whether the vote screen offers the choices and **Cast your vote** (their state in words says why not, when it can't
    /// be cast).
    public static func choosing(_ s: VoteSummary) -> Bool { s.ballot == nil && s.state != .closed && s.state != .rejected }

    /// The Open section: open, upcoming, being checked and rejected; the Closed section holds `closed`.
    public static func inOpenSection(_ s: VoteSummary) -> Bool { s.state != .closed }

    /// The sidebar's Votes entry (IOS-PLAN §4.16): shown only when the vault answers `vote.list` and holds at least one
    /// vote or lists a `reconnect` connection: a member with no service that votes sees nothing (no empty screen).
    public static func entry(_ votes: [VoteSummary], reconnect: [ReconnectEntry], availability: VotesAvailability) -> VotesEntry {
        let on = availability == .available
        return VotesEntry(shown: on && (!votes.isEmpty || !reconnect.isEmpty), badge: on ? badge(votes) : 0)
    }

    /// The badge counts votes that are `open` and not yet voted on (not upcoming, checking or closed).
    public static func badge(_ votes: [VoteSummary]) -> Int { votes.count { $0.state == .open && $0.ballot == nil } }

    /// A vote that is not finished: removing its service connection first asks (screen 9).
    public static func unfinished(_ s: VoteSummary) -> Bool {
        if s.state == .open || s.state == .upcoming || s.state == .checking { return true }
        let b = s.ballot?.state
        return b == .sending || b == .waiting
    }

    /// Why a rejected proposal was set aside.
    public static func rejectedWhy(_ reason: String?) -> RejectedWhy {
        switch reason {
        case "signature": .signature
        case "anchor": .anchor
        case "record": .record
        default: .other
        }
    }

    /// Whether **Cast your vote** may be pressed with a choice selected: the vault says so (`can_cast`), nothing waits on
    /// a restore confirmation, and there is no ballot yet. The vault checks again.
    public static func castAllowed(_ s: VoteSummary) -> Bool { s.canCast && !s.confirmPending && s.ballot == nil && s.state == .open }

    private static let checkingNotes: Set<VoteNote> = [
        .checkingList, .checkingSite, .checkingTrust, .checkingClock, .checkingRestore, .checkingOther,
    ]

    /// The notes of a vote screen, in the order they are said. [gaveUp] is why the app's last attempt at the results
    /// failed, when it knows; [resultsProblem] a problem the app found itself in the site's results, kept until the next
    /// attempt; [notListedLate] the app has seen the vote missing from the site for 10 minutes or more.
    public static func notes(
        _ s: VoteSummary, gaveUp: GaveUpWhy? = nil, resultsProblem: Bool = false, notListedLate: Bool = false,
        resultsTooLarge: Bool = false
    ) -> [VoteNote] {
        var out: [VoteNote] = []
        if s.state == .closed { out.append(.closed) }
        if s.state == .rejected { out.append(.rejected) }
        ballotNotes(s, &out)
        checkNotes(s, gaveUp, resultsProblem, &out)
        siteNotes(s, notListedLate, &out)
        if s.ballot == nil, s.state != .closed, s.state != .rejected, let n = cannotCastNote(s) { out.append(n) }
        if s.ballot == nil, s.state == .checking, !out.contains(where: checkingNotes.contains) { out.append(checkingNote(s.reason)) }
        return resultsTooLarge ? out.map { $0 == .checkResultsProblem ? .checkResultsTooLarge : $0 } : out
    }

    private static func checkingNote(_ reason: String?) -> VoteNote {
        switch reason {
        case "service_list": .checkingList
        case "site": .checkingSite
        case "trust_root": .checkingTrust
        case "clock": .checkingClock
        case "restore": .checkingRestore
        default: .checkingOther
        }
    }

    private static func ballotNotes(_ s: VoteSummary, _ out: inout [VoteNote]) { // swiftlint:disable:this cyclomatic_complexity
        guard let b = s.ballot else { return }
        switch b.state {
        case .sending: out.append(.sending)
        case .waiting:
            switch b.reason {
            case "not_signed_in": out.append(.notSignedIn)
            case "closed": out.append(.latePending)
            default: out.append(.waiting)
            }
        case .recorded: out.append(.recorded)
        case .refused:
            switch b.code {
            case "closed", "late": out.append(.refusedLate)
            case "not_active": out.append(.refusedNotActive)
            case "not_eligible": out.append(.refusedNotEligible)
            case "connection_ended": out.append(.refusedEnded)
            default: out.append(.refusedBadBallot)
            }
        case .conflict: out.append(.conflict)
        case .disputed: out.append(.disputed)
        // A ballot state this app does not know is never a success: it reads as waiting for the service.
        case .unknown: out.append(.waiting)
        }
    }

    // swiftlint:disable cyclomatic_complexity
    private static func checkNotes(_ s: VoteSummary, _ gaveUp: GaveUpWhy?, _ resultsProblem: Bool, _ out: inout [VoteNote]) {
        let check = s.check
        let recorded = s.ballot?.state == .recorded
        switch check?.state {
        case .verified?:
            if s.ballot == nil {
                out.append(.didntVote)
            } else if recorded {
                // "Include" only after the vault's check passed, and for a ballot it holds a receipt for.
                out.append(.inResults)
                if s.conflictEvidence { out.append(.inResultsConflict) }
            }
        case .unconfirmed?: out.append(.unconfirmed)
        case .failed?: out.append(.failed)
        case .gaveUp?:
            switch gaveUp {
            case .site?: out.append(.checkGaveUpSite)
            case .unpublished?: out.append(.checkGaveUpUnpublished)
            case nil: out.append(.checkGaveUp)
            }
        case .pending?:
            let reason = check?.reason
            if reason == "input" || resultsProblem {
                out.append(.checkResultsProblem)
            } else {
                // A `pending` check whose reason is the vault's own (service_list, trust_root, clock) says so.
                switch reason {
                case "clock": out.append(.checkingClock)
                case "trust_root": out.append(.checkingTrust)
                case "service_list": out.append(.checkingList)
                default: out.append(.checkPending)
                }
            }
        case .unknown?, nil: break
        }
        // The app's own find in the site's results while the vault has not judged them yet.
        if resultsProblem, check == nil, s.state == .closed { out.append(.checkResultsProblem) }
    }
    // swiftlint:enable cyclomatic_complexity

    private static func siteNotes(_ s: VoteSummary, _ notListedLate: Bool, _ out: inout [VoteNote]) {
        let after = s.ballot != nil
        switch s.site {
        case .mismatch?: out.append(after ? .siteMismatchAfter : .siteMismatch)
        case .unpublished?: out.append(.unpublished)
        // A warning only (never stops a cast): the vault compares later.
        case .notListed?: out.append(s.state == .closed || notListedLate ? .notListedLate : .notPublished)
        case .unreachable?: out.append(.siteUnreachable)
        case .matches?, nil: break
        }
    }

    /// The reason a cast is not offered (screen 2: the reason is written where the button would be).
    public static func cannotCastNote(_ s: VoteSummary) -> VoteNote? { // swiftlint:disable:this cyclomatic_complexity
        if s.canCast, !s.confirmPending { return nil }
        if s.confirmPending { return .checkingRestore }
        switch s.cannotCast {
        case nil: return nil
        case "checking": return checkingNote(s.reason)
        case "not_open": return .notOpen
        case "closed": return .closed
        case "closing": return .closingSoon
        case "already_voted": return nil // the ballot's own note says it
        case "site_mismatch": return .siteMismatch
        case "connection_unavailable": return .noConnection
        case "not_signed_in": return .notSignedIn
        default: return .cannotCastOther
        }
    }
}
