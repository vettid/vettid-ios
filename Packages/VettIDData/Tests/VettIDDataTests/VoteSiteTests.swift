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

/// The app's work with the public votes site for the vault (IOS-PLAN §4.16 "The site"; ANDROID-PLAN 0.1.107/0.1.108;
/// VAULT-MESSAGING 0.81.4 §10.19.8): the runs, their limits and schedule, the documents of a vote, and the results check.
/// Mirrors vettid-android `VoteSyncTest` and the site part of `VotesManagerTest`.
@MainActor
struct VoteSiteTests: VotesTestCase {
    let clock = TestClock(1_793_534_400_000)
    let site = FakeVoteSite()
    let vault = FakeVoteSiteOps()
    let sleeper = TestSleeper()

    func siteManager(_ ops: FakeVoteOps, gated: @escaping @MainActor () -> Bool = { false }, siteOK: Bool = true) -> VotesManager {
        let c = clock
        let vault = vault
        let sleeper = sleeper
        return VotesManager(
            ops: { ops }, gated: gated, now: { c.date }, site: site,
            siteOps: { _ in
                guard siteOK else { throw VaultFailure(.other, code: "session_dropped") }
                return vault
            },
            sleep: { d in try await sleeper.sleep(d) }
        )
    }

    @discardableResult
    func serveList(_ v: Int64, size: Int = 64) -> VoteSync.ServedList {
        let l = VoteSyncTests.list(v, size: size)
        site["services.json"] = .found(l.doc)
        site["services.json.sig"] = .found(l.sig)
        return l
    }

    func serveVersion(_ l: VoteSync.ServedList) {
        site["services/\(l.version).json"] = .found(l.doc)
        site["services/\(l.version).json.sig"] = .found(l.sig)
    }

    // MARK: The service list

