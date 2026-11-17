import Foundation

/// How much of a document has been on screen, from its top down without a gap (VAULT-MESSAGING 0.89.0 §10.4: "Approve
/// is enabled only once the whole of it has been on screen"). Every part that comes on screen is kept, in any order, and
/// the coverage is what they join into from the top: a jump past the middle (to the password field, by keyboard or
/// VoiceOver) leaves a gap until the middle has been on screen too. A change of the document's height (another text size,
/// a document shown again) starts again.
public struct SeenCoverage: Equatable, Sendable {
    /// The document's height the coverage is for.
    public private(set) var height: CGFloat = 0
    /// The parts seen, merged, in order.
    public private(set) var seen: [ClosedRange<CGFloat>] = []
    /// How far apart two parts may be and still join (rounding, one point).
    static let slack: CGFloat = 1

    public init() {}

    /// Seen from the top down to here, without a gap.
    public var seenTo: CGFloat {
        guard let first = seen.first, first.lowerBound <= Self.slack else { return 0 }
        return first.upperBound
    }

    /// Whether the whole document has been on screen.
    public var whole: Bool { height > 0 && seenTo >= height - Self.slack }

    /// The part of the document on screen is [visible] (its own coordinates; nil when none) of a document [h] tall.
    public mutating func saw(_ visible: ClosedRange<CGFloat>?, height h: CGFloat) {
        if abs(h - height) > Self.slack {
            height = h
            seen = []
        }
        guard let visible else { return }
        let part = max(visible.lowerBound, 0)...max(min(visible.upperBound, height), max(visible.lowerBound, 0))
        var merged: [ClosedRange<CGFloat>] = []
        for r in (seen + [part]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound + Self.slack {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        seen = merged
    }
}
