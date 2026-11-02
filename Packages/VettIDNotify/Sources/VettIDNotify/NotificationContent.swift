import Foundation
import VettIDData
import VettIDVault

/// A notification as the app builds it: [id] (an item's `item_id`), the [category], the texts, and the lock screen's
/// [publicTitle]. [names]: it names a connection, a device or an item, so it goes when the vault locks or is held
/// (ANDROID-PLAN §4 Notification modes 8). [itemID]: a tap opens that item. [update]: it replaces one still showing,
/// without sound (vettid-android's `alertOnce`). Built in memory; nothing of it is kept by the app.
public struct LocalNotification: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var id: String
    public var category: NotifyCategory
    public var title: String
    public var body: String?
    public var publicTitle: String
    public var itemID: String?
    public var names = false
    public var update = false

    public init(
        id: String, category: NotifyCategory, title: String, body: String? = nil, publicTitle: String, itemID: String? = nil,
        names: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.body = body
        self.publicTitle = publicTitle
        self.itemID = itemID
        self.names = names
    }

    /// Never the texts: they name people and may hold message text.
    public var description: String { "LocalNotification(\(category.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What a feed item's notification says, by the member's choice of **Show in notifications** (ANDROID-PLAN §4
/// Notification modes 8): ``NotificationPreviews/names`` the connection's "First Last" (or the device) and the kind, never
/// message text, item names or values, tags or amounts; ``NotificationPreviews/namesAndText`` adds the message text
/// (decrypted on the phone) and item names, never values; ``NotificationPreviews/nothing`` "New activity in VettID". The
/// member's email never appears. Mirrors vettid-android `NotificationContent`.
public enum NotificationContent {
    public static func of(
        _ item: FeedItem, category: NotifyCategory, previews: NotificationPreviews, names: FeedNames, messageText: String? = nil
    ) -> LocalNotification {
        let newer = NotificationMapping.needsNewerApp(item) ? NotifyStrings.newerApp : nil
        switch previews {
        case .nothing:
            return LocalNotification(
                id: item.itemID, category: category, title: NotifyStrings.publicActivity, publicTitle: category.publicTitle,
                itemID: item.itemID
            )
        case .names:
            return LocalNotification(
                id: item.itemID, category: category, title: FeedKinds.title(item, names, details: false), body: newer,
                publicTitle: category.publicTitle, itemID: item.itemID, names: true
            )
        case .namesAndText:
            let text = item.kind == "message.received" ? messageText : nil
            return LocalNotification(
                id: item.itemID, category: category, title: FeedKinds.title(item, names),
                body: text ?? newer ?? FeedKinds.supporting(item, names), publicTitle: category.publicTitle, itemID: item.itemID,
                names: true
            )
        }
    }

    /// A received message's text for a notification: the first line that shows something, cleaned and isolated
    /// (VAULT-MESSAGING §10.8 step 6); "Photo" for a photo with nothing to show, "Photo: <caption>" otherwise; nil for a
    /// text with nothing to show. Mirrors vettid-android `notifyMessageText`.
    public static func messageText(_ text: String, photo: Bool) -> String? {
        let line = AccountNames.firstLineIsolated(text)
        guard photo else { return line }
        guard let line else { return NotifyStrings.photo }
        return NotifyStrings.photoCaption(line)
    }
}

/// The texts of the notifications, Android's `core/notify` strings word for word.
enum NotifyStrings {
    static var publicActivity: String { text("notify_public_activity", "New activity in VettID") }
    static var publicAttention: String { text("notify_public_attention", "VettID needs your attention") }
    static var newerApp: String { text("notify_newer_app", "Open VettID on a newer version") }
    static var photo: String { text("notify_photo", "Photo") }
    static func photoCaption(_ caption: String) -> String { String(format: text("notify_photo_caption", "Photo: %@"), caption) }

    private static func text(_ key: String, _ english: String) -> String {
        Bundle.module.localizedString(forKey: key, value: english, table: nil)
    }
}
