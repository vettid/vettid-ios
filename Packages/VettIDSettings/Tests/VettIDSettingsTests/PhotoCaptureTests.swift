import CoreGraphics
import Foundation
import ImageIO
import Testing
import VettIDMedia
@testable import VettIDSettings

/// The profile photo is taken with the in-app camera, never chosen: the capture's state machine (permission, cameras,
/// shutter, retake, use, the round frame) and the encoding the shot goes through (VAULT-MESSAGING §10.8: a JPEG of at most
/// 65,536 bytes without EXIF). Mirrors vettid-android `PhotoCaptureTest` (the machine and the encoding; the screens are
/// VettIDSettingsUITests').
@MainActor
@Suite struct PhotoCaptureTests {
    /// Grey, with a red top-left quarter when [marked].
    nonisolated static func picture(_ w: Int, _ h: Int, marked: Bool = false) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if marked {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            // CoreGraphics draws from the bottom left: the top-left quarter is the upper half's left.
            ctx.fill(CGRect(x: 0, y: Double(h) / 2, width: Double(w) / 2, height: Double(h) / 2))
        }
        return ctx.makeImage()!
    }

    /// A picture of noise (the worst case for JPEG).
    nonisolated static func noise(_ w: Int, _ h: Int) -> CGImage {
        var state: UInt64 = 3
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            px[i] = UInt8(truncatingIfNeeded: state >> 24)
            px[i + 1] = UInt8(truncatingIfNeeded: state >> 32)
            px[i + 2] = UInt8(truncatingIfNeeded: state >> 40)
        }
        let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return ctx.makeImage()!
    }

    func shot(_ w: Int = 40, _ h: Int = 30, marked: Bool = false) throws -> ShotImage {
        try ShotImage.of(Self.picture(w, h, marked: marked))
    }

    func granted() -> PhotoCaptureMachine {
        let m = PhotoCaptureMachine()
        m.access(.granted)
        return m
    }

    func reviewing(_ w: Int = 2048, _ h: Int = 1536) throws -> (PhotoCaptureMachine, ShotImage) {
        let m = granted()
        _ = m.shutter()
        let s = try shot(w, h)
        m.shot(s)
        return (m, s)
    }

    /// A decoded JPEG's pixel and size.
    struct Pixel {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let w: Int
        let h: Int
    }

    /// The decoded JPEG's pixel at [x], [y] from the top left, as RGB.
    static func pixel(_ jpeg: [UInt8], _ x: Int, _ y: Int) throws -> Pixel {
        let image = try Photos.decodeReceived(jpeg, targetLongEdge: 512)
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(
                data: p.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = (y * image.width + x) * 4
        return Pixel(r: buf[i], g: buf[i + 1], b: buf[i + 2], w: image.width, h: image.height)
    }

    // MARK: - The state machine

    @Test func theFrontCameraIsFirstAndNothingIsTakenWithoutThePermission() {
        let m = PhotoCaptureMachine()
        #expect(m.state.lens == .front && !m.state.live)
        #expect(!m.shutter())
        m.access(.blocked)
        #expect(!m.shutter() && !m.state.canSwitch)
        m.access(.granted)
        #expect(m.state.live)
        #expect(m.shutter())
        #expect(m.state.step == .taking)
    }

    @Test func theLensSwitchesBothWaysOnlyWhenThePhoneHasBoth() {
        let m = granted()
        m.lenses(front: true, back: true)
        m.switchLens()
        #expect(m.state.lens == .back)
        m.switchLens()
        #expect(m.state.lens == .front)
        m.lenses(front: true, back: false)
        #expect(!m.state.canSwitch)
        m.switchLens()
        #expect(m.state.lens == .front)
    }

    @Test func aPhoneWithoutAFrontCameraUsesTheRearOneAndOneWithoutAnyHasNoCamera() {
        let m = granted()
        m.lenses(front: false, back: true)
        #expect(m.state.lens == .back && !m.state.noCamera)
        m.lenses(front: false, back: false)
        #expect(m.state.noCamera)
        #expect(!m.shutter())
        let n = granted()
        n.unavailable()
        #expect(n.state.noCamera && !n.state.live)
    }

    @Test func aShotIsReviewedThenRetakenOrUsed() throws {
        let m = granted()
        #expect(m.shutter())
        #expect(!m.shutter(), "one picture at a time")
        let first = try shot()
        m.shot(first)
        #expect(m.state.step == .review && m.state.shot === first && !m.state.canSwitch)
        m.retake()
        #expect(m.state.step == .live && m.state.shot == nil)
        #expect(first.isWiped, "dropped and zeroed, not kept anywhere")
        #expect(m.shutter())
        let second = try shot()
        m.shot(second)
        #expect(m.use()?.shot === second)
        #expect(!second.isWiped, "handed over to the encoder")
        #expect(m.state.shot == nil && m.use() == nil)
    }

    @Test func aFailedShotSaysSoAndALateOneIsDropped() throws {
        let m = granted()
        _ = m.shutter()
        m.shot(nil)
        #expect(m.state.step == .live && m.state.failed)
        let late = try shot()
        m.shot(late) // no shutter pressed
        #expect(m.state.shot == nil && late.isWiped)
    }

    @Test func resetKeepsThePermissionAndDropsTheShot() throws {
        let m = granted()
        m.lenses(front: true, back: true)
        m.switchLens()
        _ = m.shutter()
        let s = try shot()
        m.shot(s)
        m.reset()
        #expect(m.state == PhotoCaptureState(access: .granted))
        #expect(s.isWiped)
    }

    // MARK: - The round frame

    @Test func theFramingIsClampedAndResetRestoresTheDefault() throws {
        let (m, _) = try reviewing()
        #expect(m.state.framing == Framing() && abs(m.state.maxZoom - 3) < 1e-3)
        m.frame { _, _, _ in Framing(zoom: 9, centreX: -1, centreY: 2) }
        #expect(abs(m.state.framing.zoom - 3) < 1e-3)
        #expect(PhotoCrop.sourceRect(m.state.framing, 2048, 1536) == CropRect(0, 1536 - 512, 512))
        m.resetFraming()
        #expect(m.state.framing == Framing() && m.state.step == .review, "Reset keeps the shot")
    }

    @Test func retakeAndANewShotStartFromTheDefaultFraming() throws {
        let (m, first) = try reviewing()
        m.frame { f, w, h in PhotoCrop.zoomTo(f, w, h, zoom: 2) }
        m.retake()
        #expect(first.isWiped && m.state.framing == Framing())
        // No shot under review: the framing cannot change.
        m.frame { _, _, _ in Framing(zoom: 2) }
        #expect(m.state.framing == Framing())
        _ = m.shutter()
        m.shot(try shot(2048, 1536))
        #expect(m.state.framing == Framing())
    }

    @Test func useHandsOverTheSquareUnderTheFrame() throws {
        let (m, s) = try reviewing()
        m.frame { f, w, h in PhotoCrop.zoomTo(f, w, h, zoom: 2) }
        let sel = try #require(m.use())
        #expect(sel.shot === s && sel.crop == CropRect(640, 384, 768))
        #expect(m.state.framing == Framing() && m.state.step == .live)
    }

    // MARK: - The encoding (VAULT-MESSAGING §10.8)

    @Test func theShotIsEncodedAsASquareJpegWithinTheLimitWithoutExif() throws {
        let big = try ShotImage.of(Self.noise(1600, 1200))
        let b64 = try #require(encodeShot(.centred(big)))
        let bytes = try #require(Data(base64Encoded: b64).map { [UInt8]($0) })
        #expect(bytes.count <= 65_536, "\(bytes.count) bytes")
        #expect(ImageType.sniff(bytes) == .jpeg)
        // A JPEG re-encoded from pixels: no EXIF (APP1) segment, nor any other metadata.
        #expect(!(bytes[2] == 0xFF && bytes[3] == 0xE1))
        #expect(!JpegSegments.hasMetadata(bytes))
        let src = try #require(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        #expect(props[kCGImagePropertyExifDictionary] == nil && props[kCGImagePropertyGPSDictionary] == nil)
        let p = try Self.pixel(bytes, 0, 0)
        #expect(p.w == p.h)
        #expect(big.isWiped, "the shot is zeroed once encoded")
    }

    /// A grey shot with a red top-left quarter: zoomed and moved onto it, "Use photo" keeps red only.
    @Test func usePhotoEncodesTheSelectedRegion() throws {
        // Default framing: the centred square, mostly grey.
        let plain = granted()
        _ = plain.shutter()
        plain.shot(try shot(2048, 1536, marked: true))
        let plainSelection = try #require(plain.use())
        let centred = try #require(encodeShot(plainSelection))
        let centredBytes = try #require(Data(base64Encoded: centred).map { [UInt8]($0) })
        let c = try Self.pixel(centredBytes, 384, 384)
        #expect((100...160).contains(c.r) && (100...160).contains(c.g))
        // Zoomed 2x (a 768 px square) and dragged to the top-left corner: all red.
        let m = granted()
        _ = m.shutter()
        let s = try shot(2048, 1536, marked: true)
        m.shot(s)
        m.frame { f, w, h in PhotoCrop.gesture(f, w, h, frame: 1000, centroidX: 500, centroidY: 500, panX: 0, panY: 0, zoomChange: 2) }
        m.frame { f, w, h in
            PhotoCrop.gesture(f, w, h, frame: 1000, centroidX: 500, centroidY: 500, panX: 5000, panY: 5000, zoomChange: 1)
        }
        let sel = try #require(m.use())
        #expect(sel.crop == CropRect(0, 0, 768))
        let b64 = try #require(encodeShot(sel))
        #expect(s.isWiped)
        let bytes = try #require(Data(base64Encoded: b64).map { [UInt8]($0) })
        #expect(bytes.count <= 65_536 && !JpegSegments.hasMetadata(bytes))
        for (x, y) in [(4, 4), (256, 256), (500, 500)] {
            let p = try Self.pixel(bytes, x, y)
            #expect(p.r > 200 && p.g < 60, "red at \(x), \(y)")
        }
    }
}
