import Foundation
import VettIDCrypto
import VettIDVault

// Votes as the vault shows them (VAULT-MESSAGING 0.81.3 §10.19.8; IOS-PLAN §4.16, ANDROID-PLAN 0.1.108 §4 "Votes"). A
// vote is a service's proposal; the vault does every check and signature. Held in memory only, while the vault is open.
// The member's choice is in ``VoteDetail`` alone (`vote.get`), never in a list, an event, a feed item or a log line.
// Mirrors vettid-android `Votes.kt`.

/// A proposal's state in the vault (§10.19.3). A state this app does not know is ``unknown`` and is shown as being checked.
public enum VoteState: String, Sendable, CaseIterable {
    case checking, upcoming, open, closed, rejected
    case unknown = ""

    public static func of(_ wire: String?) -> VoteState { wire.flatMap { $0.isEmpty ? nil : VoteState(rawValue: $0) } ?? .unknown }
}

/// The `ballot.state` of a vote (§10.19.3).
public enum BallotState: String, Sendable, CaseIterable {
    case sending, waiting, recorded, refused, conflict, disputed
    case unknown = ""

    public static func of(_ wire: String?) -> BallotState { wire.flatMap { $0.isEmpty ? nil : BallotState(rawValue: $0) } ?? .unknown }
}

/// The member's ballot as the list shows it; never the choice. [code] is a refusal's code, [reason] a `waiting` ballot's.
public struct VoteBallot: Equatable, Sendable {
    public var state: BallotState
    public var code: String?
    public var reason: String?

    public init(state: BallotState, code: String? = nil, reason: String? = nil) {
        self.state = state
        self.code = code
        self.reason = reason
    }
}

/// The `check.state` of the results check (§10.19.6).
public enum CheckState: String, Sendable, CaseIterable {
    case pending, verified, unconfirmed, failed
    case gaveUp = "gave_up"
    case unknown = ""

    public static func of(_ wire: String?) -> CheckState { wire.flatMap { $0.isEmpty ? nil : CheckState(rawValue: $0) } ?? .unknown }
}

public struct VoteCheck: Equatable, Sendable {
    public var state: CheckState
    public var reason: String?
    public var dueAt: Date?

    public init(state: CheckState, reason: String? = nil, dueAt: Date? = nil) {
        self.state = state
        self.reason = reason
        self.dueAt = dueAt
    }
}

/// The `site` comparison with the public copy (§10.19.4).
public enum SiteState: String, Sendable, CaseIterable {
    case matches
    case mismatch
    case notListed = "not_listed"
    case unreachable
    case unpublished
}

/// The key of a vote in maps and routes: the pair, never the proposal id alone (0.81.2).
public struct VoteKey: Hashable, Sendable {
    public let connectionID: String
    public let proposalID: String

    public init(connectionID: String, proposalID: String) {
        self.connectionID = connectionID
        self.proposalID = proposalID
    }
}

/// One entry of `vote.list` (the summary). The pair [connectionID] and [proposalID] identifies a vote (0.81.2).
public struct VoteSummary: Equatable, Sendable {
    public var proposalID: String
    public var connectionID: String
    /// The service's words, cleaned to one line (control and bidirectional characters removed).
    public var title: String
    public var state: VoteState
    /// A `checking` proposal's reason (`service_list`, `trust_root`, `clock`, `site`, `restore`) or a `rejected` one's.
    public var reason: String?
    public var opensAt: Date?
    public var closesAt: Date?
    public var ballot: VoteBallot?
    public var check: VoteCheck?
    /// The service also showed a ballot under the member's code that the vault did not sign (0.81.3).
    public var conflictEvidence = false
    /// A restore waits for ``VotesRepository/confirm(_:mine:)`` ("Is this your vote?"): no cast meanwhile.
    public var confirmPending = false
    public var canCast = false
    public var cannotCast: String?
    public var site: SiteState?

    public init(
        proposalID: String, connectionID: String, title: String = "", state: VoteState, reason: String? = nil,
        opensAt: Date? = nil, closesAt: Date? = nil, ballot: VoteBallot? = nil, check: VoteCheck? = nil,
        conflictEvidence: Bool = false, confirmPending: Bool = false, canCast: Bool = false, cannotCast: String? = nil,
        site: SiteState? = nil
    ) {
        self.proposalID = proposalID
        self.connectionID = connectionID
        self.title = title
        self.state = state
        self.reason = reason
        self.opensAt = opensAt
        self.closesAt = closesAt
        self.ballot = ballot
        self.check = check
        self.conflictEvidence = conflictEvidence
        self.confirmPending = confirmPending
        self.canCast = canCast
        self.cannotCast = cannotCast
        self.site = site
    }