    @Test func aListThatTheVaultHoldsIsOnlyConfirmed() async throws {
        let l = serveList(3)
        let ops = FakeVoteOps()
        ops.list = listing(summary(), tail: #","list_version":3,"list_sha256":"\#(VoteSyncTests.sha(l))""#)
        let m = siteManager(ops)
        try await m.syncOnce()
        let first = try StrictJson.parseObject(try #require(vault.syncs.first))
        #expect(try first.obj("services_confirm").uint("version", min: 0, max: 9) == 3)
        #expect(try vault.servicesCalls().compactMap { $0 }.isEmpty)
    }

    @Test func aDifferentListIsSentAndACatchUpGoesInVersionOrder() async throws {
        let v4 = serveList(4)
        serveVersion(VoteSyncTests.list(2))
        serveVersion(VoteSyncTests.list(3))
        let ops = FakeVoteOps()
        ops.list = listing(summary(), tail: #","list_version":1,"list_sha256":"held""#)
        let m = siteManager(ops)
        try await m.syncOnce()
        #expect(try vault.servicesCalls().compactMap { $0 } == [[2, 3, 4]])
        #expect(v4.version == 4)
        // v3 not served yet: only v2 goes, the rest at a later run.
        vault.syncs = []
        site["services/3.json"] = nil
        try await m.syncOnce()
        #expect(try vault.servicesCalls().compactMap { $0 } == [[2]])
    }

    @Test func aBigListTravelsAsOneClaimCheckBlobAndASmallBodyInline() async throws {
        serveList(1, size: 4_194_304)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.syncOnce()
        // One upload and one blob call for the list; the entries' small body inline.
        #expect(vault.uploadCalls == 1 && vault.blobSyncs == 1)
        #expect(try vault.servicesCalls().compactMap { $0 } == [[1]])
        let blobBody = try #require(vault.syncs.first)
        #expect(blobBody.count > VoteSync.inlineMax && blobBody.count <= VoteSync.bodyMax)
        #expect(vault.inlineSyncs >= 1)
        #expect(vault.syncs.dropFirst().allSatisfy { $0.count <= VoteSync.inlineMax })
    }

    @Test func aStorageFullUploadIsTriedOnceMoreAfterAWait() async throws {
        serveList(1, size: 300_000)
        vault.quotaRefusals = 1
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        let run = Task { try await m.syncOnce() }
        #expect(await eventually { sleeper.waits == [.seconds(5)] })
        sleeper.release()
        try await run.value
        #expect(vault.uploadCalls == 2 && vault.blobSyncs == 1)
    }

    @Test func aListOverTheBodyLimitIsNeverSentButTheEntriesStillGo() async throws {
        serveList(1, size: VoteSync.bodyMax + 1)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.syncOnce()
        #expect(vault.uploadCalls == 0)
        #expect(try vault.servicesCalls().compactMap { $0 }.isEmpty)
        #expect(try vault.entries().count == 1)
    }

    @Test func aListTheVaultRefusesAsTooLargeLeavesTheRestOfTheRun() async throws {
        serveList(1)
        vault.syncRefusal = "payload_too_large"
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.syncOnce()
        // The proposals' documents were still read after the refused list.
        #expect(site.reads.contains("p/\(pid)/proposal.json"))
    }

    // MARK: The proposals

    @Test func aHeldProposalMissingFromTheIndexIsFetchedAndA404IsAbsentWithNoTime() async throws {
        site.put("index.json", "[]")
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.syncOnce()
        #expect(site.reads.contains("p/\(pid)/proposal.json"))
        let e = try #require(try vault.entries().first)
        #expect(try e.string("proposal_id") == pid && !e.has("index"))
        let doc = try e.obj("document")
        #expect(try doc.string("status") == "absent" && doc.members.map(\.name) == ["status"])
        // Fetched again at the next run and when the vote's screen opens.
        site.clearReads()
        try await m.syncOnce()
        #expect(site.reads.contains("p/\(pid)/proposal.json"))
        site.clearReads()
        vault.syncs = []
        try await m.siteCheck(key)
        #expect(site.reads.contains("p/\(pid)/proposal.json") && site.reads.contains("index.json"))
        #expect(try vault.entries().map { try $0.string("proposal_id") } == [pid])
    }

    @Test func anUnreachableDocumentIsUnreachableAndAnOddOneFound() async throws {
        let p2id = "01JBQZ0000000000000000000B"
        site["p/\(pid)/proposal.json"] = .unreachable
        site.put("p/\(p2id)/proposal.json", "not json at all")
        site.put("index.json", #"[{"proposal_id":"\#(p2id)","extended":0}]"#)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.syncOnce()
        let entries = try vault.entries()
        let byID = Dictionary(uniqueKeysWithValues: try entries.map { (try $0.string("proposal_id"), $0) })
        #expect(try byID[pid]?.obj("document").string("status") == "unreachable")
        // A proposal of the index the vault does not hold goes with its index element, its document as served.
        let p2 = try #require(byID[p2id])
        #expect(try p2.obj("index").string("proposal_id") == p2id)
        #expect(try p2.obj("document").string("status") == "found" && p2.obj("document").base64("proposal") == Array("not json at all".utf8))
    }

    @Test func anIndexIdThatIsNoUlidIsNeverFetched() async throws {
        site.put("index.json", #"[{"proposal_id":"../services"},{"proposal_id":"p1"}]"#)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        try await siteManager(ops).syncOnce()
        #expect(!site.reads.contains { $0.contains("..") || $0.hasPrefix("p/p1") })
        #expect(try vault.entries().map { try $0.string("proposal_id") } == [pid])
    }

    @Test func aProposalsSignatureBundleAndExtensionsGoAsServed() async throws {
        site.put("index.json", #"[{"proposal_id":"\#(pid)","extended":1}]"#)
        site.put("p/\(pid)/proposal.json", #"{"p":1}"#)
        site["p/\(pid)/proposal.json.sig"] = .found([UInt8](repeating: 8, count: 64))
        site.put("p/\(pid)/proposal.json.sigstore.json", #"{ "b" : 1 }"#)
        site.put("p/\(pid)/extension-1.json", #"{"x":1}"#)
        site["p/\(pid)/extension-1.json.sig"] = .found([UInt8](repeating: 9, count: 64))
        site.put("p/\(pid)/extension-1.json.sigstore.json", #"{ "e" : 1 }"#)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.syncOnce()
        let d = try #require(try vault.entries().first).obj("document")
        #expect(try d.base64("proposal_sig").count == 64)
        #expect(try d.obj("bundle").raw == #"{"b":1}"#)
        let x = try d.array("extensions").map { try $0.asObject() }
        #expect(try x.count == 1 && x[0].base64("extension") == Array(#"{"x":1}"#.utf8))
        #expect(try x[0].base64("extension_sig", 64) == [UInt8](repeating: 9, count: 64) && x[0].obj("bundle").raw == #"{"e":1}"#)
        // `extended` 1: the second extension is not asked for.
        #expect(!site.reads.contains("p/\(pid)/extension-2.json"))
    }

    // MARK: When it runs

    @Test func noRequestIsMadeWithoutASession() async throws {
        serveList(1)
        let ops = FakeVoteOps()
        ops.refuse["list"] = "session_dropped"
        let m = siteManager(ops, siteOK: false)
        try? await m.syncOnce()
        #expect(site.reads.isEmpty && vault.syncs.isEmpty)
    }

    @Test func aHeldVaultIsHandedNothingAndTheSiteIsNotRead() async throws {
        serveList(1)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        var held = false
        let m = siteManager(ops, gated: { held })
        try await m.refresh()
        held = true
        try await m.syncOnce()
        #expect(site.reads.isEmpty && vault.syncs.isEmpty)
    }

    @Test func aBuildWithoutASiteFetchesNothing() async throws {
        site.configured = false
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.syncOnce()
        try await m.siteCheck(key)
        #expect(site.reads.isEmpty && vault.syncs.isEmpty)
        #expect(try await m.checkResults(key) == .siteUnreachable)
    }

    @Test func theWorkRunsAtTheOpeningThenHourlyAndStopsAtTheLock() async throws {
        serveList(1)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.refresh()
        m.startSync()
        // The opening read the list: the first run does not read it again.
        #expect(await eventually { sleeper.waits.count == 1 })
        #expect(sleeper.waits == [.seconds(3600)])
        #expect(ops.calls == ["list"])
        #expect(site.reads.contains("services.json"))
        sleeper.release()
        #expect(await eventually { sleeper.waits.count == 2 })
        #expect(ops.calls == ["list", "list"])
        // The lock: no more runs.
        m.clear()
        site.clearReads()
        sleeper.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(site.reads.isEmpty && sleeper.waits.count == 2)
    }

    @Test func nothingRunsWhileTheAppIsAwayAndARunFollowsItsReturn() async throws {
        serveList(1)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.refresh()
        // Not started (the vault is not open): a return to the foreground runs nothing.
        m.resumeSync()
        try await Task.sleep(for: .milliseconds(50))
        #expect(site.reads.isEmpty)
        m.startSync()
        #expect(await eventually { sleeper.waits.count == 1 })
        m.pauseSync()
        site.clearReads()
        sleeper.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(site.reads.isEmpty)
        // Away for a quarter of an hour: the run follows the return.
        clock.advance(15 * 60_000)
        m.resumeSync()
        #expect(await eventually { sleeper.waits.count == 2 })
        #expect(site.reads.contains("services.json") && ops.calls.count == 2)
    }

    @Test func anOpeningThatFinishesWhileTheAppIsAwayRunsAtTheReturn() async throws {
        serveList(1)
        let ops = FakeVoteOps()
        ops.list = listing(summary())
        let m = siteManager(ops)
        try await m.refresh()
        m.pauseSync()
        m.startSync()
        try await Task.sleep(for: .milliseconds(50))
        #expect(site.reads.isEmpty && sleeper.waits.isEmpty)
        m.resumeSync()
        #expect(await eventually { sleeper.waits.count == 1 })
        #expect(site.reads.contains("services.json"))
        // A lock while away leaves nothing to resume.
        m.pauseSync()
        m.clear()
        site.clearReads()
        m.resumeSync()
        try await Task.sleep(for: .milliseconds(50))
        #expect(site.reads.isEmpty)
    }

    // MARK: The results

    func closedPending(due: String = "") -> String {
        summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"pending"\#(due)}"#)
    }

    func detail() -> JsonObject {
        voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","title":"Adopt the budget","state":"closed","text":"t","choices":[{"id":"yes","label":"Yes"}],"record_tag":"\#(Base64s.encodeStd(VoteResultsFixture.tag))","extensions":0}"#)
    }

    @Test func aDueCheckIsFetchedCheckedAndHandedToTheVault() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = FakeVoteOps()
        ops.list = listing(closedPending())
        ops.detail = detail()
        let m = siteManager(ops)
        try await m.syncOnce()
        let body = try StrictJson.parseObject(try #require(vault.submits.first))
        #expect(try body.string("connection_id") == conn && body.string("proposal_id") == pid)
        #expect(try body.base64("results") == VoteResultsFixture.results)
        #expect(try body.obj("bundle").raw == #"{"mediaType":"bundle"}"#)
        let ballot = try body.obj("row").obj("ballot")
        #expect(try ballot.string("choice_id") == "yes" && ballot.base64("vk") == VoteResultsFixture.vk)
        let proof = try body.obj("row_proof")
        #expect(try proof.uint("index", min: 0, max: 9) == 1 && proof.uint("tree_size", min: 0, max: 9) == 2)
        #expect(try proof.array("path").count == 1)
        #expect(m.hints[key] == nil)
    }

    @Test func aCheckNotDueYetIsNotRun() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = FakeVoteOps()
        ops.list = listing(closedPending(due: #","due_at":"2026-11-02T12:00:00.000Z""#))
        ops.detail = detail()
        let m = siteManager(ops)
        try await m.syncOnce()
        #expect(vault.submits.isEmpty)
    }

    @Test func eachResultsOutcomeIsKeptForTheScreens() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(closedPending())
        ops.detail = detail()
        let m = siteManager(ops)
        try await m.refresh()
        // Not published yet.
        #expect(try await m.checkResults(key) == .notPublished)
        #expect(m.hints[key]?.gaveUp == .unpublished)
        // The site down.
        site["p/\(pid)/results.json"] = .unreachable
        #expect(try await m.checkResults(key) == .siteUnreachable)
        #expect(m.hints[key]?.gaveUp == .site)
        // Results the vault could never take.
        site["p/\(pid)/results.json"] = .found([UInt8](repeating: 0x20, count: VoteSiteLimits.resultsMax + 1))
        #expect(try await m.checkResults(key) == .problem)
        #expect(m.hints[key]?.resultsTooLarge == true)
        // Rows that do not hash to the results: a problem the app finds itself, nothing sent.
        VoteResultsFixture.publish(site, pid)
        site.put("p/\(pid)/rows.json", #"{"rows":[]}"#)
        #expect(try await m.checkResults(key) == .problem)
        #expect(m.hints[key]?.resultsProblem == true && m.hints[key]?.resultsTooLarge == false)
        #expect(vault.submits.isEmpty)
        // A submission the vault leaves pending for its input.
        VoteResultsFixture.publish(site, pid)
        vault.submitAnswer = #"{"proposal_id":"\#(pid)","check":{"state":"pending","reason":"input"}}"#
        #expect(try await m.checkResults(key) == .submitted(.pending))
        #expect(m.hints[key]?.resultsProblem == true && m.hints[key]?.gaveUp == nil)
        vault.submitAnswer = #"{"proposal_id":"\#(pid)","check":{"state":"verified"}}"#
        #expect(try await m.checkResults(key) == .submitted(.verified))
        #expect(m.hints[key] == nil)
    }

    @Test func aCheckDueEventRunsTheCheck() async throws {
        VoteResultsFixture.publish(site, pid)
        let ops = FakeVoteOps()
        ops.list = listing(closedPending())
        ops.detail = detail()
        let m = siteManager(ops)
        m.onEvent(event("vote.event", #"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","event":"check_due","state":"closed"}"#))
        #expect(await eventually { vault.submits.count == 1 })
    }

    @Test func aGaveUpCheckIsDiagnosedOnce() async throws {
        let ops = FakeVoteOps()
        let m = siteManager(ops)
        await m.diagnoseGaveUp(key)
        #expect(m.hints[key]?.gaveUp == .unpublished)
        site["p/\(pid)/results.json"] = .unreachable
        await m.diagnoseGaveUp(key)
        // Already known: the site is not asked again.
        #expect(m.hints[key]?.gaveUp == .unpublished)
        #expect(site.reads.count == 1)
    }
}

// swiftlint:enable line_length
