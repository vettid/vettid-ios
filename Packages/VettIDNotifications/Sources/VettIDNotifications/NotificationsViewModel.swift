import Foundation
import Observation
import VettIDData
import VettIDVault

/// An archive the member can undo: back to [previous] (`active` or `read`).
public struct ArchiveUndo: Equatable, Sendable {
    public var itemID: String
    public var previous: String

    public init(itemID: String, previous: String) {
        self.itemID = itemID
        self.previous = previous
    }
}

/// The Notifications screen's state and its Archived view's. The items and names are the member's own: never printed,
/// dumped or mirrored. Mirrors vettid-android `NotificationsUiState`.
public struct NotificationsState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var items: [FeedItem] = []
    public var names = FeedNames()
    public var load: FeedLoad = .notLoaded
    public var archived = false
    public var unreadOnly = false
    /// The detail sheet's item, with [sheetGone] when its target is gone (or it has none).
    public var sheet: FeedItem?
    public var sheetGone = false
    public var confirmDelete: FeedItem?
    public var undo: ArchiveUndo?
    public var markingAll = false
    public var error: FailureKind?
    /// A screen to open (taken by the screen through ``NotificationsViewModel/targetTaken()``).
    public var open: FeedTarget?
    /// Items that were unread when the screen came into view, or arrived while it was in view, and were marked read by
    /// viewing (ANDROID-PLAN §4 Notifications): they keep the dot and stay under the Unread chip until the member leaves.
    public var fresh: Set<String> = []

    public init(archived: Bool = false) { self.archived = archived }

    public func sections(calendar: Calendar = .current) -> [FeedSection] {
        FeedSections.of(items, archived: archived, unreadOnly: unreadOnly, calendar: calendar, fresh: fresh)
    }

    /// Whether [item] shows as unread: `active`, or read by viewing while the screen is open.
    public func showsUnread(_ item: FeedItem) -> Bool {
        item.status == FeedManager.statusActive || (item.status == FeedManager.statusRead && fresh.contains(item.itemID))
    }

    public var unread: Int { items.count { $0.status == FeedManager.statusActive } }

    public var description: String {
        "NotificationsState(load: \(load), items: \(items.count), archived: \(archived), unreadOnly: \(unreadOnly), "
            + "sheet: \(sheet != nil), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Notifications (ANDROID-PLAN §4 Notifications): the vault's feed from ``FeedRepository``, with names from the app's
/// caches. Tapping an item marks it read and opens its target, or the detail sheet when the target is gone; swiping
/// archives (with Undo) or marks read and unread; the Archived view moves items back or deletes them (confirmed).
///
/// **Viewing marks read**: while the screen is in view (``shown()`` to ``paused()``), every unread item that is not
/// `urgent` is marked read (``FeedRepository/markViewed(_:)``): those unread when it came into view, and those that arrive
/// while it is. Each item at most once while this model lives, so an item the member marks unread stays unread. They keep
/// their dot (``NotificationsState/fresh``) until the member leaves (``left()``). Urgent items (Needs attention) stay
/// unread until tapped or marked read. Mirrors vettid-android `NotificationsViewModel`.
@MainActor
@Observable
public final class NotificationsViewModel {
    @ObservationIgnored private let feed: any FeedRepository
    @ObservationIgnored private let connections: (any ConnectionsRepository)?
    @ObservationIgnored private let approvals: (any ApprovalsRepository)?
    @ObservationIgnored private let items: (any ItemsRepository)?
    @ObservationIgnored private let votes: (any VotesRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// Whether the screen is in view.
    @ObservationIgnored private var inView = false
    /// Items seen while in view: an item not among them that shows up is an arrival.
    @ObservationIgnored private var seen = Set<String>()
    /// Items marked read by viewing, or marked unread by the member: never marked read by viewing (again).
    @ObservationIgnored private var handled = Set<String>()
    private var local: NotificationsState

    /// [archived]: the Archived view. [connections], [approvals], [items] and [votes]: the names, followed as they change; the Vault
    /// list is read quietly when it has not been read (an `item.revealed` opens its item).
    public init(
        feed: any FeedRepository, connections: (any ConnectionsRepository)? = nil, approvals: (any ApprovalsRepository)? = nil,
        items: (any ItemsRepository)? = nil, votes: (any VotesRepository)? = nil, archived: Bool = false
    ) {
        self.feed = feed
        self.connections = connections
        self.approvals = approvals
        self.items = items
        self.votes = votes
        local = NotificationsState(archived: archived)
        if feed.load == .notLoaded { refresh() }
        items?.readIfNotLoaded()
        follows.add(follow(self, read: { $0.feed.items }, apply: { m, _ in m.onItems() }))
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public var state: NotificationsState {
        var s = local
        s.items = feed.items
        s.load = feed.load
        s.names = FeedNames(
            connections: connections?.connections ?? [], items: items?.names ?? [:], approvals: approvals?.approvals ?? [],
            votes: votes?.votes ?? []
        )
        return s
    }

    private func onItems() {
        if inView { markViewed(arrivalsOnly: true) }
    }

    /// The screen came into view: the unread items that are not urgent are marked read.
    public func shown() {
        guard !local.archived else { return }
        inView = true
        markViewed(arrivalsOnly: false)
    }

    /// The screen is no longer in the foreground: nothing more is marked read until it is ``shown()`` again.
    public func paused() { inView = false }

    /// The member left the screen: the items read by viewing show as read from now on.
    public func left() {
        inView = false
        local.fresh = []
    }

    /// Marks read the unread items that are not urgent and not yet handled: all of them when the screen comes into view,
    /// else only those not seen before (arrivals; not an item another device marked unread meanwhile).
    private func markViewed(arrivalsOnly: Bool) {
        let now = feed.items
        let ids = now.filter { i in
            i.status == FeedManager.statusActive && !FeedKinds.urgent(i) && !handled.contains(i.itemID)
                && (!arrivalsOnly || !seen.contains(i.itemID))
        }.map(\.itemID)
        seen.formUnion(now.map(\.itemID))
        guard !ids.isEmpty else { return }
        handled.formUnion(ids)
        local.fresh.formUnion(ids)
        feed.markViewed(ids)
    }

    public func refresh() {
        let feed = feed
        guarded { try await feed.refresh() }
    }

    public func setUnreadOnly(_ on: Bool) { local.unreadOnly = on }

    /// A tap: marks the item read (not waiting for the answer) and opens its target, or the sheet.
    public func open(_ item: FeedItem) {
        feed.markReadQuietly(item.itemID)
        let target = FeedKinds.target(item)
        if target == .sheet || !exists(target) {
            local.sheet = item
            local.sheetGone = target != .sheet || FeedKinds.isAsk(item.kind)
        } else {
            local.open = target
        }
    }

    /// Whether the target is still there (a removed connection, a deleted item, an ask decided or expired: the sheet).
    func exists(_ t: FeedTarget) -> Bool {
        let n = state.names
        switch t {
        case .approval(let key): return n.approvals[key] != nil
        case .connection(let id), .conversation(let id), .sharedWithYou(let id): return n.connections[id] != nil
        case .shareRule(let id, _): return n.connections[id] != nil
        case .item(let id): return n.items[id] != nil
        default: return true
        }
    }

    public func targetTaken() { local.open = nil }

    public func closeSheet() {
        local.sheet = nil
        local.sheetGone = false
    }

    /// Archived, with an Undo that restores the previous status.
    public func archive(_ item: FeedItem) {
        let previous = [FeedManager.statusActive, FeedManager.statusRead].contains(item.status) ? item.status : FeedManager.statusRead
        local.undo = ArchiveUndo(itemID: item.itemID, previous: previous)
        setStatus(item.itemID, FeedManager.statusArchived)
    }

    public func undoArchive() {
        guard let u = local.undo else { return }
        handled.insert(u.itemID)
        local.undo = nil
        setStatus(u.itemID, u.previous)
    }

    public func undoShown() { local.undo = nil }

    /// Read ↔ unread, as the row shows it. An item read by viewing (still dotted) loses its dot; an item marked unread is
    /// not marked read by viewing again while this model lives.
    public func toggleRead(_ item: FeedItem) {
        let id = item.itemID
        if local.showsUnread(item) {
            local.fresh.remove(id)
            if item.status == FeedManager.statusActive { setStatus(id, FeedManager.statusRead) }
        } else {
            handled.insert(id)
            setStatus(id, FeedManager.statusActive)
        }
    }

    /// Archived view: back to the main list, read.
    public func moveToNotifications(_ item: FeedItem) { setStatus(item.itemID, FeedManager.statusRead) }

    /// Asks to delete [item] (nil: never mind).
    public func askDelete(_ item: FeedItem?) { local.confirmDelete = item }

    public func delete() {
        guard let item = local.confirmDelete else { return }
        local.confirmDelete = nil
        let feed = feed
        guarded { try await feed.delete(item.itemID) }
    }

    public func markAllRead() {
        guard !local.markingAll else { return }
        local.markingAll = true
        local.fresh = []
        let feed = feed
        work.launch { [weak self] in
            do {
                try await feed.markAllRead()
            } catch {
                self?.local.error = failureKind(error)
            }
            self?.local.markingAll = false
        }
    }

    public func errorShown() { local.error = nil }

    private func setStatus(_ id: String, _ status: String) {
        let feed = feed
        guarded { try await feed.setStatus(id, status: status) }
    }

    private func guarded(_ body: @escaping @MainActor () async throws -> Void) {
        work.launch { [weak self] in
            do {
                try await body()
            } catch {
                self?.local.error = failureKind(error)
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
