import Foundation
import Testing
@testable import VettIDData
import VettIDCrypto
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// `vote.get`'s `decision` and `outcome` (VAULT-MESSAGING 0.90.18 §10.19.8; BALLOT-PROTOCOL 0.14.0 §3.5, §7.1). The vault
/// refused any other decision on arrival and recomputed the outcome; one the app can't read gives no line, never a wrong one.
@Suite struct VoteDecisionWireTests {
    func decision(_ json: String) throws -> VoteDecision? {
        VoteWire.decision(try StrictJson.parseObject(Array(json.utf8)))
    }

    func outcome(_ json: String) throws -> VoteOutcome? {
        VoteWire.outcome(try StrictJson.parseObject(Array(json.utf8)))
    }

    @Test func eachRuleWithItsBase() throws {
        #expect(try decision(#"{"rule":"majority","base":"cast","threshold":null}"#) == VoteDecision(rule: .majority, base: .cast))
        #expect(try decision(#"{"rule":"majority","base":"voted","threshold":null}"#) == VoteDecision(rule: .majority, base: .voted))
        #expect(try decision(#"{"rule":"threshold","base":"elig","threshold":{"num":2,"den":3}}"#) == VoteDecision(rule: .threshold(num: 2, den: 3), base: .elig))
        #expect(try decision(#"{"rule":"threshold","base":"cast","threshold":{"num":1,"den":1}}"#) == VoteDecision(rule: .threshold(num: 1, den: 1), base: .cast))
        #expect(try decision(#"{"rule":"plurality","base":null,"threshold":null}"#) == VoteDecision(rule: .plurality, base: nil))
    }

    @Test func aDecisionOutsideTheRulesGivesNone() throws {
        #expect(try decision(#"{"rule":"majority","base":null,"threshold":null}"#) == nil)
        #expect(try decision(#"{"rule":"majority","base":"all","threshold":null}"#) == nil)
        #expect(try decision(#"{"rule":"threshold","base":"cast","threshold":{"num":1,"den":2}}"#) == nil, "not above one half")
        #expect(try decision(#"{"rule":"threshold","base":"cast","threshold":{"num":10,"den":11}}"#) == nil, "den above 10")
        #expect(try decision(#"{"rule":"threshold","base":"cast","threshold":{"num":3,"den":2}}"#) == nil)
        #expect(try decision(#"{"rule":"threshold","base":"cast","threshold":null}"#) == nil)
        #expect(try decision(#"{"rule":"runoff","base":"cast","threshold":null}"#) == nil)
        #expect(try decision(#"{"rule":"threshold","base":"cast","threshold":{"num":4,"den":6}}"#) == nil, "not in lowest terms")
        #expect(try decision(#"{"rule":"threshold","base":"cast","threshold":{"num":2,"den":2}}"#) == nil, "1/1 is the only all")
        #expect(try decision(#"{"rule":"plurality","base":"cast","threshold":null}"#) == nil, "plurality has no base")
        #expect(try decision(#"{"rule":"plurality","base":null,"threshold":{"num":2,"den":3}}"#) == nil)
        #expect(try decision(#"{"rule":"majority","base":"cast","threshold":{"num":2,"den":3}}"#) == nil)
        #expect(try decision(#"{"rule":"majority","base":"cast"}"#) == nil, "threshold absent")
        #expect(try decision(#"{"rule":"plurality","threshold":null}"#) == nil, "base absent")
        #expect(try decision(#"{"rule":"majority","base":"cast","threshold":null,"extra":1}"#) == nil, "an unknown member")
        #expect(try decision(#"{"rule":"threshold","base":"cast","threshold":{"num":2,"den":3,"x":1}}"#) == nil)
    }

    @Test func eachOutcome() throws {
        #expect(try outcome(#"{"quorum_met":true,"status":"decided","choice":"yes"}"#) == VoteOutcome(status: .decided, choice: "yes"))
        #expect(try outcome(#"{"quorum_met":true,"status":"not_decided","choice":null}"#) == VoteOutcome(status: .notDecided, choice: nil))
        #expect(try outcome(#"{"quorum_met":true,"status":"tied","choice":null}"#) == VoteOutcome(status: .tied, choice: nil))
        #expect(try outcome(#"{"quorum_met":false,"status":"no_quorum","choice":null}"#) == VoteOutcome(status: .noQuorum, choice: nil))
        #expect(try outcome(#"{"quorum_met":true,"status":"decided","choice":null}"#) == nil, "decided names its choice")
        #expect(try outcome(#"{"quorum_met":true,"status":"passed","choice":"yes"}"#) == nil)
        #expect(try outcome(#"{"quorum_met":false,"status":"decided","choice":"yes"}"#) == nil, "decided meets the quorum")
        #expect(try outcome(#"{"quorum_met":true,"status":"no_quorum","choice":null}"#) == nil)
        #expect(try outcome(#"{"quorum_met":true,"status":"not_decided","choice":"yes"}"#) == nil, "only decided names a choice")
        #expect(try outcome(#"{"quorum_met":true,"status":"tied"}"#) == nil, "choice absent")
    }

    @Test func voteGetCarriesThemIntoTheDetail() throws {
        let o = try StrictJson.parseObject(Array(#"{"proposal_id":"P","connection_id":"C","title":"T","state":"closed","text":"x","choices":[{"id":"yes","label":"Yes"}],"decision":{"rule":"majority","base":"cast","threshold":null},"outcome":{"quorum_met":true,"status":"decided","choice":"yes"}}"#.utf8))
        let d = try #require(VoteWire.detail(o))
        #expect(d.decision == VoteDecision(rule: .majority, base: .cast) && d.outcome == VoteOutcome(status: .decided, choice: "yes"))
    }
}

// swiftlint:enable line_length
