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
        center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
    }

    public func remove(_ ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    public func removeLeftovers() {
        let center = center
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { Self.itemID($0.request.content.userInfo) != nil }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}
#endif
