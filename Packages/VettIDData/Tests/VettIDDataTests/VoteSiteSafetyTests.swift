import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

private let pid = VoteFixture.pid
private let key = VoteFixture.key
private let pid2 = "01JBQZ0000000000000000000B"

/// What the app hands the vault from a site that serves odd things, how a lock or the app leaving ends the work that goes
/// on, and the schedule (IOS-PLAN §4.16 "The site"). The vault refuses a whole `vote.site.sync` or `vote.results.submit`
/// call for one malformed item (vettid-vault `features/vote/sync.go`, `api.go`), so the app sends only what it takes.
@MainActor
struct VoteSiteSafetyTests: VotesTestCase {
    let clock = TestClock(1_793_534_400_000)
    let site = FakeVoteSite()
    let vault = FakeVoteSiteOps()
    let sleeper = TestSleeper()

    func manager(_ ops: FakeVoteOps) -> VotesManager {
        let c = clock
        let vault = vault
        let sleeper = sleeper
        return VotesManager(
            ops: { ops }, now: { c.date }, site: site, siteOps: { _ in vault }, sleep: { d in try await sleeper.sleep(d) }
        )
    }

    func opened(_ extra: String = "") -> (FakeVoteOps, VotesManager) {
        let ops = FakeVoteOps()
        ops.list = listing(summary(extra: extra))
        return (ops, manager(ops))
    }

    func serve(_ v: Int64, sig: [UInt8]? = nil, doc: [UInt8]? = nil) {
        let l = VoteSyncTests.list(v)
        site["services.json"] = .found(doc ?? l.doc)
        site["services.json.sig"] = .found(sig ?? l.sig)
    }

