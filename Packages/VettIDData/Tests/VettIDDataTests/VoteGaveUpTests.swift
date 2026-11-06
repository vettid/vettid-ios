import Foundation
import Testing
@testable import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

private let conn = VoteFixture.conn
private let pid = VoteFixture.pid
private let key = VoteFixture.key

/// A network the test sets (true: unmetered, false: metered, nil: cannot be told).
final class TestNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Bool?
    init(_ state: Bool? = nil) { self.state = state }
    var unmetered: Bool? {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }
}

/// A `gave_up` check run again, the rows the app cannot have, and the download cap (VAULT-MESSAGING 0.83.6 §10.19.6; owner
/// decision a, 2026-11-06). Mirrors the `VotesManagerTest` cases of vettid-android #312 and #317.
@MainActor
struct VoteGaveUpTests: VotesTestCase {
    let clock = TestClock(1_793_534_400_000)
    let site = FakeVoteSite()
    let vault = FakeVoteSiteOps()
    let store = MemoryResultsAttemptStore()
    let network = TestNetwork()
    static let gaveUpAnswer = #"{"proposal_id":"p","check":{"state":"gave_up"}}"#

    func manager(_ ops: FakeVoteOps, voteRows: Bool = true, store: (any ResultsAttemptStore)? = nil) -> VotesManager {
        let c = clock
        let vault = vault
        let network = network
        return VotesManager(
            ops: { ops }, now: { c.date }, site: site, siteOps: { _ in vault }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            voteRows: { voteRows }, attempts: store ?? self.store, unmetered: { network.unmetered }
        )
    }

    func gaveUp(reason: String = "") -> String {
        summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"gave_up"\#(reason)}"#)
    }

    func detail() -> JsonObject {
        voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","title":"Adopt the budget","state":"closed","text":"t","choices":[{"id":"yes","label":"Yes"}],"record_tag":"\#(Base64s.encodeStd(VoteResultsFixture.tag))","extensions":0}"#)
    }

    func setUp(
        voteRows: Bool = true, answer: String = gaveUpAnswer, store: (any ResultsAttemptStore)? = nil
    ) async throws -> (VotesManager, FakeVoteOps) {
        VoteResultsFixture.publish(site, pid)
        vault.submitAnswer = answer
        let ops = FakeVoteOps()
        ops.list = listing(gaveUp())
        ops.detail = detail()
        let m = manager(ops, voteRows: voteRows, store: store)
        try await m.refresh()
        return (m, ops)
    }

    /// The reads of the results' documents since the last clear.
    func resultReads() -> [String] { site.reads.filter { $0.hasPrefix("p/\(pid)/results") || $0.hasPrefix("p/\(pid)/rows") } }
    var rowsReads: Int { site.reads.filter { $0 == "p/\(pid)/rows.json" }.count }
    func advance(_ days: Double) { clock.advance(Int64(days * Double(TestClock.day))) }

    private func parse(_ bytes: [UInt8]) throws -> JsonObject { try StrictJson.parseObject(bytes) }

    // MARK: The daily re-check

