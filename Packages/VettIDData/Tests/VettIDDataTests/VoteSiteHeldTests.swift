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

/// A hold that begins while the work with the public votes site goes on (the owner check past its deadline, the release
/// gate, or the release being checked): no more is read from the site nor sent to the vault, so the site does not learn
/// which votes the member follows meanwhile (IOS-PLAN §4.16 "The site"; VAULT-MESSAGING §3.6.3).
@MainActor
struct VoteSiteHeldTests: VotesTestCase {
    final class Flags {
        var gated = false
        var checking = false
    }

    let clock = TestClock(1_793_534_400_000)
    let site = FakeVoteSite()
    let vault = FakeVoteSiteOps()
    let sleeper = TestSleeper()
    let flags = Flags()

    func manager(_ ops: FakeVoteOps) -> VotesManager {
        let c = clock
        let vault = vault
        let sleeper = sleeper
        let flags = flags
        return VotesManager(
            ops: { ops }, gated: { flags.gated }, siteHeld: { flags.checking }, now: { c.date }, site: site,
            siteOps: { _ in vault }, sleep: { d in try await sleeper.sleep(d) }
        )
    }

    func closedOps() -> FakeVoteOps {
        let ops = FakeVoteOps()
        ops.list = listing(summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"pending"}"#))
        ops.detail = voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(VoteFixture.conn)","title":"t","state":"closed","text":"t","choices":[{"id":"yes","label":"Yes"}],"record_tag":"\#(Base64s.encodeStd(VoteResultsFixture.tag))","extensions":0}"#)
        return ops
    }

    /// A run held at the read of [path] when [hold] begins: once that read ends, nothing more is read or sent.
    func heldDuring(_ path: String, hold: (Flags) -> Void) async throws {
        VoteResultsFixture.publish(site, pid)
        let l = VoteSyncTests.list(1)
        site["services.json"] = .found(l.doc)
        site["services.json.sig"] = .found(l.sig)
        let ops = closedOps()
        let m = manager(ops)
        try await m.refresh()
        let gate = TestDeferred<Void>()
        let reached = TestDeferred<Void>()
        site.hold = { p in
            guard p == path else { return }
            await reached.complete(())
            try? await gate.value()
        }
        let run = Task { try? await m.syncOnce() }
        #expect(await eventually { reached.isCompleted })
        let reads = site.reads.count, syncs = vault.syncs.count, submits = vault.submits.count
        hold(flags)
        gate.complete(())
        await run.value
        try await Task.sleep(for: .milliseconds(50))
        // The read that was on its way ends (the fake site logs it then); nothing after it.
        #expect(site.reads.count == reads + 1 && site.reads.last == path)
        #expect(vault.syncs.count == syncs && vault.submits.count == submits)
    }

    @Test func aHoldDuringTheListsReadsNoMore() async throws {
        try await heldDuring("services.json") { $0.gated = true }
    }

    @Test func aHoldDuringTheProposalsReadsNoMore() async throws {
        try await heldDuring("index.json") { $0.gated = true }
    }

    @Test func theReleaseBeingCheckedDuringTheResultsReadsNoMore() async throws {
        try await heldDuring("p/\(pid)/results.json") { $0.checking = true }
    }

    @Test func aCheckDueEventWhoseReadMeetsAHoldReadsNothing() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = closedOps()
        let m = manager(ops)
        try await m.refresh()
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        m.onEvent(event("vote.event", #"{"proposal_id":"\#(pid)","connection_id":"\#(VoteFixture.conn)","event":"check_due","state":"closed"}"#))
        try await Task.sleep(for: .milliseconds(50))
        flags.gated = true
        gate.complete(())
        try await Task.sleep(for: .milliseconds(100))
        #expect(vault.submits.isEmpty && site.reads.isEmpty)
    }

    @Test func aCheckDueEventWhileTheReleaseIsCheckedReadsNothing() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = closedOps()
        let m = manager(ops)
        try await m.refresh()
        flags.checking = true
        m.onEvent(event("vote.event", #"{"proposal_id":"\#(pid)","connection_id":"\#(VoteFixture.conn)","event":"check_due","state":"closed"}"#))
        try await Task.sleep(for: .milliseconds(100))
        #expect(vault.submits.isEmpty && site.reads.isEmpty)
    }

    @Test func aVotesScreenCheckWhileHeldReadsNothing() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = closedOps()
        let m = manager(ops)
        try await m.refresh()
        flags.checking = true
        _ = try? await m.checkResults(key)
        #expect(vault.submits.isEmpty && site.reads.isEmpty)
    }
}

// swiftlint:enable line_length
