import Foundation
import VettIDMedia

/// How the shot sits under the review's round frame. Normalised, so it survives a change of the frame's size on screen
/// (the crop does not change): [zoom] is 1 when the shot's shorter side just fills the frame and grows as the member
/// zooms in; [centreX] and [centreY] are the crop's centre as fractions of the shot's width and height. Mirrors
/// vettid-android `Framing`.
public struct Framing: Equatable, Sendable {
    public var zoom: Double
    public var centreX: Double
    public var centreY: Double

    public init(zoom: Double = 1, centreX: Double = 0.5, centreY: Double = 0.5) {
        self.zoom = zoom
        self.centreX = centreX
        self.centreY = centreY
    }

    /// The default framing: centred, the shot fitted to the frame.
    public var isDefault: Bool { self == Framing() }
}

/// A square of the shot, in its pixels from the top left: what "Use photo" keeps. Mirrors vettid-android `CropRect`.
public struct CropRect: Equatable, Sendable, CustomStringConvertible {
    public var left: Int
    public var top: Int
    public var side: Int

    public init(_ left: Int, _ top: Int, _ side: Int) {
        self.left = left
        self.top = top
        self.side = side
    }

    public var rect: CGRect { CGRect(x: left, y: top, width: side, height: side) }

    public var description: String { "CropRect(\(left), \(top), \(side))" }
}

// swiftlint:disable function_parameter_count
/// The crop math of the review step, pure. The frame is a square (the circle drawn in it, as the avatar is shown); the
/// shot always covers it: never zoomed out past its shorter side, never panned off an edge, and never zoomed in so far
/// that the square under the frame is smaller than ``ProfilePhotoEncoder/targetSide`` (it would be scaled up into blur).
/// Mirrors vettid-android `PhotoCrop` (its signatures: the shot's sides and the frame's geometry as separate values).
public enum PhotoCrop {
    /// One press of "Zoom in" or "Zoom out".
    public static let zoomStep = 1.25
    /// Double-tap zooms to this (or the most allowed).
    public static let doubleTapZoom = 2.0
    /// One accessibility "Move" step: this fraction of the frame.
    public static let nudgeStep = 0.25

    static let epsilon = 1e-3
    static let middle = 0.5

    /// The most a shot of [w]×[h] can be zoomed in (1: not at all, when it is no larger than [target]).
    public static func maxZoom(_ w: Int, _ h: Int, target: Int = ProfilePhotoEncoder.targetSide) -> Double {
        max(1, Double(min(w, h)) / Double(target))
    }

    /// [f] made valid for a shot of [w]×[h]: the zoom within 1...``maxZoom(_:_:target:)``, the centre so that the shot
    /// covers the frame.
    public static func clamp(_ f: Framing, _ w: Int, _ h: Int) -> Framing {
        let most = maxZoom(w, h)
        let zoom = f.zoom.isNaN ? 1 : min(max(f.zoom, 1), most)
        let side = Double(min(w, h)) / zoom
        return Framing(zoom: zoom, centreX: centre(f.centreX, side / 2 / Double(w)), centreY: centre(f.centreY, side / 2 / Double(h)))
    }

    private static func centre(_ c: Double, _ half: Double) -> Double {
        let lo = min(half, middle)
        return c.isNaN ? middle : min(max(c, lo), 1 - lo)
    }

    /// Kotlin's `roundToInt` (half up), so that the crop is the same pixel for pixel as vettid-android's.
    static func round(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }

    /// The square of the shot under the frame, in its pixels (always inside the shot).
    public static func sourceRect(_ f: Framing, _ w: Int, _ h: Int) -> CropRect {
        let c = clamp(f, w, h)
        let short = min(w, h)
        let side = min(max(round(Double(short) / c.zoom), 1), short)
        let left = min(max(round(c.centreX * Double(w) - Double(side) / 2), 0), w - side)
        let top = min(max(round(c.centreY * Double(h) - Double(side) / 2), 0), h - side)
        return CropRect(left, top, side)
    }

    /// Screen points per shot pixel, for a frame [frame] points wide.
    public static func displayScale(_ f: Framing, _ w: Int, _ h: Int, frame: Double) -> Double {
        frame * clamp(f, w, h).zoom / Double(min(w, h))
    }

    /// A pinch or a drag over a frame [frame] points wide: the point of the shot that was under the previous centroid
    /// (`centroid - pan`) ends up under [centroidX], [centroidY] at the new zoom.
    public static func gesture(
        _ f: Framing, _ w: Int, _ h: Int, frame: Double, centroidX: Double, centroidY: Double, panX: Double, panY: Double,
        zoomChange: Double
    ) -> Framing {
        guard frame > 0 else { return clamp(f, w, h) }
        let old = clamp(f, w, h)
        let scale = displayScale(old, w, h, frame: frame)
        let qx = old.centreX * Double(w) + (centroidX - panX - frame / 2) / scale
        let qy = old.centreY * Double(h) + (centroidY - panY - frame / 2) / scale
        let zoom = min(max(old.zoom * zoomChange, 1), maxZoom(w, h))
        let newScale = frame * zoom / Double(min(w, h))
        let cx = qx - (centroidX - frame / 2) / newScale
        let cy = qy - (centroidY - frame / 2) / newScale
        return clamp(Framing(zoom: zoom, centreX: cx / Double(w), centreY: cy / Double(h)), w, h)
    }

    /// The zoom set to [zoom], about the frame's centre (the slider).
    public static func zoomTo(_ f: Framing, _ w: Int, _ h: Int, zoom: Double) -> Framing {
        var g = f
        g.zoom = zoom
        return clamp(g, w, h)
    }

    /// "Zoom in" ([zoomIn]) or "Zoom out" by ``zoomStep``, about the frame's centre.
    public static func step(_ f: Framing, _ w: Int, _ h: Int, zoomIn: Bool) -> Framing {
        zoomTo(f, w, h, zoom: clamp(f, w, h).zoom * (zoomIn ? zoomStep : 1 / zoomStep))
    }

    /// Double-tap at [x], [y] of a frame [frame] points wide: zoomed in, back to the default; else zoomed in there.
    public static func doubleTap(_ f: Framing, _ w: Int, _ h: Int, frame: Double, x: Double, y: Double) -> Framing {
        let c = clamp(f, w, h)
        if c.zoom > 1 + epsilon || maxZoom(w, h) <= 1 + epsilon { return Framing() }
        let target = min(doubleTapZoom, maxZoom(w, h))
        return gesture(c, w, h, frame: frame, centroidX: x, centroidY: y, panX: 0, panY: 0, zoomChange: target / c.zoom)
    }

    /// An accessibility "Move": the view shifts by [dx], [dy] steps of ``nudgeStep`` of the frame (+x: shows more to the
    /// right).
    public static func nudge(_ f: Framing, _ w: Int, _ h: Int, dx: Int, dy: Int) -> Framing {
        let c = clamp(f, w, h)
        let side = Double(min(w, h)) / c.zoom
        var g = c
        g.centreX += Double(dx) * nudgeStep * side / Double(w)
        g.centreY += Double(dy) * nudgeStep * side / Double(h)
        return clamp(g, w, h)
    }

    /// The shot can be moved that way (an accessibility action is offered only then).
    public static func canNudge(_ f: Framing, _ w: Int, _ h: Int, dx: Int, dy: Int) -> Bool {
        nudge(f, w, h, dx: dx, dy: dy) != clamp(f, w, h)
    }
}
// swiftlint:enable function_parameter_count
