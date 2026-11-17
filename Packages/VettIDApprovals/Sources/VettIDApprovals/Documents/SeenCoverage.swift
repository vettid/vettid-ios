import Foundation

/// How much of a document has been on screen, from its top down, without a gap (VAULT-MESSAGING 0.89.0 §10.4: "Approve
/// is enabled only once the whole of it has been on screen"). It advances only while the part on screen starts at or
/// above what has been seen, so a jump past the middle (to the password field, by keyboard or VoiceOver) does not count,
/// and it starts again whenever the document's height changes (a new text size, a document shown again).
public struct SeenCoverage: Equatable, Sendable {
    /// The document's height the coverage is for.
    public private(set) var height: CGFloat = 0
    /// Seen from the top down to here, in the document's own coordinates.
    public private(set) var seenTo: CGFloat = 0
    /// How far a part on screen may start below what has been seen and still continue it (rounding, one point).
    static let slack: CGFloat = 1

    public init() {}

    /// Whether the whole document has been on screen.
    public var whole: Bool { height > 0 && seenTo >= height - Self.slack }

    /// The part of the document on screen is [visible] (its own coordinates; nil when none) of a document [height] tall.
    public mutating func saw(_ visible: ClosedRange<CGFloat>?, height h: CGFloat) {
        if abs(h - height) > Self.slack {
            height = h
            seenTo = 0
        }
        guard let visible, visible.lowerBound <= seenTo + Self.slack else { return }
        seenTo = max(seenTo, min(visible.upperBound, height))
    }
}
