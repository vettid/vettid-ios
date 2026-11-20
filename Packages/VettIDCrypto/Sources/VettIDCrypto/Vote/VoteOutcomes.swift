import Foundation

/// How a vote is decided and its outcome, as an observer checks them (BALLOT-PROTOCOL 0.14.1 §3.5, §7.1, §8.4 step 4,
/// §8.5): the proposal's `decision` read strictly, the results' `outcome` checked for consistency, and the outcome
/// recomputed from the proposal and the tally with integers only. Mirrors service-vault's `vote` package and
/// vettid-vault's `votewire` (`Decide`), and is pinned by their copied vectors (`outcomes`, `decisions`,
/// `outcome_shapes`).
public enum VoteOutcomes {
    /// The reserved choice (§3.1): never decided, never tied, never tested against the rule.
    public static let abstain = "abstain"

    /// A proposal's `decision` (§3.5).
    public typealias Decision = BallotDecision
    /// The results' `outcome` (§7.1).
    public typealias Outcome = BallotOutcome

    /// [o] as a `decision` (§3.5): exactly `rule`, `base` and `threshold`; `base` `null` exactly for plurality;
    /// `threshold` `{num, den}` exactly for threshold, with 1 ≤ `den` ≤ 10, 1 ≤ `num` ≤ `den`, 2·`num` > `den` and in
    /// lowest terms, and `null` otherwise. Throws for anything else.
    public static func decision(_ o: JsonObject) throws -> Decision {
        try exactly(o, ["rule", "base", "threshold"])
        guard let rule = Decision.Rule(rawValue: try o.string("rule")) else { throw bad("rule") }
        let base: Decision.Base?
        if isNull(o["base"]) {
            base = nil
        } else {
            guard let b = Decision.Base(rawValue: try o.string("base")) else { throw bad("base") }
            base = b
        }
        if (rule == .plurality) != (base == nil) { throw bad("base") }
        var fraction: (num: UInt64, den: UInt64)?
        if !isNull(o["threshold"]) {
            let t = try o.obj("threshold")
            try exactly(t, ["num", "den"])
            let den = try t.uint("den", min: 1, max: 10)
            let num = try t.uint("num", min: 1, max: den)
            guard 2 * num > den, gcd(num, den) == 1 else { throw bad("threshold") }
            fraction = (num, den)
        }
        if (rule == .threshold) != (fraction != nil) { throw bad("threshold") }
        return Decision(rule: rule, base: base, fraction: fraction)
    }

    /// [o] as an `outcome` consistent in itself (§8.5): exactly `quorum_met`, `status` and `choice`; a known status;
    /// `quorum_met` false exactly for `no_quorum`; `choice` a real choice's id (`[a-z0-9-]{1,32}`, not `abstain`)
    /// exactly for `decided`, and `null` otherwise. Throws for anything else.
    public static func outcome(_ o: JsonObject) throws -> Outcome {
        try exactly(o, ["quorum_met", "status", "choice"])
        let quorumMet = try o.bool("quorum_met")
        guard let status = Outcome.Status(rawValue: try o.string("status")) else { throw bad("status") }
        if quorumMet == (status == .noQuorum) { throw bad("quorum_met") }
        if status == .decided {
            let choice = try o.string("choice")
            guard VoteRows.validChoice(choice), choice != abstain else { throw bad("choice") }
            return Outcome(quorumMet: quorumMet, status: status, choice: choice)
        }
        guard isNull(o["choice"]) else { throw bad("choice") }
        return Outcome(quorumMet: quorumMet, status: status, choice: nil)
    }

