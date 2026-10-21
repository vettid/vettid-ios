import CoreGraphics
import Foundation
import ImageIO

/// Why a photo could not be prepared or shown. Mirrors vettid-android `PhotoFailure`.
public enum PhotoFailure: String, Sendable {
    /// Larger than the bounds (sending: 16,384 a side or 100 MP; showing: 8,192 or 40 MP, 1,024 for a thumbnail).
    case tooLarge
    /// Not JPEG, PNG or WebP by its bytes (showing), or a format the phone cannot decode (sending).
    case unsupported
    /// Truncated, corrupt, or out of memory.
    case unreadable
    /// Could not be brought under `attachment_max_bytes` or the thumbnail under 32 KiB.
    case cannotFit
}

/// A photo that could not be prepared or shown. Says the failure only, never anything of the picture.
public struct PhotoError: Error, Equatable, Sendable, CustomStringConvertible {
    public let failure: PhotoFailure

    public init(_ failure: PhotoFailure) { self.failure = failure }

    public var description: String { "photo: \(failure.rawValue)" }
}

/// Encoded bytes of a photo in memory that can be zeroed: ``wipe()`` zeroes them in place. What is handed out is a copy
/// (``copy()``), which a wipe cannot reach. Never printed or reflected. [mirrored]: a front-camera shot, to be mirrored
/// left to right as it was previewed wherever it is decoded (vettid-android `PhotoCamera.take`: "front shots mirrored,
/// as previewed").
public final class PhotoBytes: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var storage: [UInt8]
    public let mirrored: Bool

    public init(_ bytes: [UInt8], mirrored: Bool = false) {
        storage = bytes
        self.mirrored = mirrored
    }

    /// A holder with storage of its own, then [source] zeroed in place: a ``wipe()`` reaches every byte the app kept.
    public init(taking source: inout [UInt8], mirrored: Bool = false) {
        storage = source.withUnsafeBufferPointer { Array($0) }
        self.mirrored = mirrored
        source.withUnsafeMutableBufferPointer { p in
            for i in p.indices { p[i] = 0 }
        }
    }

    public var count: Int { lock.withLock { storage.count } }

    /// A copy in storage of its own.
    public func copy() -> [UInt8] { lock.withLock { storage.withUnsafeBufferPointer { Array($0) } } }

    /// Whether every byte is zero (wiped).
    public var isWiped: Bool { lock.withLock { storage.allSatisfy { $0 == 0 } } }

    /// Runs [body] with the bytes, without a copy.
    public func withBytes<T>(_ body: ([UInt8]) throws -> T) rethrows -> T { try lock.withLock { try body(storage) } }

    public func wipe() {
        lock.withLock {
            storage.withUnsafeMutableBufferPointer { p in
                for i in p.indices { p[i] = 0 }
            }
        }
    }

    public var description: String { "PhotoBytes(\(count))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A photo prepared for sending, in memory only: the re-encoded JPEG, its thumbnail and its size in pixels. Mirrors
/// vettid-android `PreparedPhoto`.
public final class PreparedPhoto: Sendable, CustomStringConvertible, CustomReflectable {
    public let jpeg: PhotoBytes
    public let thumb: PhotoBytes
    public let width: Int
    public let height: Int

    public init(jpeg: [UInt8], thumb: [UInt8], width: Int, height: Int) {
        self.jpeg = PhotoBytes(jpeg)
        self.thumb = PhotoBytes(thumb)
        self.width = width
        self.height = height
    }

    /// Zeroes both encodings (after the answer to `message.send`, at Cancel and at a lock).
    public func wipe() {
        jpeg.wipe()
        thumb.wipe()
    }

    public var isWiped: Bool { jpeg.isWiped && thumb.isWiped }

    public var description: String { "PreparedPhoto(\(width)×\(height))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Reading, preparing and decoding photos in memory (ANDROID-PLAN "Photo attachments", 0.1.39) with ImageIO. Every path
/// reads the bounds first and refuses before pixels are allocated; nothing writes a file: the sources are `CFData` in
/// memory and the JPEG encoder writes to a `CFMutableData`. Decoding applies the EXIF orientation to the pixels and, for
/// an animated PNG or WebP, decodes the first frame only (index 0). Mirrors vettid-android `Photos`.
public enum Photos {
    static let shrinks = 6
    static let shrink = 0.8

    /// Prepares [source] (a picked file's bytes, or a camera shot encoded in memory) for sending: bounds from the header
    /// (16,384 a side, 100 MP; ImageIO's header for a type the reader here does not know, such as HEIC), decoded with the
    /// orientation applied and downscaled to a long edge of at most 2,560, re-encoded as JPEG from pixels only (quality
    /// 85, lowered in steps to fit `attachment_max_bytes`), and a thumbnail of long edge 320 under 32 KiB. No EXIF, XMP,
    /// GPS or camera data survives: the pixels are drawn into a plain sRGB bitmap (no gain map, no other profile) and the
    /// encoder's own segments are removed (``JpegSegments/stripped(_:)``).
    /// [mirrored]: a front-camera shot, mirrored left to right (as previewed) before it is re-encoded.
    public static func prepare(_ source: [UInt8], mirrored: Bool = false) throws -> PreparedPhoto {
        if let declared = ImageHeader.dimensions(source),
           !declared.within(maxSide: PhotoLimits.sourceMaxSide, maxPixels: PhotoLimits.sourceMaxPixels) {
            throw PhotoError(.tooLarge)
        }
        let bounds = Bounds(maxSide: PhotoLimits.sourceMaxSide, maxPixels: PhotoLimits.sourceMaxPixels)
        let image = try decode(source, bounds, targetLongEdge: PhotoLimits.sendLongEdge, expected: nil, failure: .unsupported)
        return try prepare(mirrored ? try mirror(image) : image)
    }

    /// Prepares a picture already decoded (upright).
    public static func prepare(_ image: CGImage) throws -> PreparedPhoto {
        let photo = try plain(image, longEdge: PhotoLimits.sendLongEdge)
        let (jpeg, sent) = try encodeUnder(
            photo, limit: PhotoLimits.attachmentMaxBytes, start: PhotoLimits.sendQuality, floor: PhotoLimits.minQuality
        )
        let thumbImage = try plain(sent, longEdge: PhotoLimits.thumbLongEdge)
        let (thumb, _) = try encodeUnder(
            thumbImage, limit: PhotoLimits.thumbMaxBytes, start: PhotoLimits.thumbQuality, floor: PhotoLimits.thumbMinQuality
        )
        guard !JpegSegments.hasMetadata(jpeg), !JpegSegments.hasMetadata(thumb) else { throw PhotoError(.unsupported) }
        return PreparedPhoto(jpeg: jpeg, thumb: thumb, width: sent.width, height: sent.height)
    }

    /// Decodes a received photo for showing: the type sniffed from its bytes (JPEG, PNG, WebP; the peer's `mime` is
    /// never read), a JPEG with a second picture refused, the header read first and anything over [maxSide] or
    /// [maxPixels] refused before decoding, then decoded to a long edge of at most [targetLongEdge] (the screen), the
    /// first frame only.
    public static func decodeReceived(
        _ bytes: [UInt8], targetLongEdge: Int, maxSide: Int = PhotoLimits.viewMaxSide, maxPixels: Int64 = PhotoLimits.viewMaxPixels
    ) throws -> CGImage {
        guard let type = ImageType.sniff(bytes) else { throw PhotoError(.unsupported) }
        // A JPEG with a second picture (a gain map, MPF) is refused before decoding: a decoder may read the second one
        // too, whose size the primary's header does not bound.
        if type == .jpeg, JpegSegments.hasMpf(bytes) || JpegSegments.hasSecondImage(bytes) { throw PhotoError(.unsupported) }
        guard let declared = ImageHeader.dimensions(bytes) else { throw PhotoError(.unreadable) }
        guard declared.within(maxSide: maxSide, maxPixels: maxPixels) else { throw PhotoError(.tooLarge) }
        let bounds = Bounds(maxSide: maxSide, maxPixels: maxPixels)
        return try decode(bytes, bounds, targetLongEdge: targetLongEdge, expected: type, failure: .unreadable)
    }

    /// ``decodeReceived(_:targetLongEdge:maxSide:maxPixels:)`` with a thumbnail's bounds: 1,024 pixels a side at most.
    public static func decodeThumbnail(_ bytes: [UInt8], targetLongEdge: Int = PhotoLimits.thumbLongEdge) throws -> CGImage {
        try decodeReceived(
            bytes, targetLongEdge: targetLongEdge, maxSide: PhotoLimits.thumbViewMaxSide, maxPixels: PhotoLimits.thumbViewMaxPixels
        )
    }

    /// [image] mirrored left to right, in a plain 8-bit sRGB bitmap with no alpha.
    public static func mirror(_ image: CGImage) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { throw PhotoError(.unreadable) }
        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw PhotoError(.unreadable) }
        return out
    }

    /// [image] as JPEG at [quality] (1–100), pixels only: the encoder's metadata segments are removed. The encoder's own
    /// output buffer is released, not zeroed; the bytes returned are the caller's.
    public static func jpeg(_ image: CGImage, quality: Int) throws -> [UInt8] {
        let out = CFDataCreateMutable(nil, 0)!
        guard let dest = CGImageDestinationCreateWithData(out, ImageType.jpeg.uti as CFString, 1, nil) else {
            throw PhotoError(.unreadable)
        }
        let options = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else { throw PhotoError(.unreadable) }
        guard let clean = JpegSegments.stripped([UInt8](out as Data)) else { throw PhotoError(.unreadable) }
        return clean
    }

    // MARK: - Internals

    /// Zeroes [b] in place.
    static func zero(_ b: inout [UInt8]) {
        b.withUnsafeMutableBufferPointer { p in
            for i in p.indices { p[i] = 0 }
        }
    }

    struct Bounds {
        let maxSide: Int
        let maxPixels: Int64
    }

    /// Decodes the first frame of [bytes] to a long edge of at most [targetLongEdge], orientation applied, after
    /// ImageIO's own header is checked against [bounds] (and its type against [expected], for a received photo).
    static func decode(
        _ bytes: [UInt8], _ bounds: Bounds, targetLongEdge: Int, expected: ImageType?, failure: PhotoFailure
    ) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, options), CGImageSourceGetCount(src) > 0 else {
            throw PhotoError(failure)
        }
        if let expected, (CGImageSourceGetType(src) as String?) != expected.uti { throw PhotoError(failure) }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, options) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw PhotoError(failure)
        }
        guard Dimensions(width: w, height: h).within(maxSide: bounds.maxSide, maxPixels: bounds.maxPixels) else {
            throw PhotoError(.tooLarge)
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, targetLongEdge),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions) else { throw PhotoError(failure) }
        return image
    }

    /// [image] drawn into a plain 8-bit sRGB bitmap with no alpha, scaled so that its long edge is at most [longEdge].
    static func plain(_ image: CGImage, longEdge: Int) throws -> CGImage {
        let edge = max(image.width, image.height)
        let s = edge > longEdge ? Double(longEdge) / Double(edge) : 1
        let w = max(1, Int((Double(image.width) * s).rounded()))
        let h = max(1, Int((Double(image.height) * s).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { throw PhotoError(.unreadable) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw PhotoError(.unreadable) }
        return out
    }

    /// JPEG at [start], lowered by 10 to [floor]; then scaled down by a fifth and tried again, until under [limit].
    /// Returns the bytes and the picture they hold.
    static func encodeUnder(_ image: CGImage, limit: Int, start: Int, floor: Int) throws -> ([UInt8], CGImage) {
        var current = image
        for _ in 0..<shrinks {
            var q = start
            while q >= floor {
                var out = try jpeg(current, quality: q)
                if out.count <= limit { return (out, current) }
                zero(&out) // a rejected attempt: the app's own copy zeroed
                q -= PhotoLimits.qualityStep
            }
            let edge = max(current.width, current.height)
            current = try plain(current, longEdge: max(1, Int((Double(edge) * shrink).rounded())))
        }
        throw PhotoError(.cannotFit)
    }
}
