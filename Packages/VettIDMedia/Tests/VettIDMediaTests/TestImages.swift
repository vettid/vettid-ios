import CoreGraphics
import Foundation
import ImageIO
@testable import VettIDMedia

/// Hand-built image bytes for the tests (headers, EXIF with GPS, an APNG) and pictures drawn with Core Graphics. Mirrors
/// vettid-android `TestImages`.
enum TestImages {
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    static func le24(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { le16(v) + le16(v >> 16) }
    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    static let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFF_FFFF
    }

    static func pngChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let t = ascii(type)
        return be32(UInt32(data.count)) + t + data + be32(crc32(t + data))
    }

    static func ihdr(_ w: Int, _ h: Int) -> [UInt8] { be32(UInt32(w)) + be32(UInt32(h)) + [8, 2, 0, 0, 0] } // 8-bit RGB

    /// A PNG that is only its signature and IHDR: a header declaring [w] × [h] and no pixels at all.
    static func pngHeaderOnly(_ w: Int, _ h: Int) -> [UInt8] { pngSig + pngChunk("IHDR", ihdr(w, h)) }

    /// SOI, an APP0 and an SOF0 declaring [w] × [h]: enough for the header reader, not for a decoder.
    static func minimalJpegHeader(_ w: Int, _ h: Int) -> [UInt8] {
        let app0: [UInt8] = [0xFF, 0xE0] + be16(16) + ascii("JFIF") + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        let sof: [UInt8] = [0xFF, 0xC0] + be16(11) + [8] + be16(h) + be16(w) + [1, 1, 0x11, 0]
        return [0xFF, 0xD8] + app0 + sof
    }

    static func webpVp8xHeader(_ w: Int, _ h: Int) -> [UInt8] {
        let vp8x = ascii("VP8X") + le32(10) + [0, 0, 0, 0] + le24(w - 1) + le24(h - 1)
        return ascii("RIFF") + le32(4 + vp8x.count) + ascii("WEBP") + vp8x
    }

    /// [jpeg] with an APP1 segment ([app1], from "Exif\0\0" on) inserted after SOI.
    static func withApp1(_ jpeg: [UInt8], _ app1: [UInt8]) -> [UInt8] {
        Array(jpeg[0..<2]) + [0xFF, 0xE1] + be16(app1.count + 2) + app1 + Array(jpeg[2...])
    }

    /// [jpeg] with an APP2 segment holding an MPF index inserted after SOI (as a photo with a gain map has).
    static func withMpf(_ jpeg: [UInt8]) -> [UInt8] {
        let payload = ascii("MPF") + [0] + [UInt8](repeating: 0, count: 16)
        return Array(jpeg[0..<2]) + [0xFF, 0xE2] + be16(payload.count + 2) + payload + Array(jpeg[2...])
    }

    /// An EXIF block (big-endian TIFF) with Make "TestCam", Orientation [orientation] and a GPS IFD with a latitude
    /// reference and a latitude: the camera and location data that must never be sent.
    static func exifWithGpsAndOrientation(_ orientation: Int) -> [UInt8] {
        var tiff = ascii("MM") + be16(42) + be32(8)
        let ifd0Size = 2 + 3 * 12 + 4
        let makeAt = 8 + ifd0Size
        let make = ascii("TestCam") + [0]
        let gpsAt = makeAt + make.count
        tiff += be16(3)
        tiff += be16(0x010F) + be16(2) + be32(UInt32(make.count)) + be32(UInt32(makeAt)) // Make, ASCII
        tiff += be16(0x0112) + be16(3) + be32(1) + be16(orientation) + be16(0) // Orientation, SHORT
        tiff += be16(0x8825) + be16(4) + be32(1) + be32(UInt32(gpsAt)) // GPSInfo IFD pointer, LONG
        tiff += be32(0)
        tiff += make
        let gpsIfdSize = 2 + 2 * 12 + 4
        let latAt = gpsAt + gpsIfdSize
        tiff += be16(2)
        tiff += be16(0x0001) + be16(2) + be32(2) + ascii("N") + [0, 0, 0]
        tiff += be16(0x0002) + be16(5) + be32(3) + be32(UInt32(latAt))
        tiff += be32(0)
        for (n, d) in [(52, 1), (31, 1), (1_234, 100)] { tiff += be32(UInt32(n)) + be32(UInt32(d)) }
        return ascii("Exif") + [0, 0] + tiff
    }

    /// zlib data of [raw] in stored (uncompressed) deflate blocks, with its Adler-32.
    static func zlibStored(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var at = 0
        repeat {
            let n = min(65_535, raw.count - at)
            let last: UInt8 = at + n >= raw.count ? 1 : 0
            out += [last] + le16(n) + le16(~n & 0xFFFF) + raw[at..<(at + n)]
            at += n
        } while at < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for x in raw {
            a = (a + UInt32(x)) % 65_521
            b = (b + a) % 65_521
        }
        return out + be32(b << 16 | a)
    }

    static func rows(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var raw: [UInt8] = []
        for _ in 0..<h { raw += [0] + Array([[UInt8]](repeating: [r, g, b], count: w).joined()) }
        return zlibStored(raw)
    }

    /// An APNG of two [w] × [h] frames: red first (also the default image), then blue.
    static func apngRedThenBlue(_ w: Int, _ h: Int) -> [UInt8] {
        let actl = be32(2) + be32(0)
        func fctl(_ seq: Int) -> [UInt8] {
            be32(UInt32(seq)) + be32(UInt32(w)) + be32(UInt32(h)) + be32(0) + be32(0) + be16(1) + be16(1) + [0, 0]
        }
        return pngSig + pngChunk("IHDR", ihdr(w, h)) + pngChunk("acTL", actl) + pngChunk("fcTL", fctl(0))
            + pngChunk("IDAT", rows(w, h, 255, 0, 0)) + pngChunk("fcTL", fctl(1))
            + pngChunk("fdAT", be32(2) + rows(w, h, 0, 0, 255)) + pngChunk("IEND", [])
    }

    // MARK: - Pictures

    /// Left half red, right half blue.
    static func halves(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Double(w) / 2, height: Double(h)))
        return ctx.makeImage()!
    }

    /// The pixel at [x], [y] (from the top left) as RGB.
    struct RGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGB {
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(
                data: p.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = (y * image.width + x) * 4
        return RGB(r: buf[i], g: buf[i + 1], b: buf[i + 2])
    }

    static func isRed(_ c: RGB) -> Bool { c.r > 200 && c.b < 60 }
    static func isBlue(_ c: RGB) -> Bool { c.b > 200 && c.r < 60 }

    /// [image] encoded by ImageIO as [uti], with [properties] (EXIF, TIFF, GPS dictionaries) written by it; nil when
    /// this system cannot encode that type.
    static func encoded(_ image: CGImage, uti: String, properties: [CFString: Any] = [:]) -> [UInt8]? {
        let out = CFDataCreateMutable(nil, 0)!
        guard let dest = CGImageDestinationCreateWithData(out, uti as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](out as Data)
    }

    /// Camera and location data as ImageIO writes them: a GPS position, the camera's make and model, orientation 6.
    static var cameraProperties: [CFString: Any] { [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 52.5162, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 13.3777, kCGImagePropertyGPSLongitudeRef: "E",
        ],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "TestModel 9"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "TestLens"],
    ] }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        return (0...(hay.count - needle.count)).contains { i in hay[i..<(i + needle.count)].elementsEqual(needle) }
    }
}
