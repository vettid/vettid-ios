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

/// The recheck on open's download limits (VAULT-MESSAGING §10.19.6; vettid-android #319 item 2 and #321): on a metered or
/// unknown network `rows.json` at most daily per vote until a week after the vote's close (as extended), then weekly;
/// Wi-Fi never capped; the time kept in the encrypted stamps file, across a lock and a restart. Mirrors the
/// `VotesManagerTest` cases of vettid-android #321.
@MainActor
struct VoteRecheckLimitsTests: VotesTestCase {
    let clock = TestClock(1_793_534_400_000)
    let site = FakeVoteSite()
    let vault = FakeVoteSiteOps()
    let network = TestNetwork(false)
    let ops = FakeVoteOps()

    private let checked = RecheckOutcome.consistent
    private let held = RecheckOutcome.notChecked

    func manager(rechecks: any RecheckStampStore = MemoryRecheckStampStore(), attempts: any ResultsAttemptStore = MemoryResultsAttemptStore()) -> VotesManager {
        let c = clock
        let vault = vault
        let network = network
        return VotesManager(
            ops: { ops }, now: { c.date }, site: site, siteOps: { _ in vault }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            voteRows: { true }, attempts: attempts, rechecks: rechecks, unmetered: { network.unmetered }
        )
    }

    /// A verified vote that closes at [closes] (the phone's clock), or has no `closes_at` when nil.
    func verifiedVote(closes: Date?) -> String {
        let v = summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"verified"}"#)
        let was = #""closes_at":"2026-11-06T17:00:00.000Z""#
        guard let closes else { return v.replacingOccurrences(of: "," + was, with: "") }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return v.replacingOccurrences(of: was, with: #""closes_at":"\#(f.string(from: closes))""#)
    }

    func detail() -> JsonObject {
        voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","title":"Adopt the budget","state":"closed","text":"t","choices":[{"id":"yes","label":"Yes"}],"record_tag":"\#(Base64s.encodeStd(VoteResultsFixture.tag))","extensions":0,"tally":{"abstain":0,"no":0,"yes":1},"counts":{"ballots":1,"eligible":2,"removed":0,"unhandled":0}}"#)
    }

    /// A manager over a list of one verified vote closing at [closes], the results published.
    func opened(closes: Date?, rechecks: any RecheckStampStore = MemoryRecheckStampStore()) async throws -> VotesManager {
        VoteResultsFixture.publish(site, pid)
        ops.list = listing(verifiedVote(closes: closes))
        ops.detail = detail()
        let m = manager(rechecks: rechecks)
        try await m.refresh()
        return m
    }

    /// An open after a lock: the verdict forgotten, the recheck runs again.
    func reopen(_ m: VotesManager) async throws -> RecheckOutcome {
        m.clear()
        try await m.refresh()
        return try await m.recheckResults(key)
    }

    var rowsReads: Int { site.reads.filter { $0 == "p/\(pid)/rows.json" }.count }
    func at(_ d: TimeInterval) -> Date { clock.date.addingTimeInterval(d) }
    static let day: TimeInterval = 86_400
    static let ms: TimeInterval = 0.001

    // MARK: The recheck on open

    /// The verdict is memory only, so every open after a lock rechecks; on mobile data rows.json is downloaded at most weekly
    /// once the vote has been closed a week; nothing is submitted; a wipe forgets the time.
    @Test func theRecheckOnOpenDownloadsRowsAtMostWeeklyOnMobileDataLongAfterTheClose() async throws {
        let m = try await opened(closes: at(-30 * Self.day))
        let day0 = clock.nowMs
        #expect(try await m.recheckResults(key) == checked && rowsReads == 1)
        // A lock, then the next open on mobile data the same week: not rechecked, no download.
        clock.nowMs = day0 + 3 * TestClock.day
        #expect(try await reopen(m) == held && rowsReads == 1)
        // On Wi-Fi it downloads; and on an unknown network a week after the last download.
        network.unmetered = true
        #expect(try await reopen(m) == checked && rowsReads == 2)
        network.unmetered = nil
        clock.nowMs = day0 + 10 * TestClock.day
        #expect(try await reopen(m) == checked && rowsReads == 3)
        #expect(vault.submits.isEmpty)
        // A wipe forgets it.
        m.clear()
        m.forgetStored()
        try await m.refresh()
        network.unmetered = false
        #expect(try await m.recheckResults(key) == checked && rowsReads == 4)
    }

