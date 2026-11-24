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

    /// A reading, with the key of the content it was measured for: kept, so that one that arrives before the gate is armed for its
    /// key (the layout of the new content comes before the change of key is seen) is judged when it is armed.
    private struct Reading: Equatable, Sendable {
        var key: String
        var top: Double?
        var end: Double?
        var visibleTop: Double
        var visibleBottom: Double
    }

    private var last: Reading?

    public init(key: String) { self.key = key }

    /// A reading measured for the content [key]: the top marker's position [top] and the end of the last element [end] (its bottom
    /// edge), in the scrolled area's coordinates. [visibleTop] and [visibleBottom] bound what the member sees of the area: its top
    /// and bottom insets (a bar or the safe area the content scrolls under) are outside them, and the top marker rests at
    /// [visibleTop]. A nil `top` or `end` is not laid out. A reading for another key waits for the gate to be armed for it.
    public mutating func update(key: String, top: Double?, end: Double?, visibleTop: Double, visibleBottom: Double) {
        last = Reading(key: key, top: top, end: end, visibleTop: visibleTop, visibleBottom: visibleBottom)
        judge()
    }

    /// The area's insets or height changed (a rotation): the last reading is judged against the new bounds.
    public mutating func area(visibleTop: Double, visibleBottom: Double) {
        guard var l = last else { return }
        l.visibleTop = visibleTop
        l.visibleBottom = visibleBottom
        last = l
        judge()
    }

    private mutating func judge() {
        guard let l = last, l.key == key, l.visibleBottom > l.visibleTop else { return }
        if !sawTop {
            guard let top = l.top, Self.atTop(top, visibleTop: l.visibleTop) else { return }
            sawTop = true
        }
        if let end = l.end, Self.endReached(end: end, visibleBottom: l.visibleBottom) { reached = true }
    }

    /// What is shown changed: the gate is armed again for [key], and a reading kept for that key is judged at once (content that
    /// fits needs no further reading). The same key changes nothing.
    public mutating func rearm(_ key: String) {
        guard key != self.key else { return }
        self.key = key
        reached = false
        sawTop = false
        judge()
    }

    /// Pure: the bottom edge ([end]) is inside the visible area, to a half point.
    public static func endReached(end: Double, visibleBottom: Double) -> Bool { end <= visibleBottom + 0.5 }

    /// Pure: the top marker is at the top of the visible area (where it rests), to a point.
    public static func atTop(_ top: Double, visibleTop: Double = 0) -> Bool { abs(top - visibleTop) <= 1 }
}
