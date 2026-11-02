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
    private let visible: @MainActor () -> NotifyVisible?
    private let allowed: @MainActor () -> Bool
    private let names: @MainActor () -> FeedNames
    private let messageText: @MainActor (_ connectionID: String, _ messageID: String) -> String?
    /// The item notifications this process posted that may still show.
    private(set) var posted = Set<String>()

    /// [open]: the vault is open on this phone and not held or due (§3.6.3). [visible]: the screen in front; nil when the
    /// app is not active. [allowed]: the member allowed notifications for VettID (the iPhone's Settings decide, and turn
    /// them off). [names] and [messageText]: from the app's in-memory caches.
    public init(
        poster: any NotificationPoster,
        previews: @escaping @MainActor () -> NotificationPreviews,
        open: @escaping @MainActor () -> Bool,
        visible: @escaping @MainActor () -> NotifyVisible?,
        allowed: @escaping @MainActor () -> Bool,
        names: @escaping @MainActor () -> FeedNames,
        messageText: @escaping @MainActor (_ connectionID: String, _ messageID: String) -> String?
    ) {
        self.poster = poster
        self.previews = previews
        self.open = open
        self.visible = visible
        self.allowed = allowed
        self.names = names
        self.messageText = messageText
    }

    /// At launch the vault is not open yet: every item notification still showing outlived the open vault of an earlier
    /// process, and goes (ANDROID-PLAN §4 Notification modes 8).
    public func start() {
        if !open() { poster.removeLeftovers() }
    }

    /// A new or changed unread item (``FeedManager/onArrival``).
    public func arrived(_ item: FeedItem) {
        guard let category = NotificationMapping.category(item), notifiable(item) else { return }
        let p = previews()
        let text: String? = if p == .namesAndText, item.kind == "message.received", let c = item.connectionID, let m = item.ref {
            messageText(c, m)
        } else {
            nil
        }
        var n = NotificationContent.of(item, category: category, previews: p, names: names(), messageText: text)
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

    private func notifiable(_ item: FeedItem) -> Bool {
        allowed() && open() && item.status == FeedManager.statusActive && !shownOnScreen(item)
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
