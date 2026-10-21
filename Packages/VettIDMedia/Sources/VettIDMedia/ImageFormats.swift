import Foundation

/// The photo types a vault and an app accept (VAULT-MESSAGING §10.5.1 `photo_types`), decided **by sniffing** the first
/// bytes and nothing else: never by the `mime` or the name a peer sent. Mirrors vettid-android `ImageType`.
public enum ImageType: String, Sendable, CaseIterable {
    case jpeg
    case png
    case webp

    public var mime: String {
        switch self {
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .webp: "image/webp"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .webp: "webp"
        }
    }

    /// The uniform type identifier (for the share sheet and the Photos library).
    public var uti: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .webp: "org.webmproject.webp"
        }
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let webpMin = 12

    /// JPEG `FF D8 FF`; PNG its 8-byte signature; WebP `RIFF`, any 4 bytes, `WEBP`. Anything else is nil.
    public static func sniff(_ b: [UInt8]) -> ImageType? {
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b.count >= pngSignature.count, Array(b[0..<pngSignature.count]) == pngSignature { return .png }
        if b.count >= webpMin, b.ascii(0, "RIFF"), b.ascii(8, "WEBP") { return .webp }
        return nil
    }
}

/// A picture's width and height in pixels, as its header declares them.
public struct Dimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var longEdge: Int { max(width, height) }
    public var pixels: Int64 { Int64(width) * Int64(height) }

    /// Whether this is within [maxSide] on each side and [maxPixels] in all.
    public func within(maxSide: Int, maxPixels: Int64) -> Bool {
        (1...maxSide).contains(width) && (1...maxSide).contains(height) && pixels <= maxPixels
    }
}

/// Reads the dimensions a JPEG, PNG or WebP declares **from its header only**, before any decoder allocates pixels: a
/// decompression bomb (a small file declaring 60,000 × 60,000 pixels) is refused from these few bytes. Nil when the
/// header cannot be read (truncated, or not one of the three types). Mirrors vettid-android `ImageHeader`.
public enum ImageHeader {
    static let pngIHDRType = 12
    static let pngIHDREnd = 24
    static let jpegSOFMin = 7
    static let webpChunk = 12
    static let vp8Mask = 0x3FFF

    public static func dimensions(_ b: [UInt8]) -> Dimensions? {
        switch ImageType.sniff(b) {
        case .png: png(b)
        case .jpeg: jpeg(b)
        case .webp: webp(b)
        case nil: nil
        }
    }

    // PNG: the signature, then the IHDR chunk (length 13): width and height as 32-bit big-endian.
    private static func png(_ b: [UInt8]) -> Dimensions? {
        guard b.count >= pngIHDREnd, b.ascii(pngIHDRType, "IHDR") else { return nil }
        let w = b.u32be(pngIHDRType + 4)
        let h = b.u32be(pngIHDRType + 8)
        guard (1...UInt32(Int32.max)).contains(w), (1...UInt32(Int32.max)).contains(h) else { return nil }
        return Dimensions(width: Int(w), height: Int(h))
    }

    // JPEG: the segments after SOI up to the first start-of-frame (SOF0–SOF15 but DHT C4, JPG C8 and DAC CC).
    private static func jpeg(_ b: [UInt8]) -> Dimensions? {
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { return nil }
            var m = Int(b[i + 1])
            while m == 0xFF, i + 2 < b.count { // fill bytes
                i += 1
                m = Int(b[i + 1])
            }
            i += 2
            if m == 0xD8 || m == 0x01 || (0xD0...0xD7).contains(m) { continue } // no length
            if m == 0xD9 || m == 0xDA || i + 1 >= b.count { return nil } // end, or scan data before any frame
            let len = b.u16be(i)
            guard len >= 2 else { return nil }
            if (0xC0...0xCF).contains(m), m != 0xC4, m != 0xC8, m != 0xCC {
                guard i + jpegSOFMin <= b.count else { return nil }
                let h = b.u16be(i + 3)
                let w = b.u16be(i + 5)
                return w > 0 && h > 0 ? Dimensions(width: w, height: h) : nil
            }
            i += len
        }
        return nil
    }

    // WebP: the first chunk after "RIFF....WEBP": VP8 (lossy), VP8L (lossless) or VP8X (extended, the canvas).
    private static func webp(_ b: [UInt8]) -> Dimensions? {
        guard b.count >= webpChunk + 8 else { return nil }
        if b.ascii(webpChunk, "VP8 ") {
            // Frame tag (3), start code 9D 01 2A, then 14-bit width and height, little-endian.
            let p = webpChunk + 8 + 3
            guard b.count >= p + 7, b[p] == 0x9D, b[p + 1] == 0x01, b[p + 2] == 0x2A else { return nil }
            let d = Dimensions(width: b.u16le(p + 3) & vp8Mask, height: b.u16le(p + 5) & vp8Mask)
            return d.width > 0 && d.height > 0 ? d : nil
        }
        if b.ascii(webpChunk, "VP8L") {
            // Signature 0x2F, then 14 bits width − 1 and 14 bits height − 1, little-endian bit order.
            let p = webpChunk + 8
            guard b.count >= p + 5, b[p] == 0x2F else { return nil }
            let bits = UInt32(b[p + 1]) | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3]) << 16 | UInt32(b[p + 4]) << 24
            return Dimensions(width: Int(bits & 0x3FFF) + 1, height: Int((bits >> 14) & 0x3FFF) + 1)
        }
        if b.ascii(webpChunk, "VP8X") {
            // Flags (4), then canvas width − 1 and height − 1, 24-bit little-endian each.
            let p = webpChunk + 8 + 4
            guard b.count >= p + 6 else { return nil }
            return Dimensions(width: b.u24le(p) + 1, height: b.u24le(p + 3) + 1)
        }
        return nil
    }
}