    /// Daily for 7 days after the close, then weekly; each edge at 1 ms before and exactly on it.
    @Test func theRecheckOnMeteredDataIsDailyForSevenDaysAfterTheCloseThenWeekly() async throws {
        let closes = clock.date
        let day0 = clock.nowMs
        let m = try await opened(closes: closes)
        #expect(try await m.recheckResults(key) == checked)
        clock.nowMs = day0 + 3_600_000
        #expect(try await reopen(m) == held) // the same day
        clock.nowMs = day0 + TestClock.day - 1
        #expect(try await reopen(m) == held)
        clock.nowMs = day0 + TestClock.day
        #expect(try await reopen(m) == checked && rowsReads == 2) // 24 h later
        // At the close plus 7 days, the last download on day 5: 1 ms before it the daily rule (downloads), exactly at it the weekly (held).
        for (boundary, expected) in [(7 * TestClock.day - 1, checked), (7 * TestClock.day, held)] {
            let stamps = MemoryRecheckStampStore()
            stamps.save([RecheckStamp(key: ResultsAttempts.id(key), atMs: day0 + 5 * TestClock.day)])
            let other = try await opened(closes: closes, rechecks: stamps)
            clock.nowMs = day0 + boundary
            #expect(try await reopen(other) == expected)
        }
        // Then weekly: the last download at the close plus 8 days; 1 ms before 7 days since held, exactly at them it downloads.
        let stamps = MemoryRecheckStampStore()
        stamps.save([RecheckStamp(key: ResultsAttempts.id(key), atMs: day0 + 8 * TestClock.day)])
        let weekly = try await opened(closes: closes, rechecks: stamps)
        clock.nowMs = day0 + 15 * TestClock.day - 1
        #expect(try await reopen(weekly) == held)
        clock.nowMs = day0 + 15 * TestClock.day
        #expect(try await reopen(weekly) == checked)
    }

    /// The weekly cap at its edge: 1 ms before 7 days held, at 7 days it downloads.
    @Test func theRecheckWeeklyCapAtItsBoundary() async throws {
        let m = try await opened(closes: at(-30 * Self.day))
        let day0 = clock.nowMs
        #expect(try await m.recheckResults(key) == checked)
        clock.nowMs = day0 + 7 * TestClock.day - 1
        #expect(try await reopen(m) == held && rowsReads == 1)
        clock.nowMs = day0 + 7 * TestClock.day
        #expect(try await reopen(m) == checked && rowsReads == 2)
    }

    @Test func theRecheckOnWifiIsNeverCappedInEitherPeriod() async throws {
        network.unmetered = true
        let m = try await opened(closes: clock.date)
        #expect(try await m.recheckResults(key) == checked)
        #expect(try await reopen(m) == checked)
        clock.advance(9 * TestClock.day)
        #expect(try await reopen(m) == checked)
        #expect(try await reopen(m) == checked)
        #expect(rowsReads == 4)
    }

    @Test func aVoteWithNoCloseKnownUsesTheWeeklyRule() async throws {
        let m = try await opened(closes: nil)
        let day0 = clock.nowMs
        #expect(try await m.recheckResults(key) == checked)
        clock.nowMs = day0 + TestClock.day
        #expect(try await reopen(m) == held)
        clock.nowMs = day0 + 7 * TestClock.day
        #expect(try await reopen(m) == checked && rowsReads == 2)
    }

    // MARK: What the time is kept in

