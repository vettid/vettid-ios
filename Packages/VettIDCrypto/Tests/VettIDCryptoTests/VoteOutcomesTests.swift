import Foundation
import Testing
@testable import VettIDCrypto

/// How a vote is decided and its outcome, as the observer checks them (BALLOT-PROTOCOL 0.14.1 §3.5, §7.1, §8.4 step 4,
/// §8.5), against `vote.json`'s §11 item 5 vectors byte for byte (see SOURCE.md): every `decisions`, `outcome_shapes`
/// and `outcomes` case, the decided documents, and the proposal every verifier refuses.
struct VoteOutcomesTests {
    private let v: VectorDoc

    init() throws {
        v = try VectorDoc.load("vote.json")
    }

    private func cases(_ name: String) throws -> [JsonObject] {
        try v.o.array(name).map { try $0.asObject() }
    }

    @Test func everyDecisionIsAcceptedOrRefusedAsTheVectorSays() throws {
        let all = try cases("decisions")
        #expect(all.count == 24)
        for c in all {
            let ok = (try? VoteOutcomes.decision(c.obj("decision"))) != nil
            let (valid, name) = (try c.bool("valid"), try c.string("case"))
            #expect(ok == valid, "\(name)")
        }
    }

    @Test func everyOutcomeShapeIsConsistentOrNotAsTheVectorSays() throws {
        let all = try cases("outcome_shapes")
        #expect(all.count == 16)
        for c in all {
            let ok = (try? VoteOutcomes.outcome(c.obj("outcome"))) != nil
            let (valid, name) = (try c.bool("valid"), try c.string("case"))
            #expect(ok == valid, "\(name)")
        }
    }

    /// Each case recomputes to its outcome; one whose outcome is `null` is a tally every verifier refuses.
    @Test func everyOutcomeRecomputes() throws {
        let all = try cases("outcomes")
        #expect(all.count == 40)
        for c in all {
            let name = try c.string("case")
            let decision = try VoteOutcomes.decision(c.obj("decision"))
            let got: VoteOutcomes.Outcome? = try? {
                var tally: [String: UInt64] = [:]
                for (id, n) in try c.obj("tally").members { tally[id] = try n.asUint(min: 0, max: StrictJson.maxSafeInteger) }
                let t = BallotTally(
                    choices: try c.array("choices").map { try $0.asString() }, counts: tally,
                    ballots: try c.uint("ballots", min: 0, max: StrictJson.maxSafeInteger),
                    eligible: try c.uint("eligible", min: 0, max: StrictJson.maxSafeInteger)
                )
                return try VoteOutcomes.recompute(decision, minBallots: c.uint("min_ballots", min: 0, max: StrictJson.maxSafeInteger), t)
            }()
            if case .null? = c["outcome"] {
                #expect(got == nil, "\(name): refused")
            } else {
                let want = try VoteOutcomes.outcome(c.obj("outcome"))
                #expect(got == want, "\(name)")
            }
        }
    }

    private var decided: VectorDoc { get throws { try v.sub("documents_decided") } }

    private func rows(_ d: VectorDoc) throws -> [JsonObject] {
        try StrictJson.parseObject(Array(d.str("rows").utf8)).array("rows").map { try $0.asObject() }
    }

    private func check(_ results: String, _ d: VectorDoc) throws -> ResultsProblem? {
        let tag = try rows(d)[0].base64("record_tag", 32)
        return try VoteRows.ownRow(results: Array(results.utf8), rows: Array(d.str("rows").utf8), recordTag: tag).problem
    }

    /// The decided documents pass the whole observer check, and their outcome is `decided` for `yes`.
    @Test func theDecidedDocumentsPassAndDecideYes() throws {
        let d = try decided
        let results = try d.str("results")
        #expect(try check(results, d) == nil)
        let outcome = try VoteOutcomes.outcome(StrictJson.parseObject(Array(results.utf8)).obj("outcome"))
        #expect(outcome == VoteOutcomes.Outcome(quorumMet: true, status: .decided, choice: "yes"))
    }

    /// An outcome that does not recompute from the rows' tally is a problem with the published results, and so is one not
    /// consistent in itself.
    @Test func anOutcomeThatDoesNotRecomputeIsAProblem() throws {
        let d = try decided
        let results = try d.str("results")
        let decidedYes = #""outcome":{"choice":"yes","quorum_met":true,"status":"decided"}"#
        #expect(results.contains(decidedYes))
        let notDecided = results.replacingOccurrences(
            of: decidedYes, with: #""outcome":{"choice":null,"quorum_met":true,"status":"not_decided"}"#
        )
        #expect(try check(notDecided, d) == ResultsProblem("outcome"))
        let decidedNo = results.replacingOccurrences(
            of: decidedYes, with: #""outcome":{"choice":"no","quorum_met":true,"status":"decided"}"#
        )
        #expect(try check(decidedNo, d) == ResultsProblem("outcome"))
        let inconsistent = results.replacingOccurrences(
            of: decidedYes, with: #""outcome":{"choice":"yes","quorum_met":false,"status":"decided"}"#
        )
        #expect(try check(inconsistent, d) == ResultsProblem("outcome"))
    }

    /// (0.14.1) A proposal with `removed_may_vote: true` is refused by every verifier, the observer included: results that
    /// carry it are a problem with the proposal, before anything else.
    @Test func aProposalWithRemovedMayVoteTrueIsRefused() throws {
        let d = try decided
        let results = try d.str("results")
        let doc = try StrictJson.parseObject(Array(results.utf8)).obj("proposal").string("doc")
        let refused = Data(try v.str("proposal_removed_may_vote_true").utf8).base64EncodedString()
        #expect(try check(results.replacingOccurrences(of: doc, with: refused), d) == ResultsProblem("proposal"))
        // The same proposal with `false` gets past that check (it fails later: it's another vote's document).
        let allowed = Data(
            try v.str("proposal_removed_may_vote_true")
                .replacingOccurrences(of: #""removed_may_vote":true"#, with: #""removed_may_vote":false"#).utf8
        )
        #expect(try check(results.replacingOccurrences(of: doc, with: allowed.base64EncodedString()), d) != ResultsProblem("proposal"))
    }

    /// A proposal without `removed_may_vote`, or without a valid `decision` (absent, or one §3.5 refuses), is a problem
    /// with the proposal too.
    @Test func aProposalWithoutRemovedMayVoteOrAValidDecisionIsRefused() throws {
        let d = try decided
        let results = try d.str("results")
        let doc = try StrictJson.parseObject(Array(results.utf8)).obj("proposal").string("doc")
        let proposal = try #require(Data(base64Encoded: doc).flatMap { String(data: $0, encoding: .utf8) })
        let decision = try #require(proposal.range(of: #""decision":\{[^}]*\}\},?|"decision":\{[^}]*\},?"#, options: .regularExpression))
        let variants = [
            proposal.replacingOccurrences(of: #""removed_may_vote":false,"#, with: ""),
            proposal.replacingOccurrences(of: #","removed_may_vote":false"#, with: ""),
            proposal.replacingCharacters(in: decision, with: ""),
            proposal.replacingOccurrences(of: #""rule":"majority""#, with: #""rule":"unanimity""#),
        ].filter { $0 != proposal }
        #expect(variants.count >= 3)
        for v in variants {
            let changed = results.replacingOccurrences(of: doc, with: Data(v.utf8).base64EncodedString())
            #expect(try check(changed, d) == ResultsProblem("proposal"), "\(v)")
        }
    }
}
