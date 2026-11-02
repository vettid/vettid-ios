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
    /// The wait under way, by its token; nil when none is. Each wait gets a new token, so an earlier wait's end (a tap
    /// replaced, the shell gone and back) changes nothing.
    @ObservationIgnored private var waiting: Int?
    @ObservationIgnored private var tokens = 0
    /// When the tap waiting was made.
    @ObservationIgnored private var offeredAt: Date?
    @ObservationIgnored private let now: @MainActor () -> Date

    /// How long a tap waits for the shell (an app lock or a vault unlock left for later): after it, it is dropped, so
    /// that a tap from long before never opens a screen by itself (IOS-PLAN §4.12).
    public static let maxWait: TimeInterval = 600

    public init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    public func offer(_ itemID: String) {
        // The same item tapped again while it waits: the wait under way stands, from this tap.
        offeredAt = now()
        guard itemID != self.itemID else { return }
        self.itemID = itemID
        waitOver = false
        waiting = nil
    }

    /// The tap waiting is older than ``maxWait``.
    public var isStale: Bool {
        guard itemID != nil, let offeredAt else { return false }
        return now().timeIntervalSince(offeredAt) > Self.maxWait
    }

    /// A token once per tap (and again after ``rearm()``): the caller starts the one wait for its item; nil otherwise.
    public func startWaiting() -> Int? {
        guard itemID != nil, waiting == nil, !waitOver else { return nil }
        tokens += 1
        waiting = tokens
        return tokens
    }

    /// Whether the wait [token] is still the one under way.
    public func isWaiting(_ token: Int) -> Bool { waiting == token }

    /// The wait [token] ended; ignored when it is no longer the one under way.
    public func waitEnded(_ token: Int) {
        guard waiting == token else { return }
        waiting = nil
        waitOver = true
    }

    /// The shell left (the vault locked, a check took its place): a tap still waiting keeps its item, and its item is
    /// waited for again when the shell is back, since the feed is read again then.
    public func rearm() {
        waitOver = false
        waiting = nil
    }

    public func consume() {
        offeredAt = nil
        itemID = nil
        waitOver = false
        waiting = nil
    }

    public nonisolated var description: String { "NotificationOpenInbox(…)" }
    public nonisolated var debugDescription: String { description }
}