    func entry() throws -> JsonObject { try #require(try vault.entries().first(where: { try $0.string("proposal_id") == pid })) }

    // MARK: What the vault would refuse the whole call for

    @Test func aListWithABadSignatureOrNoDocumentIsNotSent() async throws {
        let (_, m) = opened()
        serve(1, sig: [UInt8](repeating: 7, count: 63))
        try await m.syncOnce()
        serve(1, sig: [UInt8](repeating: 7, count: 65))
        try await m.syncOnce()
        serve(1, doc: [])
        try await m.syncOnce()
        #expect(try vault.servicesCalls().compactMap { $0 }.isEmpty)
        // The entries of the same runs went.
        #expect(!vault.syncs.isEmpty)
    }

    @Test func aBadVersionInACatchUpEndsThereAndTheGoodOnesBeforeItGo() async throws {
        let (ops, m) = opened(); _ = ops
        ops.list = listing(summary(), tail: #","list_version":1,"list_sha256":"x""#)
        try await m.refresh()
        serve(4)
        let v2 = VoteSyncTests.list(2)
        site["services/2.json"] = .found(v2.doc)
        site["services/2.json.sig"] = .found(v2.sig)
        let v3 = VoteSyncTests.list(3)
        site["services/3.json"] = .found(v3.doc)
        site["services/3.json.sig"] = .found([UInt8](repeating: 1, count: 10))
        try await m.syncOnce()
        #expect(try vault.servicesCalls().compactMap { $0 } == [[2]])
    }

    @Test func aProposalOverTheVaultsLimitIsSentUnreachable() async throws {
        site["p/\(pid)/proposal.json"] = .found([UInt8](repeating: 0x20, count: 65_537))
        let (_, m) = opened()
        try await m.syncOnce()
        #expect(try entry().obj("document").string("status") == "unreachable")
        site["p/\(pid)/proposal.json"] = .found([UInt8](repeating: 0x20, count: 65_536))
        vault.syncs = []
        try await m.syncOnce()
        #expect(try entry().obj("document").string("status") == "found")
    }

    func serveExtension(_ n: Int, doc: [UInt8] = Array(#"{"x":1}"#.utf8), sig: [UInt8]? = [UInt8](repeating: 9, count: 64), bundle: String? = #"{"e":1}"#) {
        site["p/\(pid)/extension-\(n).json"] = .found(doc)
        site["p/\(pid)/extension-\(n).json.sig"] = sig.map { .found($0) }
        site["p/\(pid)/extension-\(n).json.sigstore.json"] = bundle.map { .found(Array($0.utf8)) }
    }

    func extensions() throws -> Int { try entry().obj("document").array("extensions").count }

    @Test func extensionsStopAtTheFirstOneTheVaultWouldRefuse() async throws {
        site.put("p/\(pid)/proposal.json", "{}")
        site.put("index.json", #"[{"proposal_id":"\#(pid)","extended":3}]"#)
        let cases: [(String, () -> Void)] = [
            ("over 4,096 bytes", { serveExtension(2, doc: [UInt8](repeating: 0x20, count: 4_097)) }),
            ("no signature", { serveExtension(2, sig: nil) }),
            ("a signature of 63 bytes", { serveExtension(2, sig: [UInt8](repeating: 9, count: 63)) }),
            ("no bundle", { serveExtension(2, bundle: nil) }),
            ("a bundle that is no object", { serveExtension(2, bundle: "[1]") }),
        ]
        for (why, bad) in cases {
            let (_, m) = opened()
            serveExtension(1)
            bad()
            serveExtension(3)
            vault.syncs = []
            try await m.syncOnce()
            // Extension 1 goes, the bad 2 and the 3 after it do not (they could not be applied before it).
            #expect(try extensions() == 1, Comment(rawValue: why))
        }
    }

    @Test func anExtensionOfExactly4096BytesGoes() async throws {
        site.put("p/\(pid)/proposal.json", "{}")
        site.put("index.json", #"[{"proposal_id":"\#(pid)","extended":1}]"#)
        serveExtension(1, doc: [UInt8](repeating: 0x20, count: 4_096))
        let (_, m) = opened()
        try await m.syncOnce()
        #expect(try extensions() == 1)
    }

    @Test func anIndexElementWithAServiceIDThatIsNoStringIsSentWithoutIndex() async throws {
        site.put("p/\(pid2)/proposal.json", "{}")
        site.put("index.json", #"[{"proposal_id":"\#(pid2)","service_id":7},{"proposal_id":"\#(pid)","service_id":"ab"}]"#)
        let (_, m) = opened()
        try await m.syncOnce()
        let bad = try #require(try vault.entries().first { try $0.string("proposal_id") == pid2 })
        #expect(!bad.has("index") && bad.has("document"))
        #expect(try entry().obj("index").string("service_id") == "ab")
    }

    @Test func aResultsSignatureThatIsNotSixtyFourBytesIsAProblemAndNothingIsSent() async throws {
        for n in [63, 65] {
            VoteResultsFixture.publish(site, pid)
            site["p/\(pid)/results.json.sig"] = .found([UInt8](repeating: 5, count: n))
            let ops = FakeVoteOps()
            ops.list = listing(summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"pending"}"#))
            ops.detail = voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(VoteFixture.conn)","title":"t","state":"closed","text":"t","choices":[{"id":"yes","label":"Yes"}],"record_tag":"\#(Base64s.encodeStd(VoteResultsFixture.tag))","extensions":0}"#)
            let m = manager(ops)
            try await m.syncOnce()
            #expect(vault.submits.isEmpty)
            #expect(m.hints[key]?.resultsProblem == true)
        }
    }

    @Test func aRefusedStageDoesNotStarveTheResults() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = FakeVoteOps()
        ops.list = listing(summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"pending"}"#))
        ops.detail = voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(VoteFixture.conn)","title":"t","state":"closed","text":"t","choices":[{"id":"yes","label":"Yes"}],"record_tag":"\#(Base64s.encodeStd(VoteResultsFixture.tag))","extensions":0}"#)
        let m = manager(ops)
        // No list is served, so the first call is the proposals': the vault refuses it.
        vault.syncRefusal = "bad_request"
        await #expect(throws: VaultFailure.self) { try await m.syncOnce() }
        #expect(vault.submits.count == 1)
        // And a refused list does not starve the proposals.
        serve(1)
        vault.syncRefusal = "bad_request"
        vault.syncs = []
        await #expect(throws: VaultFailure.self) { try await m.syncOnce() }
        #expect(!vault.syncs.isEmpty)
    }

    // MARK: A lock or the app leaving ends what goes on

    /// Holds the read of [path] until the test lets it go.
    func holding(_ path: String) -> (gate: TestDeferred<Void>, reached: TestDeferred<Void>) {
        let gate = TestDeferred<Void>()
        let reached = TestDeferred<Void>()
        site.hold = { p in
            guard p == path else { return }
            await reached.complete(())
            try? await gate.value()
        }
        return (gate, reached)
    }

    func closedOps() -> FakeVoteOps {
        let ops = FakeVoteOps()
        ops.list = listing(summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"pending"}"#))
        ops.detail = voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(VoteFixture.conn)","title":"t","state":"closed","text":"t","choices":[{"id":"yes","label":"Yes"}],"record_tag":"\#(Base64s.encodeStd(VoteResultsFixture.tag))","extensions":0}"#)
        return ops
    }

    func afterLeaving(holdAt path: String, leave: (VotesManager) -> Void) async throws {
        VoteResultsFixture.publish(site, pid)
        serve(1)
        let ops = closedOps()
        let m = manager(ops)
        try await m.refresh()
        let (gate, reached) = holding(path)
        let run = Task { try? await m.syncOnce() }
        #expect(await eventually { reached.isCompleted })
        let reads = site.reads, syncs = vault.syncs.count, submits = vault.submits.count, calls = ops.calls
        leave(m)
        gate.complete(())
        await run.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(site.reads == reads && vault.syncs.count == syncs && vault.submits.count == submits && ops.calls == calls)
        #expect(m.hints.isEmpty)
    }

    @Test func aLockDuringTheListsEndsTheRun() async throws {
        try await afterLeaving(holdAt: "services.json") { $0.clear() }
    }

    @Test func aLockDuringTheResultsEndsTheRun() async throws {
        try await afterLeaving(holdAt: "p/\(pid)/rows.json") { $0.clear() }
    }

    @Test func theAppLeavingDuringTheProposalsEndsTheRun() async throws {
        try await afterLeaving(holdAt: "index.json") { $0.pauseSync() }
    }

    @Test func theAppLeavingDuringTheResultsEndsTheRun() async throws {
        try await afterLeaving(holdAt: "p/\(pid)/results.json.sig") { $0.pauseSync() }
    }

    // MARK: The schedule

    @Test func aQuickReturnKeepsTheHourAndALaterOneRunsAtOnce() async throws {
        serve(1)
        let (_, m) = opened()
        try await m.refresh()
        m.startSync()
        #expect(await eventually { sleeper.waits.count == 1 })
        m.pauseSync()
        site.clearReads()
        // Back after five minutes: no run; the hour goes on with what is left of it.
        clock.advance(5 * 60_000)
        m.resumeSync()
        #expect(await eventually { sleeper.waits.count == 2 })
        #expect(sleeper.waits[1] == .seconds(3300))
        #expect(site.reads.isEmpty)
        // Away again, back after eleven minutes in all: a run now, and a whole hour after it.
        m.pauseSync()
        clock.advance(6 * 60_000)
        m.resumeSync()
        #expect(await eventually { sleeper.waits.count == 3 })
        #expect(sleeper.waits[2] == .seconds(3600) && site.reads.contains("services.json"))
    }

    // MARK: Work begun just before a halt

    @Test func aCheckBegunJustBeforeALockDoesNotRun() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = closedOps()
        let m = manager(ops)
        try await m.refresh()
        let caller = Task { try? await m.checkResults(key) }
        // The call has made its work and waits; the lock comes before that work starts.
        await Task.yield()
        m.clear()
        _ = await caller.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(vault.submits.isEmpty && site.reads.isEmpty)
    }

    @Test func aCheckDueEventWhoseReadMeetsTheAppLeavingSendsNothing() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = closedOps()
        let m = manager(ops)
        try await m.refresh()
        m.startSync()
        #expect(await eventually { sleeper.waits.count == 1 })
        vault.submits = []
        site.clearReads()
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        m.onEvent(event("vote.event", #"{"proposal_id":"\#(pid)","connection_id":"\#(VoteFixture.conn)","event":"check_due","state":"closed"}"#))
        try await Task.sleep(for: .milliseconds(50))
        m.pauseSync()
        gate.complete(())
        try await Task.sleep(for: .milliseconds(100))
        #expect(vault.submits.isEmpty && site.reads.isEmpty)
    }

    // MARK: A lost session ends the run

    @Test func aLostSessionOnTheListsEndsTheRunAtOnce() async throws {
        serve(1)
        site.put("index.json", "[]")
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let c = clock
        let m = VotesManager(
            ops: { ops }, now: { c.date }, site: site,
            siteOps: { _ in throw VaultFailure(.other, code: "session_dropped") }, sleep: { _ in }
        )
        await #expect(throws: VaultFailure.self) { try await m.syncOnce() }
        #expect(!site.reads.contains("index.json") && !site.reads.contains { $0.hasPrefix("p/") })
    }

    @Test func aRefusalOfTheListsLetsTheOtherStagesGoOn() async throws {
        serve(1)
        vault.syncRefusal = "limit"
        let (_, m) = opened()
        await #expect(throws: VaultFailure.self) { try await m.syncOnce() }
        #expect(site.reads.contains("index.json"))
    }

    @Test func aRunThatFailedStillEndsTheReturnThrottle() async throws {
        serve(1)
        vault.syncRefusal = "bad_request"
        let (_, m) = opened()
        try await m.refresh()
        m.startSync()
        #expect(await eventually { sleeper.waits.count == 1 })
        m.pauseSync()
        site.clearReads()
        clock.advance(5 * 60_000)
        m.resumeSync()
        #expect(await eventually { sleeper.waits.count == 2 })
        #expect(site.reads.isEmpty)
    }

    // MARK: The attempts at the results

    @Test func aCheckAlreadyOnItsWayIsNotSubmittedTwice() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = closedOps()
        let m = manager(ops)
        try await m.refresh()
        let (gate, reached) = holding("p/\(pid)/results.json")
        let first = Task { try await m.checkResults(key) }
        #expect(await eventually { reached.isCompleted })
        // The hourly run and a `check_due` event meet it: neither starts another.
        let hourly = Task { try? await m.syncOnce() }
        m.onEvent(event("vote.event", #"{"proposal_id":"\#(pid)","connection_id":"\#(VoteFixture.conn)","event":"check_due","state":"closed"}"#))
        let joined = Task { try await m.checkResults(key) }
        try await Task.sleep(for: .milliseconds(50))
        gate.complete(())
        _ = try await first.value
        _ = try await joined.value
        await hourly.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(vault.submits.count == 1)
    }

    // MARK: The runner and its manager

    @Test func aManagerLetGoWithoutALockLeavesNothingRunning() async throws {
        serve(1)
        weak var gone: VotesManager?
        do {
            let (_, m) = opened()
            gone = m
            try await m.refresh()
            m.startSync()
            #expect(await eventually { sleeper.waits.count == 1 })
        }
        #expect(gone == nil)
        // The hour passes: the loop ends and does not touch the manager.
        sleeper.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sleeper.waits.count == 1)
    }
}

// swiftlint:enable line_length
