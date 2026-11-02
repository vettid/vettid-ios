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
    /// The wait for the tapped item to reach the feed is over (it came, or the time ran out): the shell decides again, with
    /// what is in front then.
    public private(set) var waitOver = false
    @ObservationIgnored private var waiting = false

    public init() {}

    public func offer(_ itemID: String) {
        // The same item tapped again while it waits: the wait under way stands.
        guard itemID != self.itemID else { return }
        self.itemID = itemID
        waitOver = false
        waiting = false
    }

    /// True once per tap: the caller starts the one wait for its item.
    public func startWaiting() -> Bool {
        guard itemID != nil, !waiting, !waitOver else { return false }
        waiting = true
        return true
    }

    /// The wait for [itemID] ended; ignored when another tap has replaced it or it was taken.
    public func waitEnded(for itemID: String) {
        guard self.itemID == itemID, waiting else { return }
        waiting = false
        waitOver = true
    }

    /// The shell left (the vault locked, a check took its place): a tap still waiting keeps its item, and its item is
    /// waited for again when the shell is back, since the feed is read again then.
    public func rearm() {
        waitOver = false
        waiting = false
    }

    public func consume() {
        itemID = nil
        waitOver = false
        waiting = false
    }

    public nonisolated var description: String { "NotificationOpenInbox(…)" }
    public nonisolated var debugDescription: String { description }
}