    /// A new manager over the same file (a cold start) keeps the cap; a vote no longer listed and a wipe drop it; the file holds
    /// a key and a time and nothing else.
    @Test func theCapSurvivesARestartAndGoesWithTheVoteOrAWipe() async throws {
        let stamps = MemoryRecheckStampStore()
        let first = try await opened(closes: at(-30 * Self.day), rechecks: stamps)
        #expect(try await first.recheckResults(key) == checked)
        #expect(stamps.load()?.map(\.key) == [ResultsAttempts.id(key)] && stamps.load()?.first.map { String(describing: $0) } == "RecheckStamp")
        clock.advance(TestClock.day)
        let restarted = manager(rechecks: stamps)
        try await restarted.refresh()
        #expect(try await restarted.recheckResults(key) == held && rowsReads == 1)
        // Pruned with the list.
        ops.list = listing()
        try await restarted.refresh()
        #expect(stamps.load()?.isEmpty == true)
        // Wiped.
        ops.list = listing(verifiedVote(closes: at(-30 * Self.day)))
        restarted.clear()
        try await restarted.refresh()
        _ = try await restarted.recheckResults(key)
        #expect(stamps.load()?.count == 1)
        restarted.clear()
        restarted.forgetStored()
        #expect(stamps.load()?.isEmpty == true)
    }

    /// Stamps that cannot be read now (protected data away) are not read as "never": on a metered network the download waits,
    /// on Wi-Fi it does not; nothing is written over the file.
    @Test func stampsThatCannotBeReadHoldTheDownloadOnMeteredDataOnly() async throws {
        final class Away: RecheckStampStore, @unchecked Sendable {
            private let lock = NSLock()
            var saved = 0
            func load() -> [RecheckStamp]? { nil }
            func save(_ stamps: [RecheckStamp]) { lock.withLock { saved += 1 } }
        }
        let away = Away()
        let m = try await opened(closes: at(-30 * Self.day), rechecks: away)
        #expect(try await m.recheckResults(key) == held && rowsReads == 0)
        network.unmetered = true
        #expect(try await reopen(m) == checked)
        #expect(away.saved == 0)
    }

    /// A chunk of the download arriving after a wipe puts nothing back: the next recheck on mobile data is not held.
    @Test func aRowsChunkArrivingAfterAWipeStampsNothing() async throws {
        let m = try await opened(closes: at(-30 * Self.day))
        site.beforeReceived = { await m.forgetStored() }
        _ = try await m.recheckResults(key)
        site.beforeReceived = nil
        #expect(try await reopen(m) == checked && rowsReads == 2)
    }

    /// A lock while the bytes arrive (the recheck's job is cancelled): they were spent, so the cap counts them.
    @Test func aLockDuringTheRechecksDownloadStillCountsTheBytes() async throws {
        let m = try await opened(closes: at(-30 * Self.day))
        site.beforeReceived = { await m.clear() }
        _ = try? await m.recheckResults(key)
        site.beforeReceived = nil
        try await m.refresh()
        #expect(try await m.recheckResults(key) == held && rowsReads == 1)
    }

    /// A download in many chunks writes its stamp once, not at every chunk.
    @Test func theStampIsWrittenOncePerDownload() async throws {
        final class Counting: RecheckStampStore, @unchecked Sendable {
            private let lock = NSLock()
            private var inner: [RecheckStamp] = []
            private(set) var saves = 0
            func load() -> [RecheckStamp]? { lock.withLock { inner } }
            func save(_ stamps: [RecheckStamp]) { lock.withLock { saves += 1; inner = stamps } }
        }
        let counting = Counting()
        site.chunks = 50
        let m = try await opened(closes: at(-30 * Self.day), rechecks: counting)
        #expect(try await m.recheckResults(key) == checked)
        #expect(counting.saves == 1)
    }

    /// The member's Check again downloads rows.json on any network, and that download counts for the recheck's cap: an open
    /// right after, on mobile data, is held (the two paths do not add up).
    @Test func aCheckAgainDownloadCountsForTheRecheckOnOpen() async throws {
        let m = try await opened(closes: at(-30 * Self.day))
        vault.submitAnswer = #"{"proposal_id":"p","check":{"state":"verified"}}"#
        #expect(try await m.checkResults(key) == .submitted(.verified))
        #expect(rowsReads == 1)
        #expect(try await reopen(m) == held && rowsReads == 1)
    }
}

// swiftlint:enable line_length
