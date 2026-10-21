import Foundation
import Observation
import VettIDData

/// The History screen's state. The entries and names are the member's own: never printed, dumped or mirrored. Mirrors
/// vettid-android `HistoryUiState`.
public struct HistoryState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var entries: [AuditRecord] = []
    public var filter = AuditFilter()
    public var datePreset = DatePreset.any
    /// id → "First Last" of the member's connections ("" before the names arrived: ``connectionLabel(_:)`` says "Name not
    /// shared yet"), for the rows and the connection filter.
    public var connectionNames: [String: String] = [:]
    /// id → name of the member's items (the Vault list), for the rows of item entries (§10.9); nil while the app holds no
    /// list (the Vault screens come with IOS-PLAN §8 I3.1): no item is then named, rather than every one called deleted
    /// (chosen; not in the spec).
    public var itemNames: [String: String]?
    /// The vault's devices (`device.list`), for entries with a device; nil while not known.
    public var devices: HistoryDevices?
    public var loading = true
    public var loadingMore = false
    public var end = false
    public var localSearch = false
    /// The vault's search ran out of its budget on the last page and goes on with older entries.
    public var partial = false
    /// The unfiltered log did not chain (§10.9): the red banner.
    public var chainBroken = false
    public var error: FailureKind?

    public init(filter: AuditFilter = AuditFilter()) { self.filter = filter }

    /// The connections the filter offers, by name.
    public var connections: [ConnectionOption] {
        connectionNames.keys.map { ConnectionOption(id: $0, name: connectionLabel($0)) }
            .sorted { $0.name.lowercased() == $1.name.lowercased() ? $0.id < $1.id : $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The entries the list shows: [entries] without the hidden kinds (IOS-PLAN §4.1), which stay in [entries] for the
    /// chain check.
    public var shown: [AuditRecord] { entries.filter { !AuditKinds.hidden($0.kind, $0.entry.ref) } }

    /// Nothing to show and nothing filtered: "No history yet" (with hidden entries read and more to read, the list loads on).
    public var emptyHistory: Bool { shown.isEmpty && filter.isEmpty && (end || entries.isEmpty) }

    public var description: String {
        "HistoryState(entries: \(entries.count), loading: \(loading), loadingMore: \(loadingMore), end: \(end), "
            + "localSearch: \(localSearch), chainBroken: \(chainBroken), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// History (ANDROID-PLAN §4 History): the member's audit log through `audit.list` (VAULT-MESSAGING 0.20.0 §10.9), newest
/// first, read in pages as the list scrolls; searched by the vault (`q`, sent after a 300 ms pause), filtered by one
/// category, a connection and dates. Read-only. Opened from a connection's page, the connection is preset. A list refused
/// because the daily check was due reads again by itself once a check passes. Mirrors vettid-android `HistoryViewModel`.
@MainActor
@Observable
public final class HistoryViewModel {
    /// ANDROID-PLAN §4 History: the search is sent after a 300 ms pause.
    public static let searchDebounce: Duration = .milliseconds(300)

    @ObservationIgnored private let history: any HistoryRepository
    @ObservationIgnored private let connections: (any ConnectionsRepository)?
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored private let itemNames: (@MainActor () -> [String: String]?)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    @ObservationIgnored private var known: [String: ConnectionInfo] = [:]
    @ObservationIgnored private var pager: HistoryPager!
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    /// Bumped by every refresh and reload: only the latest refresh, when it ends, says no refresh runs any more (two quick
    /// refreshes chain; the first one's end must not let a page load run beside the second on the same pager).
    @ObservationIgnored private var refreshGeneration = 0
    private var local: HistoryState

    /// [connectionID]: a connection's History (its page's "History"). [items]: the Vault list, read quietly when it has not
    /// been read and followed for its names ([itemNames] in its place: the names by item id, nil before the list is read).
    /// [debounce], [now] and [calendar]: tests set them.
    public init(
        history: any HistoryRepository, connections: (any ConnectionsRepository)? = nil, ownerChecks: (any OwnerCheckRepository)? = nil,
        connectionID: String? = nil, items: (any ItemsRepository)? = nil, itemNames: (@MainActor () -> [String: String]?)? = nil,
        debounce: Duration = HistoryViewModel.searchDebounce, now: @escaping @MainActor () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.history = history
        self.connections = connections
        self.ownerChecks = ownerChecks
        self.itemNames = itemNames ?? AuditKinds.itemNames(items)
        self.debounce = debounce
        self.now = now
        self.calendar = calendar
        local = HistoryState(filter: AuditFilter(connectionID: connectionID))
        local.itemNames = self.itemNames?()
        pager = newPager()
        // The item names follow the Vault list (an item renamed, deleted, or the list read meanwhile).
        if self.itemNames != nil {
            follows.add(follow(self, read: { $0.itemNames?() }, apply: { m, n in m.local.itemNames = n }))
        }
        items?.readIfNotLoaded()
        if connections != nil {
            follows.add(follow(self, read: { $0.connections?.connections ?? [] }, apply: { $0.onConnections($1) }))
            let c = connections
            work.launch { try? await c?.refresh() }
        }
        loadDevices(refresh: false)
        reload()
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck }, apply: { $0.onOwnerCheck($1) }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public var state: HistoryState { local }

    private func newPager() -> HistoryPager {
        HistoryPager(repo: history) { [weak self] r in self?.localText(r) ?? AuditFilter.kindText(r.kind) }
    }

    private func onConnections(_ list: [ConnectionInfo]) {
        known = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        local.connectionNames = Dictionary(list.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
    }

    /// The daily check passed (or the hold ended): a list refused because it was due reads again by itself.
    private func onOwnerCheck(_ v: OwnerCheckView?) {
        guard v?.state == .ok, local.error == .ownerCheckRequired else { return }
        retry()
    }

    /// The device names (ANDROID-PLAN §4 History), best effort: without them rows name no device.
    private func loadDevices(refresh: Bool) {
        let history = history
        work.launch { [weak self] in
            if let d = await history.devices(refresh: refresh) { self?.local.devices = d }
        }
    }

    /// What this phone can search when the vault does not (the fields of §10.9 it holds): the kind in both forms, the
    /// entry's title in the app's language, the connection's names (the app uses no aliases), the item and the device.
    func localText(_ r: AuditRecord) -> [String] {
        let c = r.entry.connectionID.flatMap { known[$0] }
        let item = AuditKinds.itemOf(r.kind, r.entry.ref).flatMap { local.itemNames?[$0] }
        let device = local.devices?.device(r.entry.deviceID)?.rowName
        let name = c.flatMap { $0.displayName.isEmpty ? nil : $0.displayName }
        let title = HistoryText.title(r.kind, r.entry.ref, names: EntryNames(connection: name, device: device, item: item))
        return AuditFilter.kindText(r.kind) + [title, c?.name, c?.firstName, c?.lastName, c?.accountName, item, device].compactMap { $0 }
    }

    public func setCategory(_ c: AuditCategory?) { setFilter(HistoryFilters.category(local.filter, c)) }

    public func setConnection(_ id: String?) {
        var f = local.filter
        f.connectionID = id
        setFilter(f)
    }

    public func setDates(_ preset: DatePreset, since: Date? = nil, until: Date? = nil) {
        local.datePreset = preset
        setFilter(HistoryFilters.dates(local.filter, preset, now: now(), calendar: calendar, since: since, until: until))
    }

    public func setQuery(_ q: String) {
        let before = local.filter
        var f = before
        f.query = q
        local.filter = f
        // Only a change of what is sent (trimmed, NFC, at most 128 bytes) restarts the list.
        if f.q != before.q { reload(debounced: true) }
    }

    public func clearFilters() {
        local.datePreset = .any
        setFilter(AuditFilter())
    }

    public func retry() {
        if local.entries.isEmpty {
            reload()
        } else {
            local.error = nil
            loadMore()
        }
    }

    private func setFilter(_ f: AuditFilter) {
        guard f != local.filter else { return }
        local.filter = f
        reload()
    }

    private func reload(debounced: Bool = false) {
        job?.cancel()
        local.loading = true
        local.loadingMore = false
        local.error = nil
        if !debounced { local.entries = [] }
        refreshing = false
        refreshGeneration += 1
        let p = newPager()
        pager = p
        let pause = debounce
        job = work.launch { [weak self] in
            if debounced, pause > .zero {
                try? await Task.sleep(for: pause)
                if Task.isCancelled { return }
            }
            guard let filter = self?.local.filter else { return }
            await self?.load(p) { try await p.reset(filter) }
        }
    }

    /// The list is shown again (reopened from the drawer, back from an entry, or an export closed, which the vault
    /// recorded as `audit.exported`): the newest page is read again and what arrived since goes on top. Nothing while the
    /// first page is loading (that read is the newest); after a failure or with nothing shown, a full reload. Runs after
    /// a load in progress (the pager reads one load at a time).
    public func refresh() {
        if local.loading { return }
        if local.entries.isEmpty || local.error != nil {
            reload()
            return
        }
        // A device may have been paired or removed meanwhile, an item renamed or deleted.
        loadDevices(refresh: true)
        local.itemNames = itemNames?()
        let before = job
        let p: HistoryPager = pager
        refreshing = true
        refreshGeneration += 1
        let g = refreshGeneration
        job = work.launch { [weak self] in
            await before?.value
            await self?.load(p) { try await p.refresh() }
            if self?.refreshGeneration == g { self?.refreshing = false }
        }
    }

    /// The list's end came into view: the next page, unless one is loading or the results have no more.
    public func loadMore() {
        let s = local
        guard !(s.loading || s.loadingMore || refreshing), !s.end, s.error == nil else { return }
        local.loadingMore = true
        let p: HistoryPager = pager
        job = work.launch { [weak self] in await self?.load(p) { try await p.more() } }
    }

    /// Runs one load of [p] and shows what it read, or its failure; nothing when [p] was replaced meanwhile (a new
    /// filter) or the load was cancelled.
    private func load(_ p: HistoryPager, _ body: () async throws -> HistoryPager.Snapshot) async {
        do {
            let snap = try await body()
            guard p === pager, !Task.isCancelled else { return }
            local.entries = snap.entries
            local.end = snap.end
            local.localSearch = snap.localSearch
            local.partial = snap.partial
            local.chainBroken = local.chainBroken || snap.chainBroken
            local.loading = false
            local.loadingMore = false
            local.error = nil
        } catch {
            guard p === pager, !Task.isCancelled, !(error is CancellationError) else { return }
            local.loading = false
            local.loadingMore = false
            local.error = failureKind(error)
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
