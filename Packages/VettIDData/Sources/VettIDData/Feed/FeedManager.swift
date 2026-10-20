import Foundation
import Observation
import VettIDVault

/// The vault calls behind ``FeedManager`` (VAULT-MESSAGING §10.9); a test passes its own.
public protocol FeedOps: Sendable {
    /// `feed.list{after_seq, limit}`: every item changed after [afterSeq], in `seq` order, deleted ones included.
    func feedList(afterSeq: Int64, limit: Int) async throws -> FeedPage
    func feedUpdate(_ itemID: String, status: String) async throws -> FeedItem
    func feedDelete(_ itemID: String) async throws
    /// `feed.retention_days` (§10.8); nil when the vault does not say.
    func feedRetentionDays() async throws -> Int?
}

extension VaultApi: FeedOps {
    public func feedList(afterSeq: Int64, limit: Int) async throws -> FeedPage {
        try await feedList(status: nil, afterSeq: afterSeq, limit: limit)
    }

    public func feedUpdate(_ itemID: String, status: String) async throws -> FeedItem {
        try await feedUpdate(itemID, status: status, priority: nil)
    }

    public func feedRetentionDays() async throws -> Int? {
        try await settingsGet().values[FeedManager.keyRetention].flatMap { Int($0) }
    }
}

/// Whether the feed has been read since the vault opened.
public enum FeedLoad: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded
    case failed
}

/// The bell's count (ANDROID-PLAN §4 Notifications): unread items, and whether one of them is urgent (the badge turns red).
public struct FeedBadge: Equatable, Sendable {
    public var unread = 0
    public var urgent = false

    public init(unread: Int = 0, urgent: Bool = false) {
        self.unread = unread
        self.urgent = urgent
    }
}

/// The vault's feed in the app (ANDROID-PLAN §4 Notifications, VAULT-MESSAGING §10.9): the owner's activity list, with
/// read and archive state shared by the owner's devices, as ``Repositories.swift`` describes the repositories. Every
/// failure is a ``VaultFailure``. Mirrors vettid-android `FeedRepository`.
@MainActor
public protocol FeedRepository: AnyObject, Observable, Sendable {
    /// The live items (never `deleted`), newest first by `at`.
    var items: [FeedItem] { get }
    var load: FeedLoad { get }
    var badge: FeedBadge { get }

    /// Reads the whole feed again.
    func refresh() async throws

    /// `feed.update{status}` (`active`, `read` or `archived`): shown at once, undone if the vault refuses.
    func setStatus(_ itemID: String, status: String) async throws

    /// Marks [itemID] read without waiting for the answer (a tap on a row or a notification).
    func markReadQuietly(_ itemID: String)

    /// Items shown on the Notifications screen: those still unread and not `urgent` are marked read, at most 4 in flight
    /// (shared with ``markAllRead()``), without waiting for the answers. Urgent items stay unread until tapped.
    func markViewed(_ itemIDs: [String])

    /// `feed.delete` (only from Archived, confirmed).
    func delete(_ itemID: String) async throws

    /// Marks every unread item read, one `feed.update` each (no bulk type), at most 4 in flight; throws the first failure
    /// after the others ran.
    func markAllRead() async throws
}

