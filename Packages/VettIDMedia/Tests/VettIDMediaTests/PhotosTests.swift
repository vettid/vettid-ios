import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VettIDMedia

/// Preparing and decoding photos with ImageIO (IOS-PLAN §8 I2.4's acceptance: EXIF and GPS absent in the sent JPEG;
/// bounded decoding refuses oversized and mistyped files). Mirrors vettid-android `PhotosTest`.
@Suite struct PhotosTests {
    func failure(_ body: () throws -> some Any) -> PhotoFailure? {
        do {
            _ = try body()
            return nil
        } catch {
            return (error as? PhotoError)?.failure
        }
    }

    /// No APP1 (EXIF, XMP, GPS), no APP13, no MPF, and nothing of the camera or the position anywhere in the bytes.
    func expectClean(_ jpeg: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!JpegSegments.hasMetadata(jpeg), sourceLocation: sourceLocation)
        let markers = JpegSegments.markers(jpeg)
        #expect(!markers.contains(JpegSegments.app1) && !markers.contains(JpegSegments.app13), sourceLocation: sourceLocation)
        for needle in ["TestCam", "TestModel", "TestLens", "Exif", "http://ns.adobe.com/xap", "GPS"] {
            #expect(!TestImages.contains(jpeg, TestImages.ascii(needle)), "\(needle)", sourceLocation: sourceLocation)
        }
        // ImageIO reads no EXIF, TIFF or GPS dictionary back either.
        let src = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil)
        let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        #expect(props[kCGImagePropertyGPSDictionary] == nil, sourceLocation: sourceLocation)
        #expect(props[kCGImagePropertyExifDictionary] == nil, sourceLocation: sourceLocation)
        #expect(props[kCGImagePropertyTIFFDictionary] == nil, sourceLocation: sourceLocation)
        #expect(props[kCGImagePropertyOrientation] == nil, sourceLocation: sourceLocation)
    }

    @Test func aJpegWithGpsCameraDataAndOrientationComesOutCleanAndUpright() throws {
        let source = TestImages.withApp1(try Photos.jpeg(TestImages.halves(400, 200), quality: 95), TestImages.exifWithGpsAndOrientation(6))
        #expect(JpegSegments.hasMetadata(source))
        let p = try Photos.prepare(source)
        let jpeg = p.jpeg.copy()
        expectClean(jpeg)
        // Orientation 6 (rotate 90° clockwise): the left half (red) is now at the top.
        #expect(p.width == 200 && p.height == 400)
        let back = try Photos.decodeReceived(jpeg, targetLongEdge: 400)
        #expect(TestImages.isRed(TestImages.pixel(back, 100, 20)), "top red")
        #expect(TestImages.isBlue(TestImages.pixel(back, 100, 380)), "bottom blue")
        let thumb = p.thumb.copy()
        #expect(ImageType.sniff(thumb) == .jpeg)
        expectClean(thumb)
    }

    /// The same with the metadata as ImageIO itself writes it (the camera's EXIF and TIFF, a GPS position).
    @Test func cameraAndLocationDataWrittenByImageIOAreGone() throws {
        let picture = TestImages.halves(400, 200)
        let source = try #require(TestImages.encoded(picture, uti: "public.jpeg", properties: TestImages.cameraProperties))
        let src = try #require(CGImageSourceCreateWithData(Data(source) as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyGPSDictionary] != nil, "the source has a position")
        let p = try Photos.prepare(source)
        expectClean(p.jpeg.copy())
        expectClean(p.thumb.copy())
        #expect(p.width == 200 && p.height == 400)
    }

    /// A HEIC from the photo library (where this system can write one) is sent as a clean JPEG.
    @Test func aHeicIsReencodedAsACleanJpeg() throws {
        guard let heic = TestImages.encoded(TestImages.halves(300, 200), uti: "public.heic", properties: TestImages.cameraProperties) else {
            return // no HEIC encoder on this system
        }
        #expect(ImageType.sniff(heic) == nil)
        let p = try Photos.prepare(heic)
        #expect(ImageType.sniff(p.jpeg.copy()) == .jpeg)
        expectClean(p.jpeg.copy())
        #expect(p.width == 200 && p.height == 300)
    }

    @Test func aLargePhotoIsDownscaledToTheLongEdgeAndFits() throws {
        let p = try Photos.prepare(try Photos.jpeg(TestImages.halves(3_000, 1_500), quality: 90))
        #expect(max(p.width, p.height) == PhotoLimits.sendLongEdge && p.height == 1_280)
        #expect(p.jpeg.count <= PhotoLimits.attachmentMaxBytes)
        #expect(p.thumb.count <= PhotoLimits.thumbMaxBytes, "thumbnail under 32 KiB")
        let thumb = try Photos.decodeThumbnail(p.thumb.copy())
        #expect(max(thumb.width, thumb.height) == PhotoLimits.thumbLongEdge)
    }

    @Test func aPngIsReencodedAsJpeg() throws {
        let png = try #require(TestImages.encoded(TestImages.halves(300, 300), uti: "public.png"))
        let p = try Photos.prepare(png)
        #expect(ImageType.sniff(p.jpeg.copy()) == .jpeg && p.width == 300)
    }

    @Test func theBombIsRefusedBeforeAnyDecoding() {
        let bomb = TestImages.pngHeaderOnly(60_000, 60_000)
        #expect(failure { try Photos.decodeReceived(bomb, targetLongEdge: 1_000) } == .tooLarge)
        #expect(failure { try Photos.prepare(bomb) } == .tooLarge)
    }

    @Test func aThumbnailDeclaringFourThousandPixelsIsRefused() {
        #expect(failure { try Photos.decodeThumbnail(TestImages.pngHeaderOnly(4_000, 100)) } == .tooLarge)
    }

    /// Only JPEG, PNG and WebP by their bytes are decoded; a file of another type whose bytes ImageIO would decode (GIF,
    /// SVG, a HEIC) is refused before any decoder runs; a truncated one is unreadable.
    @Test func onlySniffedTypesAreDecoded() throws {
        let fakeGif = TestImages.ascii("GIF89a") + [UInt8](repeating: 0, count: 100)
        #expect(failure { try Photos.decodeReceived(fakeGif, targetLongEdge: 100) } == .unsupported)
        let svg = TestImages.ascii("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>")
        #expect(failure { try Photos.decodeReceived(svg, targetLongEdge: 100) } == .unsupported)
        if let gif = TestImages.encoded(TestImages.halves(10, 10), uti: "com.compuserve.gif") {
            #expect(failure { try Photos.decodeReceived(gif, targetLongEdge: 100) } == .unsupported)
        }
        let jpeg = try Photos.jpeg(TestImages.halves(64, 64), quality: 90)
        #expect(failure { try Photos.decodeReceived(Array(jpeg.prefix(30)), targetLongEdge: 64) } == .unreadable)
    }

    @Test func anApngIsDecodedToItsFirstFrameOnly() throws {
        let apng = TestImages.apngRedThenBlue(16, 16)
        #expect(ImageType.sniff(apng) == .png)
        #expect(TestImages.isRed(TestImages.pixel(try Photos.decodeReceived(apng, targetLongEdge: 16), 8, 8)))
        #expect(TestImages.isRed(TestImages.pixel(try Photos.decodeThumbnail(apng, targetLongEdge: 16), 8, 8)))
    }

    @Test func aCameraShotIsPreparedFromMemory() throws {
        let p = try Photos.prepare(TestImages.halves(1_000, 750))
        #expect(p.width == 1_000)
        expectClean(p.jpeg.copy())
        p.wipe()
        #expect(p.isWiped && p.jpeg.isWiped && p.thumb.isWiped)
    }

    @Test func aReceivedJpegWithAGainMapOrASecondImageIsRefusedBeforeDecoding() throws {
        let jpeg = try Photos.jpeg(TestImages.halves(64, 64), quality: 90)
        #expect(JpegSegments.hasMpf(TestImages.withMpf(jpeg)))
        #expect(failure { try Photos.decodeReceived(TestImages.withMpf(jpeg), targetLongEdge: 64) } == .unsupported)
        let two = jpeg + (try Photos.jpeg(TestImages.halves(8_000, 8), quality: 50))
        #expect(JpegSegments.hasSecondImage(two))
        #expect(failure { try Photos.decodeReceived(two, targetLongEdge: 64) } == .unsupported)
        #expect(failure { try Photos.decodeThumbnail(two) } == .unsupported)
        #expect(!JpegSegments.hasSecondImage(jpeg) && !JpegSegments.hasMpf(jpeg))
    }

    /// The encoder's own segments go; the frame, the tables and the scan stay (the result decodes to the same size).
    @Test func strippingKeepsThePicture() throws {
        let raw = try #require(TestImages.encoded(TestImages.halves(64, 32), uti: "public.jpeg", properties: TestImages.cameraProperties))
        #expect(JpegSegments.hasMetadata(raw))
        let clean = try #require(JpegSegments.stripped(raw))
        expectClean(clean)
        #expect(ImageHeader.dimensions(clean) == ImageHeader.dimensions(raw))
        let back = try Photos.decodeReceived(clean, targetLongEdge: 64)
        #expect(back.width == 64 && back.height == 32)
        #expect(JpegSegments.stripped(TestImages.pngHeaderOnly(1, 1)) == nil)
    }
}
