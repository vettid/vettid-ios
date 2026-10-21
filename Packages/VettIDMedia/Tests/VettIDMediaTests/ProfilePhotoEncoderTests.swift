import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VettIDMedia

/// The profile photo (VAULT-MESSAGING §10.8): encoded from the kept square to a JPEG of at most 65,536 bytes without
/// EXIF or any other metadata; the camera's shot decoded upright into pixels that are zeroed in place. Mirrors vettid-android
/// `ProfilePhotosTest` (the encoding) and the shot part of `PhotoCaptureTest`.
@Suite struct ProfilePhotoEncoderTests {
    /// A picture of noise, the worst case for JPEG: the encoder must lower quality and size to fit.
    static func noise(_ w: Int, _ h: Int, seed: UInt64 = 7) -> CGImage {
        var state = seed
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            px[i] = UInt8(truncatingIfNeeded: state >> 24)
            px[i + 1] = UInt8(truncatingIfNeeded: state >> 32)
            px[i + 2] = UInt8(truncatingIfNeeded: state >> 40)
            px[i + 3] = 255
        }
        let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return ctx.makeImage()!
    }

    /// Grey with a red top-left quarter.
    static func marked(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        // CoreGraphics draws from the bottom left: the top-left quarter is the upper half's left.
        ctx.fill(CGRect(x: 0, y: Double(h) / 2, width: Double(w) / 2, height: Double(h) / 2))
        return ctx.makeImage()!
    }

    static func size(_ jpeg: [UInt8]) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func decoded(_ jpeg: [UInt8]) throws -> CGImage { try Photos.decodeReceived(jpeg, targetLongEdge: 512) }

    /// No EXIF (APP1 `Exif`), XMP, IPTC or MPF segment, and ImageIO reads no EXIF, TIFF or GPS dictionary back.
    static func expectNoMetadata(_ jpeg: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!JpegSegments.hasMetadata(jpeg), sourceLocation: sourceLocation)
        let exif = (0..<max(0, jpeg.count - 8)).contains { i in
            jpeg[i] == 0xFF && jpeg[i + 1] == 0xE1 && jpeg[(i + 4)..<(i + 8)].elementsEqual(Array("Exif".utf8))
        }
        #expect(!exif, sourceLocation: sourceLocation)
        let src = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil)
        let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        #expect(props[kCGImagePropertyExifDictionary] == nil, sourceLocation: sourceLocation)
        #expect(props[kCGImagePropertyGPSDictionary] == nil, sourceLocation: sourceLocation)
        #expect(props[kCGImagePropertyTIFFDictionary] == nil, sourceLocation: sourceLocation)
    }

    // MARK: - The encoding

    @Test func aLargePictureFitsTheLimitAsASquareJpegWithoutMetadata() throws {
        let out = try ProfilePhotoEncoder.encode(Self.noise(3000, 2000))
        #expect(out.count <= 65_536, "\(out.count) bytes")
        #expect(ImageType.sniff(out) == .jpeg)
        let (w, h) = try #require(Self.size(out))
        #expect(w == h && w <= ProfilePhotoEncoder.targetSide)
        Self.expectNoMetadata(out)
    }

    @Test func aSmallLimitIsMetBySmallerSides() throws {
        let out = try ProfilePhotoEncoder.encode(Self.noise(1200, 1600), maxBytes: 8_000)
        #expect(out.count <= 8_000, "\(out.count) bytes")
        let (w, _) = try #require(Self.size(out))
        #expect(w < ProfilePhotoEncoder.targetSide)
    }

    @Test func aLimitNothingFitsIsRefused() {
        #expect(throws: PhotoError(.cannotFit)) { try ProfilePhotoEncoder.encode(Self.noise(600, 600), maxBytes: 100) }
    }

    @Test func theDefaultCropIsTheCentredSquare() throws {
        #expect(ProfilePhotoEncoder.centreSquare(300, 100) == CGRect(x: 100, y: 0, width: 100, height: 100))
        #expect(ProfilePhotoEncoder.centreSquare(3, 5) == CGRect(x: 0, y: 1, width: 3, height: 3))
        // Red left, blue middle third, red right: the centred square is blue only.
        let ctx = CGContext(
            data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let out = try Self.decoded(try ProfilePhotoEncoder.encode(ctx.makeImage()!))
        #expect(out.width == out.height)
        #expect(TestImages.isBlue(TestImages.pixel(out, 2, 2)) && TestImages.isBlue(TestImages.pixel(out, out.width - 3, out.height - 3)))
    }

    /// The kept square is exactly what is encoded: from the top left, in the picture's pixels.
    @Test func theKeptSquareIsWhatIsEncoded() throws {
        let image = Self.marked(2048, 1536)
        let red = try Self.decoded(try ProfilePhotoEncoder.encode(image, crop: CGRect(x: 0, y: 0, width: 768, height: 768)))
        #expect(TestImages.isRed(TestImages.pixel(red, red.width / 2, red.height / 2)))
        #expect(TestImages.isRed(TestImages.pixel(red, red.width - 4, red.height - 4)))
        let grey = try Self.decoded(try ProfilePhotoEncoder.encode(image, crop: CGRect(x: 1280, y: 768, width: 768, height: 768)))
        let c = TestImages.pixel(grey, grey.width / 2, grey.height / 2)
        #expect((100...160).contains(c.r) && (100...160).contains(c.g))
    }

    // MARK: - The shot

    /// A camera's JPEG with a GPS position, the camera's make and model and orientation 6: decoded upright, scaled to a
    /// shorter side of 1,536, and encoded without any of it.
    @Test func aShotWithCameraAndLocationDataIsEncodedClean() throws {
        let picture = TestImages.halves(4032, 3024)
        let source = try #require(TestImages.encoded(picture, uti: "public.jpeg", properties: TestImages.cameraProperties))
        let shot = try ShotImage.decode(source, mirrored: false)
        // Orientation 6 (rotate 90° clockwise): portrait, the left half (red) at the top.
        #expect(shot.width == 1536 && shot.height == 2048)
        #expect(TestImages.isRed(TestImages.pixel(shot.image, 768, 100)) && TestImages.isBlue(TestImages.pixel(shot.image, 768, 1948)))
        let out = try ProfilePhotoEncoder.encode(shot.image)
        #expect(out.count <= 65_536)
        Self.expectNoMetadata(out)
        for needle in ["TestCam", "TestModel", "TestLens", "GPS"] {
            #expect(!TestImages.contains(out, TestImages.ascii(needle)), "\(needle)")
        }
    }

    /// The front camera's shot is mirrored as the preview showed it.
    @Test func aFrontShotIsMirrored() throws {
        let source = try Photos.jpeg(TestImages.halves(400, 300), quality: 95)
        let plain = try ShotImage.decode(source, mirrored: false)
        let mirrored = try ShotImage.decode(source, mirrored: true)
        #expect(TestImages.isRed(TestImages.pixel(plain.image, 20, 150)) && TestImages.isBlue(TestImages.pixel(mirrored.image, 20, 150)))
        // Smaller than the shorter side: kept as it is.
        #expect(plain.width == 400 && plain.height == 300)
    }

    /// A shot is zeroed in place: a picture of its pixels is black from then on.
    @Test func aShotIsWipedInPlace() throws {
        let shot = try ShotImage.of(TestImages.halves(64, 48))
        #expect(!shot.isWiped)
        #expect(TestImages.isRed(TestImages.pixel(shot.image, 4, 4)))
        shot.wipe()
        #expect(shot.isWiped)
        let c = TestImages.pixel(try #require(shot.freshPicture()), 4, 4)
        #expect(c.r == 0 && c.g == 0 && c.b == 0)
        #expect(String(describing: shot) == "ShotImage(64×48)")
    }

    @Test func aShotThatIsNotAPictureOrTooLargeIsRefused() {
        #expect(throws: PhotoError.self) { try ShotImage.decode([UInt8](repeating: 7, count: 300), mirrored: false) }
        #expect(throws: PhotoError(.tooLarge)) { try ShotImage.decode(TestImages.minimalJpegHeader(20_000, 100), mirrored: false) }
    }

    // MARK: - The camera's bytes

    /// A holder that takes the camera's bytes owns its own storage: the source is zeroed at once, and ``PhotoBytes/wipe()``
    /// zeroes what it kept.
    @Test func takenBytesAreOwnedAndZeroed() {
        var source: [UInt8] = [1, 2, 3, 4]
        let held = PhotoBytes(taking: &source, mirrored: true)
        #expect(source == [0, 0, 0, 0] && held.copy() == [1, 2, 3, 4] && held.mirrored)
        held.wipe()
        #expect(held.isWiped)
        #expect(!PhotoBytes([1]).mirrored)
    }

    /// A front shot prepared for a message is mirrored as previewed, through the same clean re-encode.
    @Test func aMirroredShotIsPreparedMirrored() throws {
        let source = try Photos.jpeg(TestImages.halves(400, 200), quality: 95)
        let plain = try Photos.decodeReceived(try Photos.prepare(source).jpeg.copy(), targetLongEdge: 400)
        let prepared = try Photos.prepare(source, mirrored: true)
        let mirrored = try Photos.decodeReceived(prepared.jpeg.copy(), targetLongEdge: 400)
        #expect(TestImages.isRed(TestImages.pixel(plain, 20, 100)) && TestImages.isBlue(TestImages.pixel(mirrored, 20, 100)))
        Self.expectNoMetadata(prepared.jpeg.copy())
    }
}
