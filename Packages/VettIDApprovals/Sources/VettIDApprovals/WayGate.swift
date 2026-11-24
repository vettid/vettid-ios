import Foundation

/// The scroll gate before Approve of a run or a proxy (ANDROID-PLAN 0.1.137 AA8): **Approve** stays disabled until the content has
/// been scrolled to its end, and once reached it stays reached while the member scrolls back up. Re-armed when what is shown
/// changes (``WayKey``), not by the member's own taps. Content that fits counts as reached, judged from the laid-out geometry,
/// never from a first measure. Pure; the screen feeds it readings. Mirrors vettid-android's `Gate` and `endReached`, which scroll
/// to the top first and only then observe.
public struct WayGate: Equatable, Sendable {
    /// The shown content this gate was armed for (its ``WayKey``).
    public private(set) var key: String
    public private(set) var reached = false
    /// A reading of this content at its top was seen since it was armed: only readings after that count, so that an offset or an
    /// end measured before the screen went back to the top (the old content's) never marks the new content as reached.
    private var sawTop = false

    public init(key: String) { self.key = key }

    /// A reading measured for the content [key]: the top marker's position [top] and the end of the last element [end] (its bottom
    /// edge), in the scrolled area's coordinates, in an area of height [viewport] that ends above the buttons and inside the safe
    /// area. A nil `top` or `end` is not laid out. A reading for another key is ignored.
    public mutating func update(key: String, top: Double?, end: Double?, viewport: Double) {
        guard key == self.key, viewport > 0 else { return }
        if !sawTop {
            guard let top, Self.atTop(top) else { return }
            sawTop = true
        }
        if let end, Self.endReached(end: end, viewport: viewport) { reached = true }
    }

    /// What is shown changed: the gate is armed again for [key]. The same key changes nothing.
    public mutating func rearm(_ key: String) {
        guard key != self.key else { return }
        self.key = key
        reached = false
        sawTop = false
    }

    /// Pure: the bottom edge ([end]) is inside the area of height [viewport], to a half point.
    public static func endReached(end: Double, viewport: Double) -> Bool { end <= viewport + 0.5 }

    /// Pure: the top marker is at the top of the area, to a point.
    public static func atTop(_ top: Double) -> Bool { abs(top) <= 1 }
}
