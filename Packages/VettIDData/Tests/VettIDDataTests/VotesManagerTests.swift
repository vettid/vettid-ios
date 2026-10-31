import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

private let conn = "conn-1"
private let pid = "01JBQZ0000000000000000000A"
private let key = VoteKey(connectionID: conn, proposalID: pid)

private func obj(_ s: String) -> JsonObject { (try? StrictJson.parseObject(s)) ?? VaultJSON.object([]) }

/// TEST ONLY. The vault calls of ``VotesManager``, as vettid-vault's `features/vote` answers them.
@MainActor
final class FakeVoteOps: VoteOps, @unchecked Sendable {
    var list = obj("{}")
    var detail = obj("{}")
    var evidence = obj(#"{"evidence":{"proposal":"AAAA","member":{"ballot":{"choice_id":"yes"}}}}"#)
    var calls: [String] = []
    var acks: [[String]] = []
    var refuse: [String: String] = [:]
    var castGate: TestDeferred<Void>?
    var listGate: TestDeferred<Void>?

    private func go(_ type: String) throws {
        calls.append(type)
        if let code = refuse[type] { throw VaultOpError(type: type, code: code, detail: "", body: nil) }
    }

    private static func name(_ k: VoteKey) -> String { "\(k.connectionID)/\(k.proposalID)" }

    nonisolated func voteList(after: String?, ack: [String]) async throws -> JsonObject {
        try await MainActor.run { try go("list"); acks.append(ack) }
        let gate = await MainActor.run { listGate }
        if let gate { try await gate.value() }
        return await MainActor.run { list }
    }

    nonisolated func voteGet(_ key: VoteKey) async throws -> JsonObject {
        try await MainActor.run { try go("get:\(Self.name(key))"); return detail }
    }

    nonisolated func voteCast(_ key: VoteKey, choiceID: String) async throws -> JsonObject {
        let gate = await MainActor.run { castGate }
        if let gate { try await gate.value() }
        try await MainActor.run { try go("cast:\(Self.name(key)):\(choiceID)") }
        return obj(#"{"proposal_id":"\#(key.proposalID)","ballot":{"state":"sending"}}"#)
    }

    nonisolated func voteCheck(_ key: VoteKey) async throws { try await MainActor.run { try go("check:\(Self.name(key))") } }

    nonisolated func voteConfirm(_ key: VoteKey, mine: Bool) async throws -> JsonObject {
        try await MainActor.run { try go("confirm:\(Self.name(key)):\(mine)") }
        return obj(#"{"ballot":{"state":"\#(mine ? "recorded" : "disputed")"}}"#)
    }

    nonisolated func voteEvidence(_ key: VoteKey) async throws -> JsonObject {
        try await MainActor.run { try go("evidence:\(Self.name(key))"); return evidence }
    }

    nonisolated func voteRelease(_ key: VoteKey, pin: String) async throws { try await MainActor.run { try go("release:\(Self.name(key))") } }
}

/// The credential's unlock window as the tests drive it.
@MainActor
final class TestWindow {
    var until: Date?
    var opened: [String] = []
    var closed = 0
    var openFail: VaultFailure?
    var closeFail: VaultFailure?
}

/// The votes list and the cast (IOS-PLAN §4.16, ANDROID-PLAN 0.1.108 "Votes"; VAULT-MESSAGING 0.81.3 §10.19.8). Mirrors
/// the list and cast part of vettid-android `VotesManagerTest` (the site and the results come with that work).
@MainActor
struct VotesManagerTests {
    private static let start = Date(timeIntervalSince1970: 1_793_534_400) // 2026-11-01T12:00:00Z
    private let clock = TestClock(1_793_534_400_000)

    private func summary(id: String = pid, conn c: String = conn, state: String = "open", extra: String = "") -> String {
        #"{"proposal_id":"\#(id)","connection_id":"\#(c)","title":"Adopt the budget","state":"\#(state)","opens_at":"2026-11-01T09:00:00.000Z","closes_at":"2026-11-06T17:00:00.000Z","can_cast":true\#(extra)}"#
    }

    private func listing(_ votes: String..., tail: String = "") -> JsonObject {
        obj(#"{"votes":[\#(votes.joined(separator: ","))],"dropped":[],"problems":[],"reconnect":[]\#(tail)}"#)
    }

    private func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: clock.date, body: Array(body.utf8)))
    }

    private func manager(_ ops: FakeVoteOps, window: TestWindow = TestWindow(), gated: @escaping @MainActor () -> Bool = { false }) -> VotesManager {
        let c = clock
        return VotesManager(
            ops: { ops },
            gated: gated,
            windowUntil: { window.until },
            openWindow: { password in
                window.opened.append(password)
                window.until = c.date.addingTimeInterval(300)
                if let f = window.openFail { throw f }
            },
            closeWindow: {
                window.closed += 1
                window.until = nil
                if let f = window.closeFail { throw f }
            },
            unlockTtl: { 300 },
            now: { c.date }
        )
    }

    private func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

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

    @Test func aCastOpensTheWindowOnlyWhenItIsClosedAndClosesWhatItOpened() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let window = TestWindow()
        let m = manager(ops, window: window)
        try await m.refresh()
        #expect(try await m.cast(key, choiceID: "yes", password: "secret") == .sending)
        #expect(window.opened == ["secret"])
        #expect(window.closed == 1)
        #expect(ops.calls.contains("cast:\(conn)/\(pid):yes"))
        // Sent once.
        #expect(ops.calls.filter { $0.hasPrefix("cast") }.count == 1)

        // A window that is already open is used and left as it was; the password is not used.
        window.until = clock.date.addingTimeInterval(120)
        #expect(m.windowOpen())
        _ = try await m.cast(key, choiceID: "no", password: "unused")
        #expect(window.opened.count == 1)
        #expect(window.closed == 1)
    }