    public var key: VoteKey { VoteKey(connectionID: connectionID, proposalID: proposalID) }
    public var closed: Bool { state == .closed }
}

/// A vote with its text, choices and facts (`vote.get`). Its description never shows the text, the choice or the tally.
public struct VoteDetail: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var summary: VoteSummary
    /// The service's words, cleaned (lines kept); shown as plain text.
    public var text: String
    public var choices: [VoteChoice]
    public var quorumText: String?
    public var minBallots: Int64?
    public var binding: Bool?
    /// The vault's tag for the member's row in the results (base64); not secret, needed for the results check.
    public var recordTag: String?
    /// The member's own choice, once cast: `vote.get` alone has it. Kept out of every list and log.
    public var choiceID: String?
    public var extensions: Int
    /// The verified results' tally (choice id to count), or nil before the check.
    public var tally: [String: Int64]?
    public var counts: VoteCounts?
    /// The ballot of the service while a restore asks "Is this your vote?": its choice id (0.81.3 `service_ballot`).
    public var serviceBallotChoiceID: String?

    public init(
        summary: VoteSummary, text: String = "", choices: [VoteChoice] = [], quorumText: String? = nil, minBallots: Int64? = nil,
        binding: Bool? = nil, recordTag: String? = nil, choiceID: String? = nil, extensions: Int = 0,
        tally: [String: Int64]? = nil, counts: VoteCounts? = nil, serviceBallotChoiceID: String? = nil
    ) {
        self.summary = summary
        self.text = text
        self.choices = choices
        self.quorumText = quorumText
        self.minBallots = minBallots
        self.binding = binding
        self.recordTag = recordTag
        self.choiceID = choiceID
        self.extensions = extensions
        self.tally = tally
        self.counts = counts
        self.serviceBallotChoiceID = serviceBallotChoiceID
    }

    public var description: String { "VoteDetail(\(summary.connectionID)/\(summary.proposalID))" }
    public var debugDescription: String { description }
}

public struct VoteChoice: Equatable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct VoteCounts: Equatable, Sendable {
    public let eligible: Int64
    public let ballots: Int64
    public let removed: Int64
    public let unhandled: Int64

    public init(eligible: Int64, ballots: Int64, removed: Int64 = 0, unhandled: Int64 = 0) {
        self.eligible = eligible
        self.ballots = ballots
        self.removed = removed
        self.unhandled = unhandled
    }
}

/// Proposals the vault dropped for its caps ([count]) from one service; acknowledged with `ack_dropped` once shown.
public struct DroppedNotice: Equatable, Sendable {
    public let connectionID: String
    public let count: Int64

    public init(connectionID: String, count: Int64) {
        self.connectionID = connectionID
        self.count = count
    }
}

/// A service at its cap of unresolved vote problems ([count]); freed by `vote.release` (§10.19.2).
public struct ProblemsNotice: Equatable, Sendable {
    public let connectionID: String
    public let count: Int64

    public init(connectionID: String, count: Int64) {
        self.connectionID = connectionID
        self.count = count
    }
}

/// A person connection that VettID's service list names as a service (§10.19.8 "Reconnecting for votes").
public struct ReconnectEntry: Equatable, Sendable {
    public let connectionID: String
    public let serviceID: String
    public let name: String

    public init(connectionID: String, serviceID: String, name: String) {
        self.connectionID = connectionID
        self.serviceID = serviceID
        self.name = name
    }
}

/// The whole `vote.list` answer.
public struct VoteListing: Equatable, Sendable {
    public var votes: [VoteSummary]
    public var dropped: [DroppedNotice]
    public var problems: [ProblemsNotice]
    public var reconnect: [ReconnectEntry]
    public var listVersion: Int64?
    public var listSha256: String?
    public var next: String?
}

/// `vote.*` bodies as models. A body that does not read yields no entry: nothing is shown that the app cannot name.
public enum VoteWire {
    /// The longest title shown (code points).
    public static let maxTitle = 80

    private static func s(_ o: JsonObject, _ k: String) -> String? { VaultJSON.string(o, k) }

    private static func id(_ o: JsonObject, _ k: String) -> String? { s(o, k).flatMap { $0.isEmpty ? nil : $0 } }

    private static func obj(_ o: JsonObject, _ k: String) -> JsonObject? {
        if case .object(let v)? = o[k] { return v }
        return nil
    }

    private static func objects(_ o: JsonObject, _ k: String) -> [JsonObject] {
        guard case .array(_, let items)? = o[k] else { return [] }
        return items.compactMap { if case .object(let v) = $0 { v } else { nil } }
    }

