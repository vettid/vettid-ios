#if os(iOS)
import Foundation
import UserNotifications
import VettIDData

/// What the poster asks of the notification center (`UNUserNotificationCenter`; a fake in tests).
@MainActor
public protocol NotificationCenterOps: AnyObject {
    /// Adds [request]; [landed] is called once the center took it (on its own queue).
    func add(_ request: UNNotificationRequest, landed: @escaping @Sendable () -> Void)
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
    /// The delivered notifications: identifier and `userInfo`.
    func delivered() async -> [(String, [AnyHashable: Any])]
}

extension UNUserNotificationCenter: NotificationCenterOps {
    public func add(_ request: UNNotificationRequest, landed: @escaping @Sendable () -> Void) {
        add(request) { @Sendable _ in landed() }
    }

    public func removePending(_ ids: [String]) { removePendingNotificationRequests(withIdentifiers: ids) }

    public func removeDelivered(_ ids: [String]) { removeDeliveredNotifications(withIdentifiers: ids) }

    public func delivered() async -> [(String, [AnyHashable: Any])] {
        await deliveredNotifications().map { ($0.request.identifier, $0.request.content.userInfo) }
    }
}

/// ``NotificationPoster`` over the notification center (IOS-PLAN §6.7): each notification in its category, with the
/// category's sound (bundled, set here, never from a payload) and level, and its item's `item_id` as identifier and in
/// `userInfo` (the tap's target; the leftovers' mark). An update replaces the one showing without sound. Nothing is logged.
///
/// The center answers adds on its own queue, so the poster keeps each add under way: one removed, or overtaken by a sweep
/// (a lock, a hold, a wipe), while under way goes once it lands; one replaced by a later add of the same identifier is the
/// later add's business. A sweep keeps what it did not ask about: the adds under way and those posted after it began.
@MainActor
public final class SystemNotificationPoster: NotificationPoster {
    /// The `userInfo` key holding a feed item notification's `item_id`.
    public nonisolated static let itemKey = "vettid.feed_item"

    private struct Add {
        let token: Int
        let sweep: Int
    }

    private let center: any NotificationCenterOps
    /// Bumped by each sweep: an add still under way when one ran is removed once it lands.
    private var sweeps = 0
    /// Bumped by each post.
    private var posts = 0
    /// The adds under way, by identifier: the latest add's token and the sweep count when it was asked.
    private var adding: [String: Add] = [:]
    /// Removed while their add was under way.
    private var removedWhileAdding = Set<String>()
    /// The post count when each identifier was last posted (a sweep keeps those posted after it began).
    private var postedAt: [String: Int] = [:]

    public init(center: any NotificationCenterOps = UNUserNotificationCenter.current()) {
        self.center = center
    }

    /// The categories, registered at launch: what the lock screen says while previews are hidden.
    public static var categories: Set<UNNotificationCategory> {
        Set(NotifyCategory.allCases.map { c in
            UNNotificationCategory(
                identifier: c.identifier, actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: c.publicTitle,
                options: []
            )
        })
    }

    /// The feed item a delivered notification opens; nil for any other notification.
    public nonisolated static func itemID(_ userInfo: [AnyHashable: Any]) -> String? { userInfo[itemKey] as? String }

    /// How a notification shows while the app is in the foreground: a banner with its sound, except a passive one (Vault
    /// activity, and an update in place), which goes to the list only.
    public nonisolated static func presentation(_ level: UNNotificationInterruptionLevel) -> UNNotificationPresentationOptions {
        level == .passive ? [.list] : [.banner, .list, .sound]
    }

    public func post(_ n: LocalNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        if let body = n.body { content.body = body }
        content.categoryIdentifier = n.category.identifier
        content.threadIdentifier = n.category.identifier
        if let item = n.itemID { content.userInfo = [Self.itemKey: item] }
        if n.update {
            content.interruptionLevel = .passive
        } else {
            content.sound = n.category.sound.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
            content.interruptionLevel = switch n.category.level {
            case .passive: .passive
            case .active: .active
            case .timeSensitive: .timeSensitive
            }
        }
        let request = UNNotificationRequest(identifier: n.id, content: content, trigger: nil)
        let id = n.id
        posts += 1
        let token = posts
        adding[id] = Add(token: token, sweep: sweeps)
        postedAt[id] = posts
        removedWhileAdding.remove(id)
        // Asked now, in this main-actor job, so that a removal made after it (a lock, "Nothing") reaches the center after the
        // add; the answer comes on the center's own queue and hops back.
        center.add(request) { @Sendable in
            Task { @MainActor [weak self] in self?.added(id, token: token) }
        }
    }

    /// An add landed: if it was removed, or a sweep ran, while it was under way, it goes now (the removal at a lock or a
    /// wipe must not be overtaken by an add it did not see). An earlier add of an identifier posted again is ignored.
    private func added(_ id: String, token: Int) {
        guard let add = adding[id], add.token == token else { return }
        adding[id] = nil
        if removedWhileAdding.remove(id) != nil || add.sweep != sweeps {
            postedAt[id] = nil
            center.removePending([id])
            center.removeDelivered([id])
        }
    }

    public func remove(_ ids: [String]) {
        for id in ids {
            if adding[id] != nil { removedWhileAdding.insert(id) }
            postedAt[id] = nil
        }
        center.removePending(ids)
        center.removeDelivered(ids)
    }

    public func removeLeftovers() {
        sweeps += 1
        let since = posts
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ids = Self.itemIDs(await center.delivered()).filter { id in
                // An add under way is the add's business; one posted after the sweep began is wanted.
                adding[id] == nil && (postedAt[id] ?? 0) <= since
            }
            if !ids.isEmpty { center.removeDelivered(ids) }
        }
    }

    /// The feed item notifications among [delivered] (identifier, `userInfo`): the others are kept.
    nonisolated static func itemIDs(_ delivered: [(String, [AnyHashable: Any])]) -> [String] {
        delivered.filter { itemID($0.1) != nil }.map(\.0)
    }
}
#endif