/// ``FeedRepository`` over ``FeedOps``. The items, the cursor (the highest `seq` applied) and the load state are kept in
/// memory only, while the vault is open: never written to the phone, and dropped on lock, on entering the hold, on a
/// wipe and with the process (ANDROID-PLAN §4 Notifications, 10).
///
/// - **Open** (``open()``, ``refresh()``): `feed.list{after_seq: 0, limit: 500}`, repeated from the last item's `seq`
///   until a page is shorter than the limit; `deleted` items are dropped; the cursor is the answer's `seq`.
/// - **Live** (``onEvent(_:)``): `feed.event` with `seq` = cursor + 1 is applied; any other `seq`, and `sync.event`
///   `feed.updated` / `feed.deleted`, start a catch-up (``catchUp()``): `feed.list{after_seq: cursor}`, paged, one in
///   flight and at most one queued. A batch's later ask comes as a change of its item (`count`, `seq`) with the status
///   the member left (0.23.1); it replaces the cached item where it is.
/// - **Own changes** (``setStatus(_:status:)``, ``delete(_:)``) apply the answer at once: the vault sends no `sync.event`
///   to the sender.
/// - **Retention**: items older than `feed.retention_days` (default 30) are dropped here as well.
/// - **History only** (IOS-PLAN §4.1): `vault.pin_changed`, `credential.recovered`, `recovery.device_paired` and a
///   closure item that is not a `rollback` are neither listed, counted nor passed to ``onArrival``; the cursor moves past
///   them (``FeedKinds/isHidden(_:)``).
/// - **Held or due** ([gated]): nothing is listed and events are ignored; after the check, a full read.
///
/// Mirrors vettid-android `FeedManager`.
@MainActor
@Observable
public final class FeedManager: FeedRepository {
    public nonisolated static let statusActive = "active"
    public nonisolated static let statusRead = "read"
    public nonisolated static let statusArchived = "archived"
    public nonisolated static let statusDeleted = "deleted"
    public nonisolated static let priorityHigh = "high"
    public nonisolated static let priorityUrgent = "urgent"
    public nonisolated static let keyRetention = "feed.retention_days"
    public nonisolated static let defaultRetentionDays = 30
    static let maxRetentionDays = 365
    static let settable: Set<String> = [statusActive, statusRead, statusArchived]
    /// `feed.list`'s largest page (§10.9).
    public nonisolated static let page = 500
    /// The feed keeps at most 1,000 live items (§10.9); deleted ones come too, so a few pages more.
    static let maxPages = 8
    static let inFlight = 4

    public private(set) var items: [FeedItem] = []
    public private(set) var load: FeedLoad = .notLoaded
    public private(set) var badge = FeedBadge()

    @ObservationIgnored private var byID: [String: FeedItem] = [:]
    @ObservationIgnored private(set) var cursor: Int64 = 0
    @ObservationIgnored private var retentionDays = FeedManager.defaultRetentionDays
    /// Bumped by ``clear()``: a read that started before it is not applied after it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading: Task<Void, any Error>?
    @ObservationIgnored private var catchUpQueued = false
    @ObservationIgnored private let marking = FeedMarking(limit: FeedManager.inFlight)

    @ObservationIgnored let ops: @MainActor () async throws -> any FeedOps
    /// The calls of a read nobody asked for (the opening, an event): only over the session already open, never opening one.
    @ObservationIgnored let quietOps: @MainActor () async throws -> any FeedOps
    /// True while the vault is held or due (VAULT-MESSAGING §3.6.3): nothing of the feed is shown.
    @ObservationIgnored private let gated: @MainActor () -> Bool
    @ObservationIgnored let now: @Sendable () -> Date
    /// New and changed unread items as they arrive (`feed.event`, the items of a catch-up), never from a full read: the
    /// notifications' source (IOS-PLAN §6.7), so that nothing missed while locked or held is replayed as a notification.
    @ObservationIgnored public var onArrival: @MainActor (FeedItem) -> Void = { _ in }

    public init(
        ops: @escaping @MainActor () async throws -> any FeedOps,
        quietOps: (@MainActor () async throws -> any FeedOps)? = nil,
        gated: @escaping @MainActor () -> Bool = { false },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.gated = gated
        self.now = now
    }

    /// The vault opened (an unlock, a start with it open, a passed owner check): the feed is read in the background.
    public func open() {
        Task { [weak self] in await self?.openNow() }
    }

    /// ``open()``, awaited (the opening's reads run one after the other).
    public func openNow() async { try? await read(full: true, quietly: true) }

    /// Forgets everything: the vault locked, was held or wiped.
    public func clear() {
        generation += 1
        byID = [:]
        cursor = 0
        catchUpQueued = false
        load = .notLoaded
        publish()
    }