    private static func instant(_ o: JsonObject, _ k: String) -> Date? { OwnerCheckManager.instant(s(o, k)) }

    /// A service's title: one line, cleaned, cut at ``maxTitle`` code points. Empty when nothing shows.
    public static func cleanTitle(_ t: String?) -> String { AccountNames.cleanedCapped(t, max: maxTitle) ?? "" }

    public static func summary(_ o: JsonObject) -> VoteSummary? {
        guard let pid = id(o, "proposal_id"), let cid = id(o, "connection_id") else { return nil }
        let ballot = obj(o, "ballot").map { b in
            VoteBallot(state: BallotState.of(s(b, "state")), code: s(b, "code"), reason: s(b, "reason"))
        }
        let check = obj(o, "check").map { c in
            VoteCheck(state: CheckState.of(s(c, "state")), reason: s(c, "reason"), dueAt: instant(c, "due_at"))
        }
        return VoteSummary(
            proposalID: pid, connectionID: cid, title: cleanTitle(s(o, "title")), state: VoteState.of(s(o, "state")),
            reason: s(o, "reason"), opensAt: instant(o, "opens_at"), closesAt: instant(o, "closes_at"), ballot: ballot,
            check: check, conflictEvidence: VaultJSON.bool(o, "conflict_evidence") == true,
            confirmPending: VaultJSON.bool(o, "confirm_pending") == true, canCast: VaultJSON.bool(o, "can_cast") == true,
            cannotCast: s(o, "cannot_cast"), site: s(o, "site").flatMap(SiteState.init(rawValue:))
        )
    }

    public static func listing(_ o: JsonObject) -> VoteListing {
        VoteListing(
            votes: objects(o, "votes").compactMap(summary),
            dropped: objects(o, "dropped").compactMap { d in
                id(d, "connection_id").map { DroppedNotice(connectionID: $0, count: VaultJSON.int(d, "count") ?? 0) }
            },
            problems: objects(o, "problems").compactMap { d in
                id(d, "connection_id").map { ProblemsNotice(connectionID: $0, count: VaultJSON.int(d, "count") ?? 0) }
            },
            reconnect: objects(o, "reconnect").compactMap { d in
                id(d, "connection_id").map {
                    ReconnectEntry(connectionID: $0, serviceID: s(d, "service_id") ?? "", name: AccountNames.cleaned(s(d, "name")) ?? "")
                }
            },
            listVersion: VaultJSON.int(o, "list_version"),
            listSha256: s(o, "list_sha256"),
            next: s(o, "next")
        )
    }

    public static func detail(_ o: JsonObject) -> VoteDetail? {
        guard let summary = summary(o) else { return nil }
        let quorum = obj(o, "quorum")
        let tally = obj(o, "tally").map { t in
            Dictionary(t.members.compactMap { m in
                if case .number(let raw) = m.value, let n = Int64(raw) { (m.name, n) } else { nil }
            }, uniquingKeysWith: { a, _ in a })
        }
        let counts = obj(o, "counts").flatMap { c -> VoteCounts? in
            guard let eligible = VaultJSON.int(c, "eligible"), let ballots = VaultJSON.int(c, "ballots") else { return nil }
            let removed = VaultJSON.int(c, "removed") ?? 0
            return VoteCounts(eligible: eligible, ballots: ballots, removed: removed, unhandled: VaultJSON.int(c, "unhandled") ?? 0)
        }
        return VoteDetail(
            summary: summary,
            text: AccountNames.cleanedLines(s(o, "text")) ?? "",
            choices: objects(o, "choices").compactMap(choice),
            quorumText: AccountNames.cleaned(quorum.flatMap { s($0, "text") }),
            minBallots: quorum.flatMap { VaultJSON.int($0, "min_ballots") },
            binding: VaultJSON.bool(o, "binding"),
            recordTag: s(o, "record_tag"),
            choiceID: s(o, "choice_id"),
            extensions: VaultJSON.int(o, "extensions").map { Int(clamping: $0) } ?? 0,
            tally: tally,
            counts: counts,
            serviceBallotChoiceID: obj(o, "service_ballot").flatMap { s($0, "choice_id") }
        )
    }

    /// The label as sent, in the order sent; cleaned like any received text. A label that shows nothing is its id.
    private static func choice(_ c: JsonObject) -> VoteChoice? {
        guard let id = id(c, "id") else { return nil }
        return VoteChoice(id: id, label: AccountNames.cleaned(s(c, "label")) ?? id)
    }

    /// The `ballot.state` of a `vote.cast` or `vote.confirm` answer.
    public static func ballotState(_ o: JsonObject) -> BallotState { BallotState.of(obj(o, "ballot").flatMap { s($0, "state") }) }
}
