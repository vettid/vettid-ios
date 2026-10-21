import Foundation
import Testing
import VettIDMedia
@testable import VettIDSettings

/// The crop math of the review's round frame: the shot always covers the frame, the zoom stays within 1 (fitted) and the
/// most that keeps the crop at least ``ProfilePhotoEncoder/targetSide`` pixels, and the frame maps to exactly one square of
/// the shot whatever its shape and whatever size the frame has on screen. Mirrors vettid-android `PhotoCropTest`.
@Suite struct PhotoCropTests {
    let eps = 1e-3

    func inside(_ r: CropRect, _ w: Int, _ h: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let ok = r.left >= 0 && r.top >= 0 && r.left + r.side <= w && r.top + r.side <= h
        #expect(ok, "\(r) in \(w)×\(h)", sourceLocation: sourceLocation)
    }

    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < eps }

    @Test func theDefaultFramingIsTheCentredSquareOfEveryShape() {
        #expect(PhotoCrop.sourceRect(Framing(), 2048, 1536) == CropRect(256, 0, 1536)) // landscape
        #expect(PhotoCrop.sourceRect(Framing(), 1536, 2304) == CropRect(0, 384, 1536)) // portrait
        #expect(PhotoCrop.sourceRect(Framing(), 900, 900) == CropRect(0, 0, 900)) // square
        #expect(PhotoCrop.sourceRect(Framing(), 3, 5) == CropRect(0, 1, 3)) // odd sides
    }

    @Test func theMostZoomKeepsTheCropAtTheEncodedSide() {
        #expect(near(PhotoCrop.maxZoom(2048, 1536), 3))
        #expect(near(PhotoCrop.maxZoom(1536, 2304), 3))
        #expect(near(PhotoCrop.maxZoom(1280, 960), 1.875))
        // A shot no larger than the encoded side cannot be zoomed at all (it would only be scaled up).
        #expect(near(PhotoCrop.maxZoom(400, 300), 1))
        #expect(near(PhotoCrop.maxZoom(ProfilePhotoEncoder.targetSide, 2000), 1))
        let r = PhotoCrop.sourceRect(Framing(zoom: 100), 2048, 1536)
        #expect(r.side == ProfilePhotoEncoder.targetSide)
        inside(r, 2048, 1536)
    }

    @Test func theZoomIsClampedToFittedAndToTheMost() {
        #expect(near(PhotoCrop.clamp(Framing(zoom: 0.2), 2048, 1536).zoom, 1))
        #expect(near(PhotoCrop.clamp(Framing(zoom: 9), 2048, 1536).zoom, 3))
        #expect(near(PhotoCrop.clamp(Framing(zoom: .nan), 2048, 1536).zoom, 1))
        #expect(near(PhotoCrop.clamp(Framing(zoom: 2), 2048, 1536).zoom, 2))
    }

    @Test func theCentreIsClampedSoTheShotCoversTheFrame() {
        // Fitted on a landscape shot: free left-right within the spare width, fixed top-bottom.
        let f = PhotoCrop.clamp(Framing(zoom: 1, centreX: 0, centreY: 0), 2048, 1536)
        #expect(near(f.centreX, 768.0 / 2048) && near(f.centreY, 0.5))
        #expect(PhotoCrop.sourceRect(f, 2048, 1536) == CropRect(0, 0, 1536))
        let g = PhotoCrop.clamp(Framing(zoom: 1, centreX: 1, centreY: 1), 2048, 1536)
        #expect(PhotoCrop.sourceRect(g, 2048, 1536) == CropRect(512, 0, 1536))
        // Zoomed in 2x: the 768 px square can reach every corner, never past it.
        #expect(PhotoCrop.sourceRect(Framing(zoom: 2, centreX: 1, centreY: 1), 2048, 1536) == CropRect(2048 - 768, 1536 - 768, 768))
        let o = PhotoCrop.sourceRect(Framing(zoom: 2, centreX: -5, centreY: .nan), 2048, 1536)
        #expect(o.left == 0 && o.top == (1536 - 768) / 2)
    }

    @Test func theFrameMapsToTheSameSquareWhateverItsSizeOnScreen() {
        var f = Framing()
        f = PhotoCrop.gesture(f, 2048, 1536, frame: 1000, centroidX: 500, centroidY: 500, panX: 0, panY: 0, zoomChange: 2)
        f = PhotoCrop.gesture(f, 2048, 1536, frame: 1000, centroidX: 500, centroidY: 500, panX: -100, panY: 50, zoomChange: 1)
        let before = PhotoCrop.sourceRect(f, 2048, 1536)
        let small = PhotoCrop.displayScale(f, 2048, 1536, frame: 600)
        let large = PhotoCrop.displayScale(f, 2048, 1536, frame: 1400)
        #expect(near(large / small, 1400.0 / 600))
        #expect(PhotoCrop.sourceRect(f, 2048, 1536) == before)
        // On a frame of 1000 at 2x, 1 point is 768 / 1000 shot pixels: a drag of -100, 50 moves the crop +76.8, -38.4.
        #expect(before == CropRect(640 + 77, 384 - 38, 768))
    }

    @Test func aDragMovesTheShotWithTheFinger() {
        let start = Framing(zoom: 2)
        // Dragging right shows more of the left: the crop's centre moves left.
        let right = PhotoCrop.gesture(start, 2048, 1536, frame: 1000, centroidX: 600, centroidY: 500, panX: 100, panY: 0, zoomChange: 1)
        #expect(right.centreX < start.centreX)
        let down = PhotoCrop.gesture(start, 2048, 1536, frame: 1000, centroidX: 500, centroidY: 600, panX: 0, panY: 100, zoomChange: 1)
        #expect(down.centreY < start.centreY)
        // A drag past the edge stops at it.
        let far = PhotoCrop.gesture(start, 2048, 1536, frame: 1000, centroidX: 500, centroidY: 500, panX: 1e6, panY: 1e6, zoomChange: 1)
        #expect(PhotoCrop.sourceRect(far, 2048, 1536) == CropRect(0, 0, 768))
        // Fitted on a landscape shot, an up-down drag cannot move it (nothing to show).
        let fitted = PhotoCrop.gesture(
            Framing(), 2048, 1536, frame: 1000, centroidX: 500, centroidY: 500, panX: 0, panY: 300, zoomChange: 1
        )
        #expect(near(fitted.centreY, 0.5))
    }

    @Test func aPinchZoomsAboutItsCentroid() {
        // A square shot, the pinch over its top-left quarter's centre: that point stays under the fingers.
        let w = 2000
        let f = PhotoCrop.gesture(Framing(), w, w, frame: 1000, centroidX: 250, centroidY: 250, panX: 0, panY: 0, zoomChange: 2)
        #expect(near(f.zoom, 2))
        #expect(PhotoCrop.sourceRect(f, w, w) == CropRect(250, 250, 1000))
        // Pinching out past fitted stops at fitted, and re-centres within the shot.
        let out = PhotoCrop.gesture(f, w, w, frame: 1000, centroidX: 250, centroidY: 250, panX: 0, panY: 0, zoomChange: 0.1)
        #expect(near(out.zoom, 1))
        #expect(PhotoCrop.sourceRect(out, w, w) == CropRect(0, 0, w))
        // Pinching in past the most stops at the most.
        let most = PhotoCrop.gesture(Framing(), w, w, frame: 1000, centroidX: 500, centroidY: 500, panX: 0, panY: 0, zoomChange: 50)
        #expect(near(most.zoom, PhotoCrop.maxZoom(w, w)))
        // No frame yet (not measured): nothing changes.
        #expect(PhotoCrop.gesture(Framing(), w, w, frame: 0, centroidX: 1, centroidY: 1, panX: 5, panY: 5, zoomChange: 3) == Framing())
    }

    @Test func theZoomButtonsStepAndStopAtTheLimits() {
        var f = PhotoCrop.step(Framing(), 2048, 1536, zoomIn: true)
        #expect(near(f.zoom, PhotoCrop.zoomStep))
        for _ in 0..<20 { f = PhotoCrop.step(f, 2048, 1536, zoomIn: true) }
        #expect(near(f.zoom, 3))
        for _ in 0..<20 { f = PhotoCrop.step(f, 2048, 1536, zoomIn: false) }
        #expect(near(f.zoom, 1))
        #expect(near(PhotoCrop.zoomTo(Framing(), 2048, 1536, zoom: 2.5).zoom, 2.5))
        // A small shot cannot be zoomed by the buttons either.
        #expect(near(PhotoCrop.step(Framing(), 400, 300, zoomIn: true).zoom, 1))
    }

    @Test func aDoubleTapZoomsInThereAndAnotherGoesBack() {
        let f = PhotoCrop.doubleTap(Framing(), 2000, 2000, frame: 1000, x: 250, y: 250)
        #expect(near(f.zoom, PhotoCrop.doubleTapZoom))
        #expect(PhotoCrop.sourceRect(f, 2000, 2000) == CropRect(250, 250, 1000))
        #expect(PhotoCrop.doubleTap(f, 2000, 2000, frame: 1000, x: 10, y: 10) == Framing())
        // At most the allowed zoom (1.875 for a 1280×960 shot).
        #expect(near(PhotoCrop.doubleTap(Framing(), 1280, 960, frame: 1000, x: 500, y: 500).zoom, 1.875))
    }

    @Test func theAccessibilityMovesShiftAQuarterFrameAndOnlyWhereTheyCan() {
        let f = Framing(zoom: 2)
        let left = PhotoCrop.nudge(f, 2048, 1536, dx: -1, dy: 0)
        #expect(near(left.centreX, 0.5 - 0.25 * 768 / 2048))
        #expect(PhotoCrop.canNudge(f, 2048, 1536, dx: 0, dy: -1))
        let corner = Framing(zoom: 2, centreX: 0, centreY: 0)
        #expect(!PhotoCrop.canNudge(corner, 2048, 1536, dx: -1, dy: 0))
        #expect(!PhotoCrop.canNudge(corner, 2048, 1536, dx: 0, dy: -1))
        #expect(PhotoCrop.canNudge(corner, 2048, 1536, dx: 1, dy: 1))
        // Fitted on a landscape shot: left and right only.
        #expect(!PhotoCrop.canNudge(Framing(), 2048, 1536, dx: 0, dy: 1))
        #expect(PhotoCrop.canNudge(Framing(), 2048, 1536, dx: 1, dy: 0))
    }

    @Test func everyFramingMapsInsideTheShot() {
        let shapes = [(2048, 1536), (1536, 2048), (1536, 2304), (1000, 1000), (513, 4000), (300, 200)]
        let values: [Double] = [-1, 0, 0.1, 0.5, 0.9, 1, 2]
        for (w, h) in shapes {
            for z in [0.5, 1, 1.7, 3, 10] {
                for x in values {
                    for y in values {
                        let r = PhotoCrop.sourceRect(Framing(zoom: z, centreX: x, centreY: y), w, h)
                        inside(r, w, h)
                        #expect(r.side >= min(ProfilePhotoEncoder.targetSide, w, h))
                    }
                }
            }
        }
    }
}