    /// A `gave_up` check is run again whenever the app opens, at most once a day per record; with the same results.json,
    /// signature and bundle as the last attempt (which had rows.json, was answered and did not end on the vault's side)
    /// rows.json is not downloaded again and nothing is sent; a change in any of the three downloads and sends again.
    @Test func aGaveUpCheckRunsOnceADayAndDoesNotDownloadUnchangedRows() async throws {
        let (m, _) = try await setUp()
        try await m.syncOnce()
        #expect(vault.submits.count == 1 && rowsReads == 1)
        // The same day: nothing is read for it and nothing is sent.
        site.clearReads()
        advance(0.5)
        try await m.syncOnce()
        #expect(vault.submits.count == 1 && resultReads().isEmpty)
        // The next day: the small documents are read again, rows.json is not, and nothing is sent.
        advance(0.6)
        try await m.syncOnce()
        #expect(vault.submits.count == 1 && rowsReads == 0 && resultReads().count == 3)
        // A fixed signature beside the same results.json is a change: rows.json is fetched and the row sent again.
        site["p/\(pid)/results.json.sig"] = .found([UInt8](repeating: 6, count: 64))
        site.clearReads()
        advance(1.1)
        try await m.syncOnce()
        #expect(vault.submits.count == 2 && rowsReads == 1)
        // And a changed bundle.
        site.put("p/\(pid)/results.json.sigstore.json", #"{"mediaType":"bundle","fixed":true}"#)
        site.clearReads()
        advance(1.1)
        try await m.syncOnce()
        #expect(vault.submits.count == 3 && rowsReads == 1)
    }

    /// The check the vault left for a reason of its own side is sent again with rows.json, whatever the results.
    @Test func aCheckLeftOnTheVaultsSideFetchesRowsAgain() async throws {
        let (m, _) = try await setUp(answer: #"{"proposal_id":"p","check":{"state":"gave_up","reason":"clock"}}"#)
        try await m.syncOnce()
        site.clearReads()
        advance(1.1)
        try await m.syncOnce()
        #expect(vault.submits.count == 2 && rowsReads == 1)
    }

    /// An attempt that sent nothing (or was refused) is never skipped: the next one fetches rows.json again.
    @Test func anAttemptThatWasNotAnsweredIsNotSkipped() async throws {
        let (m, _) = try await setUp()
        vault.submitRefusal = "bad_request"
        try await m.syncOnce()
        #expect(vault.submits.count == 1)
        site.clearReads()
        advance(1.1)
        try await m.syncOnce()
        #expect(vault.submits.count == 2 && rowsReads == 1)
    }

    /// The member's **Check again** is not held by the daily limit, and one that ends unchanged keeps the last attempt's time,
    /// so the daily re-check still runs on schedule (#317 item 3).
    @Test func checkAgainIsNotHeldByTheDailyLimitAndDoesNotDeferTheDailyRecheck() async throws {
        let (m, _) = try await setUp()
        try await m.syncOnce()
        let first = try #require(m.attempts.attempt(key)).atMs
        advance(0.5)
        // Unchanged: nothing sent, the time kept.
        #expect(try await m.checkResults(key) == .unchanged)
        #expect(vault.submits.count == 1 && m.attempts.attempt(key)?.atMs == first)
        // 25 hours after the daily attempt, the daily re-check is due; it stamps its own time.
        advance(0.55)
        #expect(m.attempts.dailyDue(key, at: clock.date))
        try await m.syncOnce()
        #expect(try #require(m.attempts.attempt(key)).atMs > first)
        // Two passes that both found it due do not run it back to back: a second one inside the day is unchanged and unrecorded.
        let at = try #require(m.attempts.attempt(key)).atMs
        site.clearReads()
        try await m.syncOnce()
        #expect(resultReads().isEmpty && m.attempts.attempt(key)?.atMs == at)
    }

    /// The kept attempts hold no choice, row or proof; a restart keeps them (the same store), a lock keeps them, a wipe
    /// forgets them, and a vote that is gone or whose check is final takes its attempt away.
    @Test func theKeptAttemptsSurviveARestartAndALockButNotAWipe() async throws {
        let (m, ops) = try await setUp()
        try await m.syncOnce()
        let kept = try #require(m.attempts.attempt(key))
        #expect(String(describing: kept) == "ResultsAttempt" && kept.answered && kept.sentRow && kept.rowsFetched)
        // A restart: a manager over the same store does not run it again the same day.
        let again = manager(ops)
        try await again.refresh()
        site.clearReads()
        try await again.syncOnce()
        #expect(resultReads().isEmpty)
        // A lock keeps them.
        m.clear()
        #expect(m.attempts.attempt(key) != nil)
        // The vote's check turning final takes its attempt away at the next whole list.
        ops.list = listing(summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"verified"}"#))
        try await m.refresh()
        #expect(m.attempts.attempt(key) == nil)
        // A wipe forgets what is left, and a write racing it (taken before) is dropped.
        let epoch = m.attempts.epoch
        m.forgetStored()
        m.attempts.put(key, ResultsAttempt(key: ResultsAttempts.id(key), atMs: 1), epoch: epoch)
        #expect(m.attempts.attempt(key) == nil && store.load().isEmpty)
    }

    // MARK: The rows the app cannot have

    @Test func withoutTheCapabilityNothingIsSentForARowThatCannotBeHad() async throws {
        let (m, _) = try await setUp(voteRows: false)
        site["p/\(pid)/rows.json"] = nil
        #expect(try await m.checkResults(key) == .notPublished)
        site["p/\(pid)/rows.json"] = .found(Array("{}".utf8))
        #expect(try await m.checkResults(key) == .problem)
        VoteResultsFixture.publish(site, pid)
        site.put("p/\(pid)/results.json", #"{"counts":{"eligible":0}}"#)
        #expect(try await m.checkResults(key) == .problem)
        #expect(vault.submits.isEmpty)
    }

    /// A definite 404 for rows.json beside the signed results is `rows_unavailable` with `vote_rows`; a timeout is retried.
    @Test func aMissingRowsJsonIsRowsUnavailableButAnUnreachableOneIsRetried() async throws {
        let (m, _) = try await setUp()
        site["p/\(pid)/rows.json"] = nil
        #expect(try await m.checkResults(key) == .submitted(.gaveUp))
        let body = try parse(try #require(vault.submits.last))
        #expect(try body.bool("rows_unavailable") == true && !body.has("row") && !body.has("row_proof") && !body.has("other_rows"))
        // Not fetched on the next attempt: rows.json could not be had, so the rows are always fetched again.
        #expect(m.attempts.attempt(key)?.rowsFetched == false)
        site["p/\(pid)/rows.json"] = .unreachable
        site.clearReads()
        advance(1.1)
        #expect(try await m.checkResults(key) == .siteUnreachable)
        #expect(vault.submits.count == 1 && rowsReads == 1)
    }

    /// `counts.eligible` outside 1 to 100,000: `rows_unavailable` without downloading rows.json.
    @Test func anElectorateOutOfRangeIsRowsUnavailableWithoutDownloadingRows() async throws {
        let (m, _) = try await setUp()
        site.put("p/\(pid)/results.json", #"{"counts":{"eligible":100001}}"#)
        site.clearReads()
        #expect(try await m.checkResults(key) == .submitted(.gaveUp))
        #expect(rowsReads == 0)
        #expect(try parse(try #require(vault.submits.last)).bool("rows_unavailable") == true)
        // Eligible that does not read at all is a problem and nothing is sent.
        site.put("p/\(pid)/results.json", #"{"counts":{}}"#)
        #expect(try await m.checkResults(key) == .problem && vault.submits.count == 1)
    }

    /// A rows.json over its cap, or not reaching rows_root, or with no row for the tag: `rows_unavailable`.
    @Test func rowsThatCannotMakeTheMembersRowAreRowsUnavailable() async throws {
        let (m, _) = try await setUp()
        // Over its cap.
        site["p/\(pid)/rows.json"] = .found([UInt8](repeating: 32, count: VoteRows.rowBytes * 2 + VoteRows.rowsOverhead + 1))
        #expect(try await m.checkResults(key) == .submitted(.gaveUp))
        // Not the published tree.
        site.put("p/\(pid)/rows.json", #"{"rows":[]}"#)
        #expect(try await m.checkResults(key) == .submitted(.gaveUp))
        #expect(try vault.submits.allSatisfy { try parse($0).bool("rows_unavailable") == true } && vault.submits.count == 2)
        // The notes say "a problem with the published results" for a vote the vault left `gave_up` with that reason.
        let s = VoteSummary(proposalID: pid, connectionID: conn, state: .closed, check: VoteCheck(state: .gaveUp, reason: "rows_unavailable"))
        #expect(VoteRules.notes(s) == [.closed, .checkResultsProblem])
    }

    /// A second row under the member's tag goes as `other_rows` with its proof to the same root.
    @Test func aSecondRowUnderTheMembersTagGoesAsOtherRows() async throws {
        let (m, _) = try await setUp()
        let all = try StrictJson.parseObject(VoteResultsFixture.rows).array("rows").map { try $0.asObject() }
        let rowsText = #"{"proposal_id":"\#(pid)","rows":[\#(all[0].raw),\#(all[1].raw),\#(all[1].raw)],"v":1}"#
        let leaves = try [VoteResultsFixture.otherTag] + [1, 1].map { _ in try VoteRows.leaf(tag: VoteResultsFixture.tag, ballot: all[1].obj("ballot")) }
        let rows = Array(rowsText.utf8)
        let results = try parse(VoteResultsFixture.results)
        let changed = results.raw
            .replacingOccurrences(of: #""rows_root":"\#(try results.string("rows_root"))""#, with: #""rows_root":"\#(Base64s.encodeStd(VoteMerkle.root(leaves)))""#)
            .replacingOccurrences(of: #""eligible":2"#, with: #""eligible":3"#)
        site["p/\(pid)/results.json"] = .found(Array(changed.utf8))
        site["p/\(pid)/rows.json"] = .found(rows)
        #expect(try await m.checkResults(key) == .submitted(.gaveUp))
        let body = try parse(try #require(vault.submits.last))
        let others = try body.array("other_rows").map { try $0.asObject() }
        #expect(others.count == 1 && !body.has("rows_unavailable"))
        #expect(try body.obj("row_proof").uint("index", min: 0, max: 9) == 1 && others[0].obj("proof").uint("index", min: 0, max: 9) == 2)
        #expect(try others[0].obj("row").obj("ballot").string("pad") == String(repeating: "0", count: 29))
        #expect(try body.obj("row").obj("ballot").string("pad") == String(repeating: "0", count: 29))
        // Without the capability the rows are not sent.
        let (plain, _) = try await setUp(voteRows: false, store: MemoryResultsAttemptStore())
        site["p/\(pid)/results.json"] = .found(Array(changed.utf8))
        site["p/\(pid)/rows.json"] = .found(rows)
        _ = try await plain.checkResults(key)
        #expect(!(try parse(try #require(vault.submits.last)).has("other_rows")))
    }

    // MARK: The download cap

    /// For 7 days from the first re-check rows.json goes by the daily rule on any network; after them on an unmetered
    /// network whenever the daily rule allows, and on a metered or unknown one at most weekly (owner decision a).
    @Test func afterSevenDaysRowsDownloadOnWifiAndAtMostWeeklyOnMobileData() async throws {
        let (m, _) = try await setUp()
        network.unmetered = false
        try await m.syncOnce() // day 0: the first re-check, rows downloaded
        func change(_ n: UInt8) { site["p/\(pid)/results.json.sig"] = .found([UInt8](repeating: n, count: 64)) }
        // Day 3, metered, results changed: within the 7 days, the daily rule alone.
        change(10)
        advance(3)
        site.clearReads()
        try await m.syncOnce()
        #expect(rowsReads == 1 && vault.submits.count == 2)
        // Day 8, metered: 5 days since the last rows download, so the weekly cap holds it back; nothing is sent.
        change(11)
        advance(5)
        site.clearReads()
        try await m.syncOnce()
        #expect(rowsReads == 0 && resultReads().count == 3 && vault.submits.count == 2)
        // Day 9, unmetered: downloaded at once.
        network.unmetered = true
        change(12)
        advance(1.1)
        site.clearReads()
        try await m.syncOnce()
        #expect(rowsReads == 1 && vault.submits.count == 3)
        // Day 10, an unknown network counts as metered.
        network.unmetered = nil
        change(13)
        advance(1.1)
        site.clearReads()
        try await m.syncOnce()
        #expect(rowsReads == 0 && vault.submits.count == 3)
        // A week after the last download: allowed again, on any network.
        network.unmetered = false
        advance(6)
        site.clearReads()
        try await m.syncOnce()
        #expect(rowsReads == 1 && vault.submits.count == 4)
    }

    /// A held-back download shows nothing new, keeps what the last attempt knew, and the member's Check again follows the
    /// same cap without deferring the daily re-check (#317 items 1 and 3).
    @Test func aDeferredDownloadSendsNothingAndCheckAgainDoesNotDeferTheDailyRecheck() async throws {
        let (m, _) = try await setUp()
        network.unmetered = false
        try await m.syncOnce()
        advance(7.5)
        site["p/\(pid)/results.json.sig"] = .found([UInt8](repeating: 10, count: 64))
        try await m.syncOnce() // the weekly download: allowed (7.5 days since the last)
        #expect(vault.submits.count == 2)
        site["p/\(pid)/results.json.sig"] = .found([UInt8](repeating: 11, count: 64))
        advance(1.1)
        let stamped = try #require(m.attempts.attempt(key)).atMs
        // The daily run is held back and stamps its time.
        try await m.syncOnce()
        let daily = try #require(m.attempts.attempt(key)).atMs
        #expect(daily > stamped && vault.submits.count == 2)
        // Check again, deferred: no new text (an outcome of its own), the time kept.
        advance(0.3)
        #expect(try await m.checkResults(key) == .deferred)
        #expect(m.attempts.attempt(key)?.atMs == daily && m.attempts.attempt(key)?.answered == true)
        #expect(vault.submits.count == 2)
    }

    @Test func theNetworkRuleCountsExpensiveConstrainedAndUnknownPathsAsMetered() {
        #expect(PathNetworkMeter.unmetered(satisfied: true, expensive: false, constrained: false) == true)
        #expect(PathNetworkMeter.unmetered(satisfied: true, expensive: true, constrained: false) == false)
        #expect(PathNetworkMeter.unmetered(satisfied: true, expensive: false, constrained: true) == false)
        #expect(PathNetworkMeter.unmetered(satisfied: false, expensive: false, constrained: false) == nil)
        #expect(UnknownNetworkMeter().unmetered() == nil)
    }
}

// swiftlint:enable line_length
