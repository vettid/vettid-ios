import Foundation

/// The scroll gate before Approve of a run or a proxy (ANDROID-PLAN 0.1.137 AA8): **Approve** stays disabled until the content has
/// been scrolled to its end, and once reached it stays reached while the member scrolls back up. Re-armed when what is shown
/// changes (``WayKey``), not by the member's own taps. Content that fits counts as reached, judged from the laid-out geometry,
/// never from a first measure. Pure; the screen feeds it the geometry. Mirrors vettid-android's `Gate` and `endReached`.
public struct WayGate: Equatable, Sendable {
    /// The shown content this gate was armed for (its ``WayKey``).
    public private(set) var key: String
    public private(set) var reached = false
    private var lastEnd: Double?
    private var lastViewport: Double?

    public init(key: String) { self.key = key }

    /// The end of the last element is at [end] (its bottom edge, in the scrolled area's coordinates) in a scrolled area of height
    /// [viewport], which ends above the buttons and inside the safe area. The laid-out geometry first (a nil `end` is not laid out).
    public mutating func update(end: Double?, viewport: Double) {
        lastEnd = end
        lastViewport = viewport
        rejudge()
    }

    /// Judges the geometry last seen again (after the content changed and was laid out).
    public mutating func rejudge() {
        guard let end = lastEnd, let viewport = lastViewport, viewport > 0 else { return }
        if Self.endReached(end: end, viewport: viewport) { reached = true }
    }

    /// What is shown changed: the gate is armed again for [key]; the geometry last seen is the old content's, so it is judged
    /// again (``rejudge()``) once the new content is laid out. The same key changes nothing.
    public mutating func rearm(_ key: String) {
        guard key != self.key else { return }
        self.key = key
        reached = false
        lastEnd = nil
    }

    /// Pure: the bottom edge ([end]) is inside the area of height [viewport], to a half point.
    public static func endReached(end: Double, viewport: Double) -> Bool { end <= viewport + 0.5 }
}
