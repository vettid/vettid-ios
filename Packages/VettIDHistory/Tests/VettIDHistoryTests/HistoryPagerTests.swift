import Foundation
import Testing
import VettIDCrypto
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// Cursor paging, `partial`, the filter sent, an older vault's search and the chain check (VAULT-MESSAGING 0.20.0 §10.9),
/// through the real ``HistoryManager`` over ``FakeAuditLog``. Mirrors vettid-android `HistoryPagerTest`.
@MainActor
@Suite struct HistoryPagerTests {
    /// 2026-10-07T12:00:00Z, the newest entry.
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_791_374_400)

    let text: @MainActor (AuditRecord) -> [String] = { AuditFilter.kindText($0.kind) }

    func pager(_ log: FakeAuditLog, minPerLoad: Int = HistoryPager.minPerLoad, maxPages: Int = HistoryPager.maxPagesPerLoad) -> (HistoryPager, HistoryManager) {
        let repo = HistoryManager { log }
        return (HistoryPager(repo: repo, localText: text, minPerLoad: minPerLoad, maxPagesPerLoad: maxPages), repo)
    }

    @Test func pagesOf50NewestFirstWithTheCursor() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(120, newest: Self.t0))
        let (p, _) = pager(log, minPerLoad: 1)
        let first = try await p.reset(AuditFilter())
        #expect(log.calls.count == 1 && log.calls[0].limit == 50 && log.calls[0].beforeSeq == nil)
        #expect(first.entries.count == 50 && first.entries.first?.seq == 120 && !first.end)
        _ = try await p.more()
        #expect(log.calls.last?.beforeSeq == 71)
        let third = try await p.more()
        #expect(third.entries.count == 120 && third.end)
        // Nothing more is asked once a page has no cursor.
        _ = try await p.more()
        #expect(log.calls.count == 3)
        #expect(third.entries.map(\.seq) == Array((1...120).reversed()))
        #expect(!third.chainBroken)
    }

    @Test func theCategoryConnectionAndDatesAreSent() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(10, kinds: ["vault.unlocked", "message.sent"], newest: Self.t0, connection: "c1"))
        let (p, _) = pager(log)
        let since = Self.t0.addingTimeInterval(-300)
        let s = try await p.reset(AuditFilter(category: .vaultAccess, connectionID: "c1", since: since, until: Self.t0))
        let call = try #require(log.calls.first)
        #expect(log.calls.count == 1 && call.kinds == ["vault", "owner_check"] && call.connectionID == "c1")
        #expect(call.since == "2026-10-07T11:55:00.000Z" && call.until == "2026-10-07T12:00:00.000Z")
        #expect(!s.entries.isEmpty && s.entries.allSatisfy { $0.kind == "vault.unlocked" && $0.entry.connectionID == "c1" && $0.at! < Self.t0 && $0.at! >= since })
    }

    @Test func aPartialSearchGoesOnWithTheCursor() async throws {
        // One match in ten; the vault evaluates 30 entries per request.
        let kinds = Array(repeating: "vault.unlocked", count: 9) + ["credential.password_changed"]
        let log = FakeAuditLog(FakeAuditLog.chain(400, kinds: kinds, newest: Self.t0))
        log.budget = 30
        let (p, _) = pager(log, minPerLoad: 10, maxPages: 8)
        let s = try await p.reset(AuditFilter(query: "password changed"))
        #expect(log.calls.first?.q == "password changed")
        // 3 matches per partial page: 4 pages for 10.
        #expect(log.calls.map(\.beforeSeq) == [nil, 371, 341, 311])
        #expect(s.entries.count == 12 && s.partial && !s.localSearch && !s.end)
        #expect(s.entries.allSatisfy { $0.kind == "credential.password_changed" })
    }

    @Test func aRefusedSearchIsSentAgainWithoutItAndRunsHere() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(50, kinds: ["vault.unlocked", "message.sent"], newest: Self.t0), mode: .refuses)
        let (p, repo) = pager(log)
        let s = try await p.reset(AuditFilter(query: "message"))
        #expect(log.calls[0].q == "message" && log.calls[1].q == nil)
        #expect(repo.searchUnsupported && s.localSearch)
        #expect(s.entries.count == 25 && s.entries.allSatisfy { $0.kind == "message.sent" })
        // The session stops sending it.
        _ = try await p.reset(AuditFilter(query: "vault"))
        #expect(log.calls.last?.q == nil)
    }

    @Test func anIgnoredSearchIsNoticedAndRunsHere() async throws {
        // A vault before 0.20.0 ignores q, since and until: the answer is unfiltered.
        let log = FakeAuditLog(FakeAuditLog.chain(50, kinds: ["vault.unlocked", "message.sent"], newest: Self.t0), mode: .ignores)
        let (p, repo) = pager(log)
        let since = Self.t0.addingTimeInterval(-19 * 60)
        let s = try await p.reset(AuditFilter(query: "vault unlocked", since: since))
        #expect(log.calls[0].q == "vault unlocked" && repo.searchUnsupported && s.localSearch)
        // The 20 newest minutes, vault.unlocked only (every other entry).
        #expect(s.entries.count == 10 && s.entries.allSatisfy { $0.kind == "vault.unlocked" && $0.at! >= since })
    }

    @Test func aVaultSearchIsTrusted() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(50, kinds: ["vault.unlocked", "message.sent"], newest: Self.t0))
        let (p, _) = pager(log)
        let s = try await p.reset(AuditFilter(query: "MESSAGE"))
        #expect(!s.localSearch && s.entries.count == 25)
    }

    @Test func aBrokenChainIsReportedOnlyUnfiltered() async throws {
        var entries = FakeAuditLog.chain(10, newest: Self.t0)
        entries[4].kind = "vault.locked"
        let log = FakeAuditLog(entries)
        let (p, _) = pager(log)
        #expect(try await p.reset(AuditFilter()).chainBroken)
        #expect(try await !p.reset(AuditFilter(category: .vaultAccess)).chainBroken)
    }

    @Test func theDetailFindsAnEntryReadBefore() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(5, newest: Self.t0))
        let (p, repo) = pager(log)
        _ = try await p.reset(AuditFilter())
        #expect(repo.cached(3)?.entry.entryID == "e3")
        repo.clear()
        #expect(repo.cached(3) == nil)
    }

    @Test func aRefreshPutsWhatArrivedSinceOnTopAndKeepsTheRest() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(120, newest: Self.t0))
        let (p, _) = pager(log, minPerLoad: 1)
        _ = try await p.reset(AuditFilter())
        _ = try await p.more()
        // An export: the vault records `audit.exported` (and nothing else changed).
        log.append("audit.exported")
        let s = try await p.refresh()
        #expect(log.calls.last?.beforeSeq == nil)
        #expect(s.entries.first?.seq == 121 && s.entries.first?.kind == "audit.exported")
        #expect(s.entries.map(\.seq) == Array((21...121).reversed()) && !s.chainBroken)
        // The cursor is where it was: the next page goes on from 21.
        _ = try await p.more()
        #expect(log.calls.last?.beforeSeq == 21)
        // Nothing new: the list stays as it is.
        let before = p.snapshot.entries
        #expect(try await p.refresh().entries == before)
    }

    @Test func aRefreshUnderAFilterAddsOnlyWhatMatches() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(10, newest: Self.t0))
        let (p, _) = pager(log)
        _ = try await p.reset(AuditFilter(category: .vaultAccess))
        log.append("audit.exported")
        log.append("vault.unlocked")
        #expect(try await p.refresh().entries.map(\.seq) == [12] + Array((1...10).reversed()))
        let (sec, _) = pager(log)
        _ = try await sec.reset(AuditFilter(category: .security))
        log.append("audit.exported")
        #expect(try await sec.refresh().entries.map(\.seq) == [13, 11])
    }

    @Test func moreThanAPageArrivedStartsOver() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(60, newest: Self.t0))
        let (p, _) = pager(log)
        _ = try await p.reset(AuditFilter())
        for _ in 0..<55 { log.append("vault.unlocked") }
        let s = try await p.refresh()
        // The newest page's cursor (66) is above the newest shown (60): a reset, newest first and contiguous.
        #expect(s.entries.first?.seq == 115)
        #expect(s.entries.map(\.seq) == Array(((115 - Int64(s.entries.count) + 1)...115).reversed()) && !s.chainBroken)
    }
}

// swiftlint:enable line_length