    @Test func aCastWithAClosedWindowAndNoPasswordIsRefusedByTheVaultAndSaysSo() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        ops.refuse["cast:\(conn)/\(pid):yes"] = "credential_locked"
        let m = manager(ops)
        try await m.refresh()
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: nil) }?.kind == .credentialLocked)
        // Never tried again after the refusal.
        #expect(ops.calls.filter { $0.hasPrefix("cast") }.count == 1)
    }

    @Test func noCastWhileARestoreWaitsForConfirmation() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(extra: #","confirm_pending":true"#))
        let window = TestWindow()
        let m = manager(ops, window: window)
        try await m.refresh()
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.code == "checking")
        // Nothing was sent, and no window was opened for it.
        #expect(!ops.calls.contains { $0.hasPrefix("cast") })
        #expect(window.opened.isEmpty)
    }

    @Test func aWindowThePromptOpenedIsClosedEvenWhenTheCastFails() async {
        let ops = FakeVoteOps()
        ops.refuse["cast:\(conn)/\(pid):yes"] = "not_open"
        let window = TestWindow()
        let m = manager(ops, window: window)
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.code == "not_open")
        #expect(window.closed == 1)
    }

    @Test func aCancelledCastStillLocksTheWindowItOpened() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let gate = TestDeferred<Void>()
        ops.castGate = gate
        let window = TestWindow()
        let m = manager(ops, window: window)
        try await m.refresh()
        let job = Task { try await m.cast(key, choiceID: "yes", password: "pw") }
        #expect(await eventually { !window.opened.isEmpty })
        job.cancel()
        _ = await job.result
        // The lock ran to its end although its caller was cancelled (a screen that left).
        #expect(window.closed == 1)
        #expect(m.windowNotClosed == nil)
    }

    @Test func anUnlockWhoseAnswerWasLostIsStillLocked() async {
        let ops = FakeVoteOps()
        let window = TestWindow()
        window.openFail = VaultFailure(.noResponse)
        let m = manager(ops, window: window)
        #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.kind == .noResponse)
        #expect(window.closed == 1)
        #expect(!ops.calls.contains { $0.hasPrefix("cast") })
    }

    @Test func anUnlockThatFailsInAnyWayButARefusalIsStillLocked() async {
        for f in [VaultFailure(.other, code: "unreadable_result"), VaultFailure(.network)] {
            let window = TestWindow()
            window.openFail = f
            let m = manager(FakeVoteOps(), window: window)
            _ = await failure { try await m.cast(key, choiceID: "yes", password: "pw") }
            #expect(window.closed == 1, "\(f.kind)")
        }
        // Only a definite refusal opened nothing.
        for kind: FailureKind in [.badPassword, .backoff, .credentialFrozen, .rotationRequired, .ownerCheckRequired, .credentialUnsettled] {
            let window = TestWindow()
            window.openFail = VaultFailure(kind)
            let m = manager(FakeVoteOps(), window: window)
            #expect(await failure { try await m.cast(key, choiceID: "yes", password: "pw") }?.kind == kind)
            #expect(window.closed == 0, "\(kind)")
        }
    }

    @Test func aLockThatFailedIsToldNotSwallowed() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let window = TestWindow()
        window.closeFail = VaultFailure(.noResponse)
        let m = manager(ops, window: window)
        try await m.refresh()
        _ = try await m.cast(key, choiceID: "yes", password: "pw")
        // The notice knows how long the window stays open unused.
        #expect(m.windowNotClosed == WindowNotClosed(ttlSeconds: 300))
        // Close it now: the notice stays while the lock fails, and goes only when it went through.
        #expect(await failure { try await m.closeWindowNow() } != nil)
        #expect(m.windowNotClosed == WindowNotClosed(ttlSeconds: 300))
        window.closeFail = nil
        try await m.closeWindowNow()
        #expect(m.windowNotClosed == nil)
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

    @Test func noVotesShowsNothingAndSendsNothing() async {
        let n = NoVotes()
        #expect(n.entry == VotesEntry())
        #expect(n.availability == .unsupported)
        #expect(await failure { try await n.cast(key, choiceID: "yes", password: nil) }?.kind == .notSupported)
        #expect(await failure { try await n.refresh() }?.kind == .notSupported)
    }
}

// swiftlint:enable line_length
