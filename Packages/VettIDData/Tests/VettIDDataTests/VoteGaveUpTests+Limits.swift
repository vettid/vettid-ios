import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

private let pid = VoteFixture.pid
private let key = VoteFixture.key

/// The follow-ups to the download cap (VAULT-MESSAGING §10.19.6; vettid-android #319 items 1, 3 and 4, #321): partial
/// downloads count, the 7 days follow the check's state, and the edges of the cap.
extension VoteGaveUpTests {
    func pendingCheck() -> String {
        summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"pending"}"#)
    }

    func changeSig(_ n: UInt8) { site["p/\(pid)/results.json.sig"] = .found([UInt8](repeating: n, count: 64)) }

    /// A store holding one record: first re-check at [first], the last rows download at [rows], the last attempt at [at].
    func storeWith(first: Int64, rows: Int64?, at: Int64) -> MemoryResultsAttemptStore {
        let s = MemoryResultsAttemptStore()
        s.save([ResultsAttempt(key: ResultsAttempts.id(key), atMs: at, firstRecheckMs: first, lastRowsMs: rows)])
        return s
    }

    /// Whether the daily re-check on a metered network at [now] downloaded rows.json, over a store with that one record.
    func downloads(_ store: MemoryResultsAttemptStore, at now: Int64) async throws -> Bool {
        network.unmetered = false
        let (m, _) = try await setUp(store: store)
        clock.nowMs = now
        site.clearReads()
        try await m.syncOnce()
        return rowsReads == 1
    }

    // MARK: Item 1: partial downloads

    /// A rows download that drops after some bytes counts toward the weekly cap: on metered data the next day it is deferred,
    /// not retried. A drop before any byte arrived does not count.
    @Test func aRowsDownloadCutOffPartwayCountsTowardTheWeeklyCap() async throws {
        let (m, _) = try await setUp()
        network.unmetered = false
        let day0 = clock.nowMs
        try await m.syncOnce()
        let rows = try #require(site["p/\(pid)/rows.json"])
        changeSig(10)
        site["p/\(pid)/rows.json"] = .unreachable
        site.partial["p/\(pid)/rows.json"] = 1_000_000
        clock.nowMs = day0 + 8 * TestClock.day
        try await m.syncOnce()
        #expect(m.attempts.attempt(key)?.lastRowsMs == clock.nowMs)
        // The next day, the rows back: held by the weekly cap, nothing more downloaded, nothing sent.
        site["p/\(pid)/rows.json"] = rows
        site.partial = [:]
        clock.nowMs = day0 + 9 * TestClock.day
        site.clearReads()
        try await m.syncOnce()
        #expect(rowsReads == 0 && vault.submits.count == 1)
    }

    @Test func aRowsDownloadThatDropsBeforeAnyByteDoesNotCount() async throws {
        let (m, _) = try await setUp()
        network.unmetered = false
        let day0 = clock.nowMs
        try await m.syncOnce()
        changeSig(10)
        site["p/\(pid)/rows.json"] = .unreachable
        clock.nowMs = day0 + 8 * TestClock.day
        try await m.syncOnce()
        #expect(m.attempts.attempt(key)?.lastRowsMs == day0)
    }

    /// A 404 reads no body: nothing is counted.
    @Test func aMissingRowsJsonCountsNothing() async throws {
        let (m, _) = try await setUp()
        network.unmetered = false
        let day0 = clock.nowMs
        try await m.syncOnce()
        changeSig(10)
        site["p/\(pid)/rows.json"] = nil
        clock.nowMs = day0 + 8 * TestClock.day
        try await m.syncOnce()
        #expect(m.attempts.attempt(key)?.lastRowsMs == day0)
    }

    // MARK: Item 3: the 7 days follow the state

    /// gave_up (first re-check day 0), pending on day 5, gave_up again on day 6: the 7 days run from day 6, so day 10 on
    /// mobile data (the last download day 6) still downloads.
    @Test func theSevenDaysStartAgainWhenTheCheckIsPendingAgain() async throws {
        let (m, ops) = try await setUp()
        network.unmetered = false
        let day0 = clock.nowMs
        try await m.syncOnce()
        #expect(m.attempts.attempt(key)?.firstRecheckMs == day0)
        ops.list = listing(pendingCheck())
        try await m.refresh()
        clock.nowMs = day0 + 5 * TestClock.day
        _ = try await m.checkResults(key)
        #expect(m.attempts.attempt(key)?.firstRecheckMs == nil)
        ops.list = listing(gaveUp())
        try await m.refresh()
        clock.nowMs = day0 + 6 * TestClock.day
        changeSig(11)
        try await m.syncOnce()
        #expect(m.attempts.attempt(key)?.firstRecheckMs == clock.nowMs)
        clock.nowMs = day0 + 10 * TestClock.day
        changeSig(12)
        site.clearReads()
        try await m.syncOnce()
        #expect(rowsReads == 1)
    }

    // MARK: Item 4: the edges of the cap

    @Test func theSevenDayWindowAndTheWeeklyCapAtTheirBoundaries() async throws {
        let day0 = clock.nowMs
        let day = TestClock.day
        // The window: the last download on day 3; 1 ms before day 7 the daily rule alone (downloads), at day 7 the cap.
        #expect(try await downloads(storeWith(first: day0, rows: day0 + 3 * day, at: day0 + 3 * day), at: day0 + 7 * day - 1))
        #expect(try await !downloads(storeWith(first: day0, rows: day0 + 3 * day, at: day0 + 3 * day), at: day0 + 7 * day))
        // The cap: the last download on day 3; 1 ms before day 10 held, at day 10 it downloads.
        #expect(try await !downloads(storeWith(first: day0, rows: day0 + 3 * day, at: day0 + 8 * day), at: day0 + 10 * day - 1))
        #expect(try await downloads(storeWith(first: day0, rows: day0 + 3 * day, at: day0 + 8 * day), at: day0 + 10 * day))
    }

    /// No rows download yet: after the 7 days it downloads.
    @Test func noRowsDownloadYetAfterTheSevenDaysDownloads() async throws {
        let day0 = clock.nowMs
        #expect(try await downloads(storeWith(first: day0, rows: nil, at: day0 + 6 * TestClock.day), at: day0 + 8 * TestClock.day))
    }

    /// A deferred attempt keeps the last record's hashes (only its time moves), and there is no site read the same day after it.
    @Test func aDeferredAttemptKeepsTheLastHashesAndReadsNothingMoreThatDay() async throws {
        let (m, _) = try await setUp()
        network.unmetered = false
        let day0 = clock.nowMs
        try await m.syncOnce()
        changeSig(10)
        clock.nowMs = day0 + 3 * TestClock.day
        try await m.syncOnce() // within the 7 days: downloaded
        let before = try #require(m.attempts.attempt(key))
        // Day 8: a changed bundle on the site, the download held by the cap: the record keeps the last hashes, so the change is
        // still seen as one when the rows can be had; only its time moves.
        site.put("p/\(pid)/results.json.sigstore.json", #"{"mediaType":"z"}"#)
        clock.nowMs = day0 + 8 * TestClock.day
        site.clearReads()
        try await m.syncOnce()
        var expected = before
        expected.atMs = clock.nowMs
        #expect(m.attempts.attempt(key) == expected && rowsReads == 0)
        // The same day: no read of the results at all.
        site.clearReads()
        clock.advance(5 * 3_600_000)
        try await m.syncOnce()
        #expect(resultReads().isEmpty)
    }

    /// A results check's rows download also stamps the recheck on open's cap (the two paths do not add up).
    @Test func aResultsChecksRowsDownloadStampsTheRecheckCap() async throws {
        let (m, _) = try await setUp()
        try await m.syncOnce()
        #expect(m.attempts.rechecks.waits(ResultsAttempts.id(key), at: clock.nowMs, closesAt: nil, unmetered: false))
        #expect(!m.attempts.rechecks.waits(ResultsAttempts.id(key), at: clock.nowMs, closesAt: nil, unmetered: true))
    }
}
