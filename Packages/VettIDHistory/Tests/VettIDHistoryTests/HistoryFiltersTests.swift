import Foundation
import Testing
import VettIDData
@testable import VettIDHistory
import VettIDVault

/// The filter the History screen builds (ANDROID-PLAN §4 History): one category at a time, the date presets from local
/// midnight, a custom range of whole days with `until` exclusive. (`q`'s own rules are VettIDData's `HistoryTests`.)
/// Mirrors vettid-android `HistoryFiltersTest`.
@Suite struct HistoryFiltersTests {
    static let newYork: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// 11:30 in New York.
    let now = Date(timeIntervalSince1970: 1_791_387_000) // 2026-10-07T15:30:00Z

    static func instant(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func oneCategoryAtATime() {
        let f = HistoryFilters.category(AuditFilter(), .devices)
        #expect(f.category == .devices && f.kinds == ["device", "approval"])
        #expect(HistoryFilters.category(f, .security).category == .security)
        // The selected one again, or All, clears it.
        #expect(HistoryFilters.category(f, .devices).category == nil)
        #expect(HistoryFilters.category(f, nil).kinds == nil)
        // §10.9: 1–16 prefixes per request.
        #expect(AuditCategory.filters.allSatisfy { (1...16).contains($0.prefixes.count) })
    }

    @Test func presetsStartAtLocalMidnight() {
        #expect(Self.instant("2026-10-07T15:30:00Z") == now)
        let today = HistoryFilters.dates(AuditFilter(), .today, now: now, calendar: Self.newYork)
        #expect(today.since == Self.instant("2026-10-07T04:00:00Z") && today.until == nil)
        let week = HistoryFilters.dates(AuditFilter(), .week, now: now, calendar: Self.newYork)
        #expect(week.since == Self.instant("2026-10-01T04:00:00Z"))
        let month = HistoryFilters.dates(AuditFilter(), .month, now: now, calendar: Self.newYork)
        #expect(month.since == Self.instant("2026-09-08T04:00:00Z"))
        let any = HistoryFilters.dates(week, .any, now: now, calendar: Self.newYork)
        #expect(any.since == nil && any.until == nil)
    }

    @Test func aCustomRangeIsWholeDaysUntilExclusive() {
        let first = Self.instant("2026-10-02T12:00:00Z")
        let last = Self.instant("2026-10-04T12:00:00Z")
        let (since, until) = HistoryFilters.days(first, last, calendar: Self.newYork)
        #expect(since == Self.instant("2026-10-02T04:00:00Z") && until == Self.instant("2026-10-05T04:00:00Z"))
        // Picked backwards: the same range.
        let back = HistoryFilters.days(last, first, calendar: Self.newYork)
        #expect(back.since == since && back.until == until)
        let f = HistoryFilters.dates(AuditFilter(), .custom, now: now, calendar: Self.newYork, since: since, until: until)
        func r(_ at: String) -> AuditRecord { AuditRecord(AuditEntry(entryID: "e", seq: 1, at: at, kind: "vault.unlocked")) }
        #expect(f.acceptsExceptSearch(r("2026-10-02T04:00:00.000Z")))
        #expect(f.acceptsExceptSearch(r("2026-10-05T03:59:59.999Z")))
        #expect(!f.acceptsExceptSearch(r("2026-10-05T04:00:00.000Z")))
        #expect(!f.acceptsExceptSearch(r("2026-10-02T03:59:59.000Z")))
    }

    @Test func theConnectionsAreOfferedByName() {
        var s = HistoryState()
        s.connectionNames = ["c2": "bea", "c1": "Ada", "c3": "Cy"]
        #expect(s.connections.map(\.id) == ["c1", "c2", "c3"])
        #expect(HistoryState().emptyHistory)
        s.filter = AuditFilter(connectionID: "c1")
        #expect(!s.emptyHistory)
    }
}
