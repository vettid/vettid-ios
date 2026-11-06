import Foundation
import VettIDData
import VettIDVault

/// Posts and removes ``LocalNotification``s (``SystemNotificationPoster`` on the iPhone; a list in tests).
@MainActor
public protocol NotificationPoster: AnyObject {
    func post(_ n: LocalNotification)

    /// Removes the notifications [ids], delivered or pending.
    func remove(_ ids: [String])

    /// Removes every feed item notification still showing, whoever posted it (a process that ended with the vault open
    /// leaves them behind). Notifications that are not a feed item's are kept.
    func removeLeftovers()
}

/// Turns the feed into notifications (ANDROID-PLAN §4 Notification modes 7 and 8; IOS-PLAN §6.7). One per item, updated in
/// place for a batch without alerting again, removed when the item is read, archived or deleted on any device; every item
/// notification is removed when the feed is forgotten (the vault locked, was held or wiped). Only arrivals notify (a live
/// event or a catch-up, never a full read), so nothing missed while the vault was locked is replayed. Nothing about the
/// screen in front is notified: the Notifications list, or the screen the item opens. Nothing here is kept on disk.
///
/// iOS before Apple push (IOS-PLAN ID12): the feed is collected only while the app is in the foreground, so these show as
/// banners while the app is open on another screen; phase P brings the same content to the notification service
/// extension. Mirrors the feed part of vettid-android `FeedNotifier`; the vault's own state notices (locked, daily check
/// due, the clone alarm while held) are not posted on iOS yet.
@MainActor
public final class FeedNotifier {
    private let poster: any NotificationPoster
    private let previews: @MainActor () -> NotificationPreviews
    private let open: @MainActor () -> Bool
    private let active: @MainActor () -> Bool
    private let visible: @MainActor () -> NotifyVisible?
    private let allowed: @MainActor () -> Bool
    private let names: @MainActor () -> FeedNames
    private let messageText: @MainActor (_ connectionID: String, _ messageID: String) -> String?
    /// Reads the votes list afresh: true when the read went through, so that ``FeedNames/votesGaveUp`` is the vault's state
    /// after a `vote.result` item arrived.
    private let refreshVotes: @MainActor () async -> Bool
    private let voteListWait: Duration
    /// The item notifications this process posted that may still show.
    private(set) var posted = Set<String>()
    /// The choice the notifications showing were built with (read at start, then each choice told).
    private var shownWith: NotificationPreviews

    /// [open]: the vault is open on this phone and not held or due (§3.6.3). [active]: the app is in the foreground and
    /// active; nothing is posted otherwise (owner decision of 2026-11-02). [visible]: the screen in front; nil when the
    /// app is not active. [allowed]: the member allowed notifications for VettID (the iPhone's Settings decide, and turn
    /// them off). [names] and [messageText]: from the app's in-memory caches.
    public init(
        poster: any NotificationPoster,
        previews: @escaping @MainActor () -> NotificationPreviews,
        open: @escaping @MainActor () -> Bool,
        active: @escaping @MainActor () -> Bool = { true },
        visible: @escaping @MainActor () -> NotifyVisible?,
        allowed: @escaping @MainActor () -> Bool,
        names: @escaping @MainActor () -> FeedNames,
        messageText: @escaping @MainActor (_ connectionID: String, _ messageID: String) -> String?,
        refreshVotes: @escaping @MainActor () async -> Bool = { true },
        voteListWait: Duration = FeedNotifier.defaultVoteListWait
    ) {
        self.refreshVotes = refreshVotes
        self.voteListWait = voteListWait
        self.poster = poster
        self.previews = previews
        self.open = open
        self.active = active
        self.visible = visible
        self.allowed = allowed
        self.names = names
        self.messageText = messageText
        shownWith = previews()
    }

    /// At launch the vault is not open yet: every item notification still showing outlived the open vault of an earlier
    /// process, and goes (ANDROID-PLAN §4 Notification modes 8).
    public func start() {
        if !open() { poster.removeLeftovers() }
    }

