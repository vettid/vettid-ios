import Foundation
import VettIDData

/// The audit log in pages, newest first (VAULT-MESSAGING 0.20.0 §10.9, ANDROID-PLAN §4 History): `limit` 50 and
/// `before_seq` = the previous page's `next_before_seq`; a page without it is the end. A `partial` page (a search that ran
/// out of its scan budget) may hold few or no entries: loading goes on with the cursor until [minPerLoad] new entries
/// arrived (or [maxPagesPerLoad] pages were read; the next load continues).
///
/// The vault filters (`kinds`, `connection_id`, `q`, `since`, `until`). A vault before 0.20.0 refuses or ignores the
/// search: then this phone filters what it loads, the category, connection and dates exactly, and `q` over what it knows
/// ([localText]: the kind, the title and the connection's names); ``Snapshot/localSearch`` says so. A vault that answered
/// `q` is trusted with it (it also matches device and item names the app may not hold), unless an entry it returned could
/// not match at all, which shows it ignored `q`.
///
/// Unfiltered lists are chain-checked (``AuditChain``); filtered and searched ones are not. One load at a time (the view
/// model serialises them). Mirrors vettid-android `HistoryPager`.
@MainActor
final class HistoryPager {
    static let minPerLoad = 20
    static let maxPagesPerLoad = 8

    /// What has been read: [entries] newest first; [end] once the results' end is reached.
    struct Snapshot: Equatable {
        var filter = AuditFilter()
        var entries: [AuditRecord] = []
        var end = false
        /// The search runs on this phone over the loaded entries (the vault does not search yet).
        var localSearch = false
        /// The last page was `partial`: the vault is still searching older entries.
        var partial = false
        /// An unfiltered list whose entries do not chain (§10.9: report it as tampered).
        var chainBroken = false
    }

    private let repo: any HistoryRepository
    private let localText: @MainActor (AuditRecord) -> [String]
    private let pageSize: Int
    private let minPerLoad: Int
    private let maxPagesPerLoad: Int
    private(set) var snapshot = Snapshot()
    private var cursor: Int64?

    init(
        repo: any HistoryRepository, localText: @escaping @MainActor (AuditRecord) -> [String], pageSize: Int = AuditRequest.defaultLimit,
        minPerLoad: Int = HistoryPager.minPerLoad, maxPagesPerLoad: Int = HistoryPager.maxPagesPerLoad
    ) {
        self.repo = repo
        self.localText = localText
        self.pageSize = pageSize
        self.minPerLoad = minPerLoad
        self.maxPagesPerLoad = maxPagesPerLoad
    }

    /// The request for the page before [beforeSeq] (nil: the newest) under [filter].
    func request(_ filter: AuditFilter, beforeSeq: Int64?) -> AuditRequest {
        AuditRequest(filter: filter, beforeSeq: beforeSeq, limit: pageSize)
    }

    /// Starts over under [filter] and reads the first entries.
    func reset(_ filter: AuditFilter) async throws -> Snapshot {
        snapshot = Snapshot(filter: filter)
        cursor = nil
        return try await more()
    }

    /// Reads the newest page again and puts the entries that arrived since the newest one shown on top (the vault added
    /// them while History was open or away, as `audit.exported` after an export). The older entries and the cursor stay.
    /// When more arrived than the page holds, when nothing is shown yet, or when the way the search runs changed, it
    /// starts over (``reset(_:)``).
    func refresh() async throws -> Snapshot {
        let s = snapshot
        guard let top = s.entries.first?.seq else { return try await reset(s.filter) }
        let r = try await repo.auditPage(request(s.filter, beforeSeq: nil))
        return startsOver(s, r, top) ? try await reset(s.filter) : prepend(s, r, top)
    }

    /// Whether ``refresh()`` must start over: entries between the newest page and [top], or the search now runs here.
    private func startsOver(_ s: Snapshot, _ r: AuditResult, _ top: Int64) -> Bool {
        let q = s.filter.q
        let local = s.localSearch || (q != nil && !r.searchSent)
        // The vault returned an entry `q` cannot match anywhere: it ignored the search (as in `more`).
        let ignored = q.map { q in !local && r.entries.contains { !couldMatch(q, $0) } } ?? false
        if ignored { repo.searchIgnored() }
        return ignored || local != s.localSearch || (r.nextBeforeSeq.map { $0 > top + 1 } ?? false)
    }

    /// The entries of [r] newer than [top] that the list shows, on top of [s].
    private func prepend(_ s: Snapshot, _ r: AuditResult, _ top: Int64) -> Snapshot {
        let q = s.filter.q
        let fresh = r.entries.filter { e in
            e.seq > top && s.filter.acceptsExceptSearch(e) && (!s.localSearch || searchMatches(q, e))
        }
        guard !fresh.isEmpty else { return s }
        var n = s
        n.entries = fresh + s.entries
        n.chainBroken = s.chainBroken || (s.filter.isEmpty && !AuditChain.consistent(fresh + s.entries.prefix(1)))
        snapshot = n
        return n
    }

    /// Reads older entries (nothing once ``Snapshot/end``).
    func more() async throws -> Snapshot {
        var s = snapshot
        var pages = 0
        var added = 0
        while !s.end, pages < maxPagesPerLoad, added < minPerLoad {
            let r = try await repo.auditPage(request(s.filter, beforeSeq: cursor))
            pages += 1
            let q = s.filter.q
            var local = s.localSearch || (q != nil && !r.searchSent)
            if let q, !local, r.entries.contains(where: { !couldMatch(q, $0) }) {
                // The vault returned an entry `q` cannot match anywhere: it ignored the search (before 0.20.0).
                repo.searchIgnored()
                local = true
            }
            let known = Set(s.entries.map(\.seq))
            let fresh = r.entries.filter { e in
                s.filter.acceptsExceptSearch(e) && !known.contains(e.seq) && (!local || searchMatches(q, e))
            }
            added += fresh.count
            cursor = r.nextBeforeSeq
            let linked = Array(s.entries.suffix(1)) + fresh
            s.chainBroken = s.chainBroken || (s.filter.isEmpty && !AuditChain.consistent(linked))
            s.entries += fresh
            s.end = cursor == nil
            s.localSearch = local
            s.partial = r.partial
            snapshot = s
        }
        return s
    }

    /// Whether this phone's search for [q] matches [e] (no search: every entry).
    private func searchMatches(_ q: String?, _ e: AuditRecord) -> Bool {
        q.map { AuditFilter.matches($0, fields: localText(e)) } ?? true
    }

    /// Whether a 0.20.0 vault could have matched [q] on [e]: on its kind or the connection's names the app knows, or on the
    /// names of a device, an item or a connection, which the app may not hold.
    private func couldMatch(_ q: String, _ e: AuditRecord) -> Bool {
        AuditFilter.matches(q, fields: localText(e)) || e.entry.deviceID != nil || AuditRecord.itemRefKinds.contains(e.kind)
            || e.entry.connectionID != nil
    }
}
