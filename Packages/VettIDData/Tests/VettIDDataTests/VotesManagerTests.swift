import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

private let conn = VoteFixture.conn
private let pid = VoteFixture.pid
private let key = VoteFixture.key

private func obj(_ s: String) -> JsonObject { voteObj(s) }

/// The votes list and the cast (IOS-PLAN §4.16, ANDROID-PLAN 0.1.108 "Votes"; VAULT-MESSAGING 0.81.3 §10.19.8). Mirrors
/// the list and cast part of vettid-android `VotesManagerTest` (the site and the results come with that work).
@MainActor
struct VotesManagerTests: VotesTestCase {
    private static let start = Date(timeIntervalSince1970: 1_793_534_400) // 2026-11-01T12:00:00Z
    let clock = TestClock(1_793_534_400_000)

    @Test func theListIsKeptByThePairAndNeverCarriesAChoice() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(), summary(conn: "conn-2"))
        let m = manager(ops)
        try await m.refresh()
        #expect(m.availability == .available)
        #expect(m.load == .loaded)
        // Two services with the same proposal id are two votes.
        #expect(m.votes.map(\.key) == [key, VoteKey(connectionID: "conn-2", proposalID: pid)])
        #expect(m.titleOf(key) == "Adopt the budget")
        #expect(m.titleOf(VoteKey(connectionID: "conn-3", proposalID: pid)) == nil)
        #expect(m.entry == VotesEntry(shown: true, badge: 2))
        #expect(ops.calls == ["list"])
    }

    @Test func aRepeatedEntryIsListedOnceAndALaterPageIsRead() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(), summary(), tail: #","next":"cursor""#)
        let m = manager(ops)
        try await m.refresh()
        // The fake answers the same page each time: the read stops at its page limit and lists each pair once.
        #expect(m.votes.count == 1)
        #expect(ops.calls.count == VotesManager.maxPages)
    }

    @Test func aTitleWithControlAndBidirectionalCharactersIsShownClean() async throws {
        let ops = FakeVoteOps()
        ops.list = obj(#"{"votes":[{"proposal_id":"\#(pid)","connection_id":"\#(conn)","title":"Budget‮decided\n\u0007now","state":"open","can_cast":true}],"dropped":[],"problems":[],"reconnect":[]}"#)
        let m = manager(ops)
        try await m.refresh()
        let t = try #require(m.votes.first?.title)
        #expect(!t.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x0A || $0.value == 0x07 })
        #expect(t.hasPrefix("Budget"))
    }

    @Test func aVaultWithoutVotesIsAskedAgainOnlyAfterTheNextOpening() async throws {
        let ops = FakeVoteOps()
        ops.refuse["list"] = "unsupported_type"
        let m = manager(ops)
        #expect(await failure { try await m.refresh() }?.kind == .notSupported)
        #expect(m.availability == .unsupported)
        #expect(m.entry == VotesEntry())
        m.refreshQuietly()
        try await m.refresh()
        try await Task.sleep(for: .milliseconds(50))
        #expect(ops.calls.filter { $0 == "list" }.count == 1)
        m.clear()
        #expect(m.availability == .unknown)
        ops.refuse = [:]
        ops.list = listing(summary())
        try await m.refresh()
        #expect(m.availability == .available)
    }

    @Test func aFailedReadSaysSoAndKeepsTheFeatureUnknown() async {
        let ops = FakeVoteOps()
        ops.refuse["list"] = "retry"
        let m = manager(ops)
        #expect(await failure { try await m.refresh() } != nil)
        #expect(m.load == .failed)
        #expect(m.availability == .unknown)
    }

    @Test func nothingIsReadWhileTheVaultIsHeldOrDue() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        var held = true
        let m = manager(ops, gated: { held })
        try await m.refresh()
        m.onEvent(event("vote.event", #"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","event":"proposal","state":"open"}"#))
        try await Task.sleep(for: .milliseconds(50))
        #expect(ops.calls.isEmpty)
        #expect(m.votes.isEmpty)
        held = false
        try await m.refresh()
        #expect(m.votes.count == 1)
    }

    @Test func theListAnnouncesDroppedProblemsAndReconnect() async throws {
        let ops = FakeVoteOps()
        ops.list = obj(#"{"votes":[],"dropped":[{"connection_id":"c1","count":3,"last_at":"2026-11-01T10:00:00.000Z"}],"problems":[{"connection_id":"c1","count":16}],"reconnect":[{"connection_id":"c2","service_id":"svc","name":"Example Org"}],"list_version":2,"list_sha256":"AAAA"}"#)
        let m = manager(ops)
        try await m.refresh()
        #expect(m.dropped == [DroppedNotice(connectionID: "c1", count: 3)])
        #expect(m.problems == [ProblemsNotice(connectionID: "c1", count: 16)])
        #expect(m.reconnect == [ReconnectEntry(connectionID: "c2", serviceID: "svc", name: "Example Org")])
        #expect(m.listVersion == 2 && m.listSha256 == "AAAA")
        // A reconnect entry alone shows the entry, with no badge.
        #expect(m.entry == VotesEntry(shown: true, badge: 0))
    }

    @Test func aShownDroppedNoticeIsAcknowledgedWithTheNextListAndDoesNotReturn() async throws {
        let ops = FakeVoteOps()
        ops.list = obj(#"{"votes":[],"dropped":[{"connection_id":"c1","count":3,"last_at":"2026-11-01T10:00:00.000Z"}],"problems":[],"reconnect":[]}"#)
        let m = manager(ops)
        try await m.refresh()
        m.acknowledgeDropped(["c1"])
        #expect(m.dropped.isEmpty)
        // The vault drops the entry once it has the acknowledgement.
        ops.list = listing()
        #expect(await eventually { ops.acks.count >= 2 })
        #expect(ops.acks.last == ["c1"])
        #expect(await eventually { m.dropped.isEmpty && ops.calls.count == 2 })
        try await m.refresh()
        #expect(ops.acks.last == [])
    }

    @Test func anAcknowledgementWhoseReadFailedGoesWithTheNextOne() async throws {
        let ops = FakeVoteOps()
        ops.list = obj(#"{"votes":[],"dropped":[{"connection_id":"c1","count":3}],"problems":[],"reconnect":[]}"#)
        let m = manager(ops)
        try await m.refresh()
        ops.refuse["list"] = "retry"
        m.acknowledgeDropped(["c1"])
        #expect(await eventually { ops.calls.count == 2 })
        ops.refuse = [:]
        ops.list = listing()
        try await m.refresh()
        #expect(ops.acks.last == ["c1"])
    }

    @Test func confirmCheckEvidenceAndReleaseNameTheConnection() async throws {
        let ops = FakeVoteOps()
        let m = manager(ops)
        #expect(try await m.confirm(key, mine: true) == .recorded)
        #expect(try await m.confirm(key, mine: false) == .disputed)
        try await m.check(key)
        try await m.release(key, pin: "123456")
        for c in ["confirm:\(conn)/\(pid):true", "confirm:\(conn)/\(pid):false", "check:\(conn)/\(pid)", "release:\(conn)/\(pid)"] {
            #expect(ops.calls.contains(c), "\(c)")
        }
    }

    @Test func theEvidenceIsTheVaultsOwnBytesUnchanged() async throws {
        let ops = FakeVoteOps()
        ops.evidence = obj(#"{"evidence":{ "proposal" : "AAAA","member":{"ballot":{"choice_id":"yes"}}}}"#)
        let m = manager(ops)
        #expect(try await m.evidence(key) == #"{ "proposal" : "AAAA","member":{"ballot":{"choice_id":"yes"}}}"#)
        #expect(ops.calls.contains("evidence:\(conn)/\(pid)"))
        ops.evidence = obj(#"{"other":1}"#)
        #expect(await failure { try await m.evidence(key) }?.code == "unreadable")
    }

    @Test func theDetailKeepsTheChoicesInTheOrderSentAndTheMembersOwnChoice() async throws {
        let ops = FakeVoteOps()
        ops.detail = obj(#"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","title":"T","state":"open","can_cast":true,"text":"Line one\n\nLine two <b>x</b> http://example.test","choices":[{"id":"no","label":"No"},{"id":"abstain","label":"Yes, really"},{"id":"yes","label":"Yes"}],"quorum":{"text":"Half","min_ballots":2},"binding":true,"record_tag":"AAAA","choice_id":"yes","extensions":1}"#)
        let m = manager(ops)
        let d = try await m.get(key)
        #expect(d.choices.map(\.id) == ["no", "abstain", "yes"])
        // The reserved abstain keeps the label it was sent with.
        #expect(d.choices[1].label == "Yes, really")
        #expect(d.choiceID == "yes")
        #expect(d.text == "Line one\n\nLine two <b>x</b> http://example.test")
        #expect(d.minBallots == 2)
        #expect(d.binding == true)
        #expect(!"\(d)".contains("yes"))
        ops.detail = obj(#"{"proposal_id":"\#(pid)"}"#)
        #expect(await failure { try await m.get(key) }?.code == "unreadable")
    }

    @Test func aVoteEventReadsTheListAgain() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = manager(ops)
        m.onEvent(event("vote.event", #"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","event":"ballot","state":"open"}"#))
        #expect(await eventually { m.votes.count == 1 })
        #expect(ops.calls.filter { $0 == "list" }.count == 1)
        m.onEvent(event("sync.event", #"{"kind":"x"}"#))
        try await Task.sleep(for: .milliseconds(50))
        #expect(ops.calls.filter { $0 == "list" }.count == 1)
    }

    @Test func eventsWhileAReadIsQueuedAreOneRead() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let m = manager(ops)
        let first = Task { try await m.refresh() }
        #expect(await eventually { ops.calls.count == 1 })
        for _ in 0..<5 { m.onEvent(event("vote.event", #"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","event":"ballot","state":"open"}"#)) }
        gate.complete(())
        try await first.value
        #expect(await eventually { ops.calls.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(ops.calls.count == 2)
    }

    @Test func aLockForgetsEverythingAndALateAnswerIsNotApplied() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(extra: #","site":"not_listed""#))
        let m = manager(ops)
        try await m.refresh()
        #expect(!m.hints.isEmpty)
        m.clear()
        #expect(m.votes.isEmpty)
        #expect(m.load == .notLoaded)
        #expect(m.hints.isEmpty)
        #expect(m.listVersion == nil)
        // A read that began before the lock is not applied after it.
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let late = Task { try await m.refresh() }
        #expect(await eventually { ops.calls.count == 2 })
        m.clear()
        gate.complete(())
        try await late.value
        #expect(m.votes.isEmpty)
        #expect(m.availability == .unknown)
    }

    @Test func aVoteMissingFromTheSiteIsLateAfterTenMinutesAndOnlyThen() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(extra: #","site":"not_listed""#))
        let m = manager(ops)
        try await m.refresh()
        let h = try #require(m.hints[key])
        #expect(!h.notListedLate(clock.date))
        #expect(!h.notListedLate(clock.date.addingTimeInterval(9 * 60)))
        #expect(h.notListedLate(clock.date.addingTimeInterval(10 * 60)))
        // Read again later: the first time it was seen missing is kept.
        clock.advance(300_000)
        try await m.refresh()
        #expect(m.hints[key]?.notListedSince == Self.start)
        // Listed again: the stamp goes.
        ops.list = listing(summary(extra: #","site":"matches""#))
        try await m.refresh()
        #expect(m.hints.isEmpty)
    }

    @Test func aNoticeAcknowledgedWhileAReadIsOnItsWayStaysAcknowledged() async throws {
        let ops = FakeVoteOps()
        ops.list = obj(#"{"votes":[],"dropped":[{"connection_id":"c1","count":3}],"problems":[],"reconnect":[]}"#)
        let m = manager(ops)
        try await m.refresh()
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let read = Task { try await m.refresh() }
        #expect(await eventually { ops.calls.count == 2 })
        // The read on its way was answered before the vault had the acknowledgement.
        m.acknowledgeDropped(["c1"])
        gate.complete(())
        try await read.value
        #expect(m.dropped.isEmpty)
        ops.listGate = nil
        #expect(await eventually { ops.acks.last == ["c1"] })
    }

    @Test func atMostOneHundredTwentyEightAcknowledgementsGoWithOneRead() async throws {
        let ops = FakeVoteOps()
        let ids = (0..<130).map { "c\($0)" }
        let entries = ids.map { #"{"connection_id":"\#($0)","count":1}"# }.joined(separator: ",")
        ops.list = obj(#"{"votes":[],"dropped":[\#(entries)],"problems":[],"reconnect":[]}"#)
        let m = manager(ops)
        try await m.refresh()
        m.acknowledgeDropped(ids)
        #expect(m.dropped.isEmpty)
        #expect(await eventually { ops.acks.count >= 2 })
        #expect(ops.acks[1] == Array(ids.prefix(128)))
        // The rest go with the read that follows at once.
        #expect(await eventually { ops.acks.count == 3 })
        #expect(ops.acks[2] == ["c128", "c129"])
        try await m.refresh()
        #expect(ops.acks.last == [])
    }

    @Test func noVotesShowsNothingAndSendsNothing() async {
        let n = NoVotes()
        #expect(n.entry == VotesEntry())
        #expect(n.availability == .unsupported)
        #expect(await failure { try await n.cast(key, choiceID: "yes", password: nil) }?.kind == .notSupported)
        #expect(await failure { try await n.refresh() }?.kind == .notSupported)
    }
}

// swiftlint:enable line_length
