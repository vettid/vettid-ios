import Foundation
import Testing
@testable import VettIDMedia

/// Sniffing, header-first bounds, metadata segments, name sanitizing and the memory cache (no decoder). Mirrors
/// vettid-android `ImageFormatsTest`.
@Suite struct ImageFormatsTests {
    @Test func sniffingDecidesByTheBytesAlone() {
        #expect(ImageType.sniff([0xFF, 0xD8, 0xFF, 0xE0]) == .jpeg)
        #expect(ImageType.sniff([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]) == .png)
        #expect(ImageType.sniff(TestImages.ascii("RIFF") + [1, 2, 3, 4] + TestImages.ascii("WEBPVP8 ")) == .webp)
        #expect(ImageType.sniff(TestImages.ascii("GIF89a....")) == nil, "GIF")
        #expect(ImageType.sniff([0, 0, 0, 0x18] + TestImages.ascii("ftypheic")) == nil, "HEIC")
        #expect(ImageType.sniff(TestImages.ascii("<svg xmlns=\"http://www.w3.org/2000/svg\"/>")) == nil, "SVG")
        #expect(ImageType.sniff(TestImages.ascii("hello")) == nil, "text")
        #expect(ImageType.sniff(TestImages.ascii("RIFF") + [0, 0, 0, 0] + TestImages.ascii("WAVE")) == nil, "RIFF but WAVE")
        #expect(ImageType.sniff([]) == nil, "empty")
        // A JPEG sent as "photo.png" with mime image/png is a JPEG: the name and mime are never read.
        #expect(ImageType.sniff(TestImages.minimalJpegHeader(10, 10)) == .jpeg)
    }

    @Test func aDecompressionBombIsRefusedFromItsHeader() throws {
        let d = try #require(ImageHeader.dimensions(TestImages.pngHeaderOnly(60_000, 60_000)))
        #expect(d == Dimensions(width: 60_000, height: 60_000))
        #expect(!d.within(maxSide: PhotoLimits.viewMaxSide, maxPixels: PhotoLimits.viewMaxPixels))
        #expect(!d.within(maxSide: PhotoLimits.sourceMaxSide, maxPixels: PhotoLimits.sourceMaxPixels))
    }

    @Test func headersOfTheThreeTypes() {
        #expect(ImageHeader.dimensions(TestImages.pngHeaderOnly(4_000, 3_000)) == Dimensions(width: 4_000, height: 3_000))
        #expect(ImageHeader.dimensions(TestImages.minimalJpegHeader(640, 480)) == Dimensions(width: 640, height: 480))
        #expect(ImageHeader.dimensions(TestImages.webpVp8xHeader(321, 123)) == Dimensions(width: 321, height: 123))
        #expect(ImageHeader.dimensions(Array(TestImages.pngHeaderOnly(10, 10).prefix(20))) == nil)
        #expect(ImageHeader.dimensions(TestImages.ascii("text")) == nil)
    }

    @Test func aThumbnailOverAThousandPixelsIsRefusedFromItsHeader() throws {
        let d = try #require(ImageHeader.dimensions(TestImages.minimalJpegHeader(4_000, 300)))
        #expect(!d.within(maxSide: PhotoLimits.thumbViewMaxSide, maxPixels: PhotoLimits.thumbViewMaxPixels))
        let small = Dimensions(width: 320, height: 240)
        #expect(small.within(maxSide: PhotoLimits.thumbViewMaxSide, maxPixels: PhotoLimits.thumbViewMaxPixels))
    }

    @Test func metadataSegmentsAreFound() {
        let withExif = TestImages.withApp1(TestImages.minimalJpegHeader(8, 8), TestImages.exifWithGpsAndOrientation(6))
        #expect(JpegSegments.hasMetadata(withExif))
        #expect(JpegSegments.markers(withExif).contains(JpegSegments.app1))
        #expect(!JpegSegments.hasMetadata(TestImages.minimalJpegHeader(8, 8)))
        #expect(JpegSegments.hasMetadata(TestImages.withMpf(TestImages.minimalJpegHeader(8, 8))))
    }

    final class Box {
        var bytes: [UInt8]
        init(_ b: [UInt8]) { bytes = b }
    }

    @Test func theCacheIsBoundedLeastRecentlyUsedOutAndCleared() {
        var evicted: [UInt8] = []
        let c = MemoryCache<String, Box>(maxBytes: 100, sizeOf: { $0.bytes.count }, onEvict: { evicted.append($0.bytes[0]) })
        c.put("a", Box([UInt8](repeating: 0x61, count: 40)))
        c.put("b", Box([UInt8](repeating: 0x62, count: 40)))
        _ = c.get("a") // a is now the most recent
        c.put("c", Box([UInt8](repeating: 0x63, count: 40)))
        #expect(c.get("b") == nil)
        #expect(c.usedBytes == 80)
        c.put("huge", Box([UInt8](repeating: 0, count: 101)))
        #expect(c.get("huge") == nil, "larger than the bound: not kept")
        c.clear()
        #expect(c.count == 0 && c.usedBytes == 0)
        #expect(evicted.contains(0x62) && evicted.contains(0x61) && evicted.contains(0x63))
    }

    @Test func theSameObjectPutAgainIsNotZeroed() {
        let c = MemoryCache<String, Box>(maxBytes: 100, sizeOf: { $0.bytes.count }) {
            $0.bytes = [UInt8](repeating: 0, count: $0.bytes.count)
        }
        let v = Box([UInt8](repeating: 7, count: 10))
        c.put("a", v)
        c.put("a", v)
        #expect(v.bytes.allSatisfy { $0 == 7 })
        #expect(c.usedBytes == 10)
    }

    /// Withdrawn offers give nothing and are zeroed; at most four live at once.
    @Test func aClearWithdrawsEveryShareOffer() {
        let shared = SharedPhotos()
        let token = shared.offer([0xFF, 0xD8, 0xFF, 1, 2, 3], type: .jpeg)
        #expect(shared.live(token) && shared.data(token) == Data([0xFF, 0xD8, 0xFF, 1, 2, 3]) && shared.type(token) == .jpeg)
        shared.clear()
        #expect(!shared.live(token) && shared.data(token) == nil)
        let tokens = (0..<5).map { shared.offer([UInt8($0)], type: .png) }
        #expect(!shared.live(tokens[0]) && tokens.dropFirst().allSatisfy(shared.live))
        #expect(Set(tokens).count == 5 && tokens.allSatisfy { $0.count == 32 })
    }
}