    /// `feed.event` and `sync.event{feed.updated, feed.deleted}` (§10.1, §10.9).
    public func onEvent(_ m: VaultMessage) {
        switch m.type {
        case "feed.event":
            // While held only the clone alarm's item arrives; it opens the alarm path elsewhere, it is not listed.
            guard !gated(), let item = FeedItem.of(m.object) else { return }
            onItem(item)
        case "sync.event":
            let kind = VaultJSON.string(m.object, "kind")
            if kind == "feed.updated" || kind == "feed.deleted", !gated() { catchUp() }
        default:
            break
        }
    }

    private func onItem(_ item: FeedItem) {
        // A read under way may have been answered before the item: read again after it.
        guard load == .loaded else { return catchUp() }
        guard item.seq > cursor else { return } // already applied
        let next = item.seq == cursor + 1
        apply([item])
        if next { cursor = item.seq }
        if item.status == Self.statusActive { arrived(item) }
        if !next { catchUp() }
    }

    /// Reads what changed after the cursor (a `seq` gap, another device's change, a return to the foreground, a relay
    /// reconnect). One read in flight and at most one queued behind it; before the first full read, a full read.
    public func catchUp() {
        guard !catchUpQueued else { return }
        catchUpQueued = true
        Task { [weak self] in
            guard let self else { return }
            try? await read(full: load != .loaded, quietly: true, queued: true)
        }
    }

    public func refresh() async throws { try await read(full: true, quietly: false) }

    /// One paged read after the reads before it ([full]: from 0, replacing everything).
    private func read(full: Bool, quietly: Bool, queued: Bool = false) async throws {
        let before = reading
        let task = Task { @MainActor [weak self] in
            _ = await before?.result
            guard let self else { return }
            if queued { catchUpQueued = false }
            try await readNow(full: full || load != .loaded, quietly: quietly)
        }
        reading = task
        try await task.value
    }

    private func readNow(full: Bool, quietly: Bool) async throws {
        // Held or due: nothing is read, so a read queued after the clear cannot fill the feed again.
        guard !gated() else { return }
        let g = generation
        if full { load = .loading }
        do {
            let o = quietly ? quietOps : ops
            if full { await readRetention(o) }
            let (changed, seq) = try await pages(o, from: full ? 0 : cursor)
            guard g == generation else { return }
            let known = full ? [:] : byID
            if full { byID = [:] }
            apply(changed)
            cursor = max(full ? 0 : cursor, seq)
            load = .loaded
            guard !full else { return }
            var seen = Set<String>()
            for c in changed where c.status == Self.statusActive && (known[c.itemID]?.seq ?? 0) < c.seq && seen.insert(c.itemID).inserted {
                if let now = byID[c.itemID] { arrived(now) }
            }
        } catch {
            if full, g == generation { load = .failed }
            throw VaultFailures.map(error)
        }
    }

    /// `feed.list{after_seq}` paged from [from] until a page is shorter than the limit: the items and the answer's `seq`.
    private func pages(_ o: @MainActor () async throws -> any FeedOps, from: Int64) async throws -> ([FeedItem], Int64) {
        var after = from
        var changed: [FeedItem] = []
        var seq = from
        for _ in 0..<Self.maxPages {
            let p = try await o().feedList(afterSeq: after, limit: Self.page)
            seq = max(seq, p.seq)
            changed += p.items
            guard p.items.count >= Self.page, let last = p.items.last else { break }
            after = last.seq
        }
        return (changed, seq)
    }

    private func readRetention(_ o: @MainActor () async throws -> any FeedOps) async {
        guard let d = try? await o().feedRetentionDays(), (1...Self.maxRetentionDays).contains(d) else { return }
        retentionDays = d
    }

    /// A notification's source, except the History-only kinds (IOS-PLAN §4.1, de-duplication).
    private func arrived(_ item: FeedItem) {
        if !FeedKinds.isHidden(item) { onArrival(item) }
    }

    /// Replaces each item by id, removes the deleted ones, drops what is past retention, and publishes. The History-only
    /// kinds (IOS-PLAN §4.1) are neither listed nor counted.
    private func apply(_ changed: [FeedItem]) {
        for item in changed {
            let gone = item.status == Self.statusDeleted || FeedKinds.isHidden(item)
            byID[item.itemID] = gone ? nil : item
        }
        publish()
    }

