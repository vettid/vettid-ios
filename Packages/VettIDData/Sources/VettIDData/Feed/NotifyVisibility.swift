import Foundation
import Observation

/// The screen in front as the notifications see it (ANDROID-PLAN §4 Notification modes 7, "none"): the Notifications
/// list, or a screen a feed item opens. Mirrors vettid-android `Visible`.
public enum NotifyVisible: Equatable, Sendable {
    case notifications
    case target(FeedTarget)
}

/// Where the open app's shell says which screen is in front; nil when no shell is shown or the app is not active.
/// Mirrors vettid-android `NotifyVisibility`.
@MainActor
@Observable
public final class NotifyVisibility {
    public private(set) var visible: NotifyVisible?

    public init() {}

    public func set(_ v: NotifyVisible?) {
        if v != visible { visible = v }
    }
}

/// A notification's tap, handed from the notification center's delegate to the open app's shell: the feed item to open.
/// The shell takes it only once the app lock, the unlock and the daily check are passed (it exists only then). Never
/// stored. Mirrors vettid-android `NotificationOpenInbox` (its `Item`).
@MainActor
@Observable
public final class NotificationOpenInbox: CustomStringConvertible, CustomDebugStringConvertible {
    public private(set) var itemID: String?

    public init() {}

    public func offer(_ itemID: String) { self.itemID = itemID }

    public func consume() { itemID = nil }

    public nonisolated var description: String { "NotificationOpenInbox(…)" }
    public nonisolated var debugDescription: String { description }
}