/// The marker segments of a JPEG up to its scan data: for the check that an encoded photo carries no metadata (no APP1:
/// EXIF and XMP, so no GPS or camera data; no APP13: IPTC), and for removing what ImageIO's encoder writes besides the
/// pixels. Mirrors vettid-android `JpegSegments`.
public enum JpegSegments {
    public static let app0 = 0xE0
    public static let app1 = 0xE1
    public static let app2 = 0xE2
    public static let app13 = 0xED
    public static let com = 0xFE

    /// The markers in order (without SOI), up to and including SOS; empty for anything but a JPEG.
    public static func markers(_ b: [UInt8]) -> [Int] {
        segments(b).map(\.marker)
    }

    /// One marker segment: its marker, where its `FF` starts and where it ends (after its length's bytes).
    struct Segment {
        let marker: Int
        let start: Int
        let end: Int
    }

    /// The segments up to and including SOS (or EOI); empty for anything but a JPEG or a malformed one's rest.
    static func segments(_ b: [UInt8]) -> [Segment] {
        guard ImageType.sniff(b) == .jpeg else { return [] }
        var out: [Segment] = []
        var i = 2
        while i + 3 < b.count, b[i] == 0xFF {
            let start = i
            let m = Int(b[i + 1])
            i += 2
            if m == 0x01 || (0xD0...0xD7).contains(m) { continue }
            if m == 0xDA || m == 0xD9 {
                out.append(Segment(marker: m, start: start, end: i))
                break
            }
            let len = b.u16be(i)
            guard len >= 2, i + len <= b.count else { break }
            i += len
            out.append(Segment(marker: m, start: start, end: i))
        }
        return out
    }

    /// Whether [b] has an APP2 segment holding a Multi-Picture Format index (`MPF\0`: a gain map or a second picture).
    public static func hasMpf(_ b: [UInt8]) -> Bool {
        segments(b).contains { $0.marker == app2 && b.ascii($0.start + 4, "MPF") && $0.start + 7 < b.count && b[$0.start + 7] == 0 }
    }

    /// Whether another JPEG follows the first one's end: after the first scan, entropy-coded data holds `FF` only as
    /// `FF 00` or a restart marker, so the first `FF D9` is the end of the image, and an `FF D8 FF` after it is a second.
    public static func hasSecondImage(_ b: [UInt8]) -> Bool {
        guard b.count > 4, let sos = (2..<(b.count - 1)).first(where: { b[$0] == 0xFF && b[$0 + 1] == 0xDA }),
              sos + 2 < b.count - 1,
              let eoi = ((sos + 2)..<(b.count - 1)).first(where: { b[$0] == 0xFF && b[$0 + 1] == 0xD9 }),
              eoi + 2 < b.count - 2 else { return false }
        return ((eoi + 2)..<(b.count - 2)).contains { b[$0] == 0xFF && b[$0 + 1] == 0xD8 && b[$0 + 2] == 0xFF }
    }

    /// Whether [b] carries a metadata segment: APP1 (EXIF, XMP, so GPS and camera data), APP13 (IPTC) or an MPF index.
    public static func hasMetadata(_ b: [UInt8]) -> Bool {
        markers(b).contains { $0 == app1 || $0 == app13 } || hasMpf(b)
    }

    /// [b] with every segment before the scan removed but the frame and tables, the JFIF header (APP0) and an ICC profile
    /// (APP2 `ICC_PROFILE`, sRGB's: the pixels were drawn in sRGB): no EXIF, XMP, IPTC, MPF, comment or maker segment is
    /// left of what an encoder writes (chosen; not in the spec: ImageIO's JPEG encoder writes a small EXIF of its own,
    /// which ANDROID-PLAN "Photo attachments" step 3 does not allow). Nil when [b] is not a JPEG this can read.
    public static func stripped(_ b: [UInt8]) -> [UInt8]? {
        let segs = segments(b)
        guard let sos = segs.last, sos.marker == 0xDA else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        out.reserveCapacity(b.count)
        for s in segs.dropLast() where keeps(s, b) { out.append(contentsOf: b[s.start..<s.end]) }
        out.append(contentsOf: b[sos.start...])
        return out
    }

    private static func keeps(_ s: Segment, _ b: [UInt8]) -> Bool {
        switch s.marker {
        case app0: b.ascii(s.start + 4, "JFIF\0")
        case app2: b.ascii(s.start + 4, "ICC_PROFILE\0")
        case 0xE1...0xEF, com: false
        default: true
        }
    }
}

extension [UInt8] {
    func ascii(_ at: Int, _ s: String) -> Bool {
        let u = Array(s.utf8)
        guard at >= 0, at + u.count <= count else { return false }
        for (k, c) in u.enumerated() where self[at + k] != c { return false }
        return true
    }

    func u16be(_ at: Int) -> Int { Int(self[at]) << 8 | Int(self[at + 1]) }

    func u16le(_ at: Int) -> Int { Int(self[at]) | Int(self[at + 1]) << 8 }

    func u24le(_ at: Int) -> Int { u16le(at) | Int(self[at + 2]) << 16 }

    func u32be(_ at: Int) -> UInt32 { UInt32(u16be(at)) << 16 | UInt32(u16be(at + 2)) }
}