    private func publish() {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        // Each time parsed once (a formatter per parse).
        let dated = byID.values.map { ($0, Self.at($0)) }.filter { ($0.1 ?? .distantFuture) >= cutoff }
        byID = Dictionary(uniqueKeysWithValues: dated.map { ($0.0.itemID, $0.0) })
        let sorted = dated.sorted { a, b in
            let (x, y) = (a.1 ?? .distantPast, b.1 ?? .distantPast)
            return x != y ? x > y : a.0.itemID > b.0.itemID
        }.map(\.0)
        if sorted != items { items = sorted }
        let unread = sorted.filter { $0.status == Self.statusActive }
        let next = FeedBadge(unread: unread.count, urgent: unread.contains { $0.priority == Self.priorityUrgent })
        if next != badge { badge = next }
    }

    /// An item's `at`; nil when it does not parse.
    public nonisolated static func at(_ item: FeedItem) -> Date? { OwnerCheckManager.instant(item.at) }

    // MARK: - The member's changes

    public func setStatus(_ itemID: String, status: String) async throws {
        guard Self.settable.contains(status) else { throw VaultFailure(.other, code: "bad_request") }
        guard let before = byID[itemID], before.status != status else { return }
        var shown = before
        shown.status = status
        apply([shown])
        let answer: FeedItem
        do {
            answer = try await ops().feedUpdate(itemID, status: status)
        } catch {
            // Undone unless something newer arrived meanwhile.
            if let now = byID[itemID], now.seq == before.seq, now.status == status { apply([before]) }
            throw VaultFailures.map(error)
        }
        if answer.seq == cursor + 1 { cursor = answer.seq }
        if (byID[itemID]?.seq ?? 0) <= answer.seq, byID[itemID] != nil { apply([answer]) }
    }

    public func markReadQuietly(_ itemID: String) {
        guard byID[itemID]?.status == Self.statusActive else { return }
        Task { [weak self] in try? await self?.setStatus(itemID, status: Self.statusRead) }
    }

    /// Marks read the unread items of [kinds] whose `ref` is [ref] (an ask decided in Approvals), or, with
    /// [connectionID], those of that connection (a conversation opened: its `message.received` items).
    public func markReadWhere(kinds: Set<String>, ref: String? = nil, connectionID: String? = nil) {
        let ids = byID.values.filter { i in
            i.status == Self.statusActive && kinds.contains(i.kind) && (ref == nil || i.ref == ref)
                && (connectionID == nil || i.connectionID == connectionID)
        }.map(\.itemID)
        for id in ids { markReadQuietly(id) }
    }

    public func delete(_ itemID: String) async throws {
        do {
            try await ops().feedDelete(itemID)
        } catch {
            throw VaultFailures.map(error)
        }
        byID[itemID] = nil
        publish()
    }

    public func markViewed(_ itemIDs: [String]) {
        let wanted = Set(itemIDs)
        let ids = byID.values.filter { wanted.contains($0.itemID) && $0.status == Self.statusActive && $0.priority != Self.priorityUrgent }
            .map(\.itemID)
        guard !ids.isEmpty else { return }
        Task { [weak self] in try? await self?.markRead(ids) }
    }

    public func markAllRead() async throws {
        try await markRead(byID.values.filter { $0.status == Self.statusActive }.map(\.itemID))
    }

    /// `feed.update{status: "read"}` for each of [ids], at most 4 in flight; throws the first failure after the others ran.
    private func markRead(_ ids: [String]) async throws {
        let tasks = ids.map { id in
            Task { @MainActor [weak self] () -> (any Error)? in
                guard let self else { return nil }
                await marking.acquire()
                defer { marking.release() }
                do {
                    try await setStatus(id, status: Self.statusRead)
                    return nil
                } catch {
                    return error
                }
            }
        }
        var first: (any Error)?
        for t in tasks {
            let e = await t.value
            if first == nil { first = e }
        }
        if let first { throw first }
    }
}

/// At most [limit] `feed.update` in flight, shared by the viewed items and Mark all as read.
@MainActor
final class FeedMarking {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