    /// The outcome of [decision] for [tally] (§7.1), in its order: the quorum (`ballots` < [minBallots] is `no_quorum`),
    /// then plurality, or a majority or threshold of the base (a base of 0 is `not_decided`). Throws for a tally that
    /// does not name exactly its choices, or whose sum is not its ballots, or with more ballots than eligible.
    public static func recompute(_ decision: Decision, minBallots: UInt64, _ tally: BallotTally) throws -> Outcome {
        try check(tally)
        if tally.ballots < minBallots { return Outcome(quorumMet: false, status: .noQuorum, choice: nil) }
        let counts = tally.choices.filter { $0 != abstain }.map { (id: $0, n: tally.counts[$0] ?? 0) }
        if decision.rule == .plurality { return plurality(counts) }
        let base: UInt64
        switch decision.base {
        case .cast?: base = counts.reduce(0) { $0 + $1.n }
        case .voted?: base = tally.ballots
        case .elig?: base = tally.eligible
        case nil: throw bad("base")
        }
        guard base > 0 else { return Outcome(quorumMet: true, status: .notDecided, choice: nil) }
        // Counts are at most 100,000 and `den` at most 10 (§7.1): these products don't overflow.
        let meets: (UInt64) -> Bool = decision.rule == .majority
            ? { 2 * $0 > base }
            : { $0 * (decision.fraction?.den ?? 1) >= base * (decision.fraction?.num ?? 1) }
        if let c = counts.first(where: { meets($0.n) }) { return Outcome(quorumMet: true, status: .decided, choice: c.id) }
        return Outcome(quorumMet: true, status: .notDecided, choice: nil)
    }

    /// [tally] names exactly its choices, sums to its ballots, and has no more ballots than eligible.
    private static func check(_ tally: BallotTally) throws {
        guard Set(tally.counts.keys) == Set(tally.choices), tally.counts.count == tally.choices.count else { throw bad("tally") }
        var sum: UInt64 = 0
        for n in tally.counts.values {
            let (s, overflow) = sum.addingReportingOverflow(n)
            guard !overflow else { throw bad("tally") }
            sum = s
        }
        guard sum == tally.ballots, tally.ballots <= tally.eligible else { throw bad("tally") }
    }

    /// Plurality (§7.1): the one real choice with the most votes; a tie at the top is `tied`; no votes is `not_decided`.
    private static func plurality(_ counts: [(id: String, n: UInt64)]) -> Outcome {
        let top = counts.map(\.n).max() ?? 0
        guard top > 0 else { return Outcome(quorumMet: true, status: .notDecided, choice: nil) }
        let holders = counts.filter { $0.n == top }
        return holders.count == 1
            ? Outcome(quorumMet: true, status: .decided, choice: holders[0].id)
            : Outcome(quorumMet: true, status: .tied, choice: nil)
    }

    private static func exactly(_ o: JsonObject, _ names: Set<String>) throws {
        guard Set(o.members.map(\.name)) == names, o.members.count == names.count else { throw bad("members") }
    }

    private static func isNull(_ v: JsonValue?) -> Bool {
        if case .null? = v { true } else { false }
    }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 { b == 0 ? a : gcd(b, a % b) }

    private static func bad(_ what: String) -> CryptoError { CryptoError.format("vote outcome: \(what)") }
}

/// A proposal's `decision` (BALLOT-PROTOCOL §3.5).
public struct BallotDecision: Equatable, Sendable {
    public enum Rule: String, Sendable { case majority, threshold, plurality }
    public enum Base: String, Sendable { case cast, voted, elig }

    public let rule: Rule
    /// Nil for plurality only.
    public let base: Base?
    /// `(num, den)` for threshold only.
    public let fraction: (num: UInt64, den: UInt64)?

    public static func == (a: BallotDecision, b: BallotDecision) -> Bool {
        a.rule == b.rule && a.base == b.base && a.fraction?.num == b.fraction?.num && a.fraction?.den == b.fraction?.den
    }
}

/// The results' `outcome` (BALLOT-PROTOCOL §7.1).
public struct BallotOutcome: Equatable, Sendable {
    public enum Status: String, Sendable {
        case decided
        case notDecided = "not_decided"
        case tied
        case noQuorum = "no_quorum"
    }

    public let quorumMet: Bool
    public let status: Status
    /// The decided choice's id; nil for every other status.
    public let choice: String?

    public init(quorumMet: Bool, status: Status, choice: String?) {
        self.quorumMet = quorumMet
        self.status = status
        self.choice = choice
    }
}

/// A tally as an observer recomputes an outcome from it (BALLOT-PROTOCOL §7.1): the proposal's choice ids in order, each
/// choice's count, the ballots and the electorate.
public struct BallotTally: Sendable {
    public let choices: [String]
    public let counts: [String: UInt64]
    public let ballots: UInt64
    public let eligible: UInt64

    public init(choices: [String], counts: [String: UInt64], ballots: UInt64, eligible: UInt64) {
        self.choices = choices
        self.counts = counts
        self.ballots = ballots
        self.eligible = eligible
    }
}