    /// How long a `vote.result` waits for the votes list read before it is titled generically (VAULT-MESSAGING 0.83.6
    /// §10.19.6 step 4: the item carries no check state, the list does).
    public static let defaultVoteListWait: Duration = .seconds(3)

    /// A new or changed unread item (``FeedManager/onArrival``). A `vote.result` is the give-up item only by its vote's state
    /// in the list, and that list may be older than the item (a re-check's verdict, or the vault giving up on its own
    /// clock): the list is read again first, at most ``defaultVoteListWait``; if that does not go through, the generic
    /// "Vote results are out".
    public func arrived(_ item: FeedItem) {
        guard NotificationMapping.category(item) != nil, notifiable(item) else { return }
        guard item.kind == "vote.result", previews() != .nothing else { return deliver(item, votesFresh: true) }
        let refresh = refreshVotes
        let wait = voteListWait
        Task { [weak self] in
            let fresh = await Self.within(wait, refresh)
            self?.deliver(item, votesFresh: fresh)
        }
    }

    /// [work]'s answer, or false when it takes longer than [wait].
    private static func within(_ wait: Duration, _ work: @escaping @MainActor () async -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: wait)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func deliver(_ item: FeedItem, votesFresh: Bool) {
        // Looked at again: the item may have been read, or its screen opened, while the list was read.
        guard let category = NotificationMapping.category(item), notifiable(item) else { return }
        let p = previews()
        let text: String? = if p == .namesAndText, item.kind == "message.received", let c = item.connectionID, let m = item.ref {
            messageText(c, m)
        } else {
            nil
        }
        // Nothing names anyone with "Nothing": the names are not read.
        var names = p == .nothing ? FeedNames() : names()
        if !votesFresh { names.votesGaveUp = [] }
        var n = NotificationContent.of(item, category: category, previews: p, names: names, messageText: text)
        n.update = posted.contains(item.itemID)
        posted.insert(item.itemID)
        poster.post(n)
    }

    /// The feed's items now (``FeedManager/onItems``): those read, archived or deleted here or on another device go.
    public func itemsChanged(_ items: [FeedItem]) {
        let active = Set(items.filter { $0.status == FeedManager.statusActive }.map(\.itemID))
        let gone = posted.subtracting(active)
        guard !gone.isEmpty else { return }
        posted.subtract(gone)
        poster.remove(gone.sorted())
    }

    /// The feed was forgotten (``FeedManager/onCleared``: the vault locked, was held or wiped): no notification names
    /// anything any more.
    public func cleared() {
        let all = posted.sorted()
        posted = []
        if !all.isEmpty { poster.remove(all) }
        poster.removeLeftovers()
    }

    /// The app left the foreground (owner decision of 2026-11-02): every item notification goes, as at a lock, so that
    /// nothing naming anyone outlives the open session; nothing is posted until it is active again.
    public func backgrounded() { cleared() }

    /// The member chose what notifications show. A narrower choice (names and text to names, anything to nothing) removes
    /// the item notifications already showing, which show more than it allows; the next ones follow the choice.
    public func previewsChanged(_ p: NotificationPreviews) {
        let before = shownWith
        shownWith = p
        if Self.rank(p) < Self.rank(before) { cleared() }
    }

    private static func rank(_ p: NotificationPreviews) -> Int {
        switch p {
        case .nothing: 0
        case .names: 1
        case .namesAndText: 2
        }
    }

    private func notifiable(_ item: FeedItem) -> Bool {
        allowed() && active() && open() && item.status == FeedManager.statusActive && !shownOnScreen(item)
    }

    /// The Notifications screen, or the screen the item opens, is in front: the bell and the screen show it.
    private func shownOnScreen(_ item: FeedItem) -> Bool {
        switch visible() {
        case nil: false
        case .notifications: true
        case .target(let t): t == FeedKinds.target(item)
        }
    }
}
