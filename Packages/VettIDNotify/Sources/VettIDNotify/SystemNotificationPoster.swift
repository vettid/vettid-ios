#if os(iOS)
import Foundation
import UserNotifications
import VettIDData

/// ``NotificationPoster`` over `UNUserNotificationCenter` (IOS-PLAN §6.7): each notification in its category, with the
/// category's sound (bundled, set here, never from a payload) and level, and its item's `item_id` as identifier and in
/// `userInfo` (the tap's target; the leftovers' mark). An update replaces the one showing without sound. Nothing is logged.
@MainActor
public final class SystemNotificationPoster: NotificationPoster {
    /// The `userInfo` key holding a feed item notification's `item_id`.
    public nonisolated static let itemKey = "vettid.feed_item"

    private let center: UNUserNotificationCenter
    /// Bumped by each sweep: an add still under way when one ran is removed once it lands.
    private var sweeps = 0
    /// The adds under way, with the sweep count when each was asked.
    private var adding: [String: Int] = [:]
    /// Removed while their add was under way.
    private var removedWhileAdding = Set<String>()

    public init(center: UNUserNotificationCenter = .current()) {
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
        adding[id] = sweeps
        removedWhileAdding.remove(id)
        // Asked now, in this main-actor job, so that a removal made after it (a lock, "Nothing") reaches the center after the
        // add; the answer comes on the center's own queue and hops back.
        center.add(request) { @Sendable _ in
            Task { @MainActor [weak self] in self?.added(id) }
        }
    }

    /// An add landed: if it was removed, or a sweep ran, while it was under way, it goes now (the removal at a lock or a
    /// wipe must not be overtaken by an add it did not see).
    private func added(_ id: String) {
        guard let asked = adding.removeValue(forKey: id) else { return }
        if removedWhileAdding.remove(id) != nil || asked != sweeps {
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    public func remove(_ ids: [String]) {
        for id in ids where adding[id] != nil { removedWhileAdding.insert(id) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    public func removeLeftovers() {
        sweeps += 1
        let center = center
        Task { @MainActor in
            let delivered = await center.deliveredNotifications()
            let ids = Self.itemIDs(delivered.map { ($0.request.identifier, $0.request.content.userInfo) })
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// The feed item notifications among [delivered] (identifier, `userInfo`): the others are kept.
    nonisolated static func itemIDs(_ delivered: [(String, [AnyHashable: Any])]) -> [String] {
        delivered.filter { itemID($0.1) != nil }.map(\.0)
    }
}
#endif
