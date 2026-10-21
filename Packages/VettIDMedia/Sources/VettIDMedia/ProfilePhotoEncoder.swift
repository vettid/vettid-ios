import CoreGraphics
import Foundation
import ImageIO

/// Pixels this app allocated and can zero in place (``wipe()``): the memory a ``ShotImage``'s picture reads from. Freed,
/// zeroed first, once neither the shot nor its picture holds it.
final class PixelBuffer: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let count: Int
    private let lock = NSLock()

    init(count: Int) {
        self.count = count
        base = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1))
    }

    deinit {
        zero()
        base.deallocate()
    }

    func zero() {
        lock.withLock {
            let p = base.bindMemory(to: UInt8.self, capacity: count)
            for i in 0..<count { p[i] = 0 }
        }
    }

    var isZero: Bool {
        lock.withLock {
            let p = base.bindMemory(to: UInt8.self, capacity: count)
            for i in 0..<count where p[i] != 0 { return false }
            return true
        }
    }
}

/// A camera shot for the profile photo (vettid-android `PhotoCaptureUiState.shot`), decoded upright into pixels in
/// memory: never a file, never printed. ``wipe()`` zeroes its pixels in place when it is retaken, dropped or encoded
/// (vettid-android recycles the bitmap). The picture (``image``) reads those pixels without a copy; what CoreGraphics
/// caches of it while it is drawn is its own and goes with the picture (released, not zeroed).
public final class ShotImage: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    /// vettid-android `SHOT_SIDE`: the shot is scaled so that its shorter side is at most this.
    public static let shortSide = 1_536

    public let image: CGImage
    private let pixels: PixelBuffer

    public var width: Int { image.width }
    public var height: Int { image.height }

    private init(image: CGImage, pixels: PixelBuffer) {
        self.image = image
        self.pixels = pixels
    }

    /// Zeroes the pixels in place. The picture shows black from then on.
    public func wipe() { pixels.zero() }

    /// Whether every pixel byte is zero (wiped).
    public var isWiped: Bool { pixels.isZero }

    public var description: String { "ShotImage(\(width)×\(height))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// The camera's shot (its encoded bytes, in memory) for review: the bounds read first (16,384 a side, 100 MP), decoded
    /// with its orientation applied, scaled so that its shorter side is at most [shortSide], and, for the front camera,
    /// [mirrored] as the preview showed it (vettid-android `uprightShot`). The camera's metadata is not carried: only
    /// pixels are kept.
    public static func decode(_ bytes: [UInt8], mirrored: Bool, shortSide: Int = shortSide) throws -> ShotImage {
        guard let declared = ImageHeader.dimensions(bytes) ?? sourceDimensions(bytes) else { throw PhotoError(.unsupported) }
        guard declared.within(maxSide: PhotoLimits.sourceMaxSide, maxPixels: PhotoLimits.sourceMaxPixels) else {
            throw PhotoError(.tooLarge)
        }
        let long = max(declared.width, declared.height)
        let short = max(1, min(declared.width, declared.height))
        let edge = short <= shortSide ? long : max(1, Int(Double(long) * Double(shortSide) / Double(short)))
        let bounds = Photos.Bounds(maxSide: PhotoLimits.sourceMaxSide, maxPixels: PhotoLimits.sourceMaxPixels)
        let decoded = try Photos.decode(bytes, bounds, targetLongEdge: edge, expected: nil, failure: .unsupported)
        return try of(decoded, mirrored: mirrored)
    }

    /// [image] drawn into pixels of its own (8-bit sRGB, no alpha, on white), [mirrored] left to right.
    public static func of(_ image: CGImage, mirrored: Bool = false) throws -> ShotImage {
        let w = image.width
        let h = image.height
        let bounded = Dimensions(width: w, height: h).within(maxSide: PhotoLimits.sourceMaxSide, maxPixels: PhotoLimits.sourceMaxPixels)
        guard w > 0, h > 0, bounded, let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw PhotoError(.unreadable) }
        let rowBytes = w * 4
        let pixels = PixelBuffer(count: rowBytes * h)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: pixels.base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes, space: space, bitmapInfo: info
        ) else { throw PhotoError(.unreadable) }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if mirrored {
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The picture reads the buffer in place; the provider holds it until the picture goes.
        guard let picture = picture(pixels, w, h) else { throw PhotoError(.unreadable) }
        return ShotImage(image: picture, pixels: pixels)
    }

    /// A picture reading [pixels] in place (8-bit sRGB, no alpha); its provider holds them until the picture goes.
    static func picture(_ pixels: PixelBuffer, _ w: Int, _ h: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let retained = Unmanaged.passRetained(pixels).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: retained, data: pixels.base, size: pixels.count,
            releaseData: { info, _, _ in if let info { Unmanaged<PixelBuffer>.fromOpaque(info).release() } }
        ) else {
            Unmanaged<PixelBuffer>.fromOpaque(retained).release()
            return nil
        }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// TEST ONLY: a new picture over the same pixels (none of CoreGraphics' cache of ``image``).
    func freshPicture() -> CGImage? { Self.picture(pixels, width, height) }

    /// ImageIO's own header, for a type ``ImageHeader`` does not read (HEIC).
    private static func sourceDimensions(_ bytes: [UInt8]) -> Dimensions? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, options),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, options) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return Dimensions(width: w, height: h)
    }
}

/// The member's profile photo (VAULT-MESSAGING §10.8): `photo` is the standard base64 of a JPEG or PNG of at most 65,536
/// bytes. ``encode(_:crop:maxBytes:)`` makes it from the square the member kept: scaled down and re-encoded as JPEG, the
/// quality (then the side) lowered until it fits the limit. Re-encoding from pixels writes no metadata, and the encoder's
/// own segments are removed (``JpegSegments/stripped(_:)``), so no EXIF, location or camera data leaves the phone.
/// Decoding a photo for display is VettIDUI's `ProfilePhotos.decode`. Mirrors vettid-android `ProfilePhotos.encode`.
public enum ProfilePhotoEncoder {
    /// §10.8: at most 65,536 bytes of image.
    public static let maxBytes = 65_536

    /// The side the member's photo is encoded at first (smaller sides are tried if the qualities do not fit). The crop
    /// under the review's round frame is never smaller than this, so the photo is never scaled up into blur.
    public static let targetSide = 512

    static let sides = [targetSide, 384, 256, 192, 128, 96]
    static let qualities = [85, 75, 65, 55, 45, 35]

    /// The JPEG bytes for `profile.set{photo}` of the square [crop] of [image] (its pixels, from the top left; the centred
    /// square when nil), at most [maxBytes], without metadata.
    public static func encode(_ image: CGImage, crop: CGRect? = nil, maxBytes: Int = maxBytes) throws -> [UInt8] {
        let rect = crop ?? centreSquare(image.width, image.height)
        guard rect.width >= 1, rect.height >= 1, let square = image.cropping(to: rect.integral) else { throw PhotoError(.unreadable) }
        for side in sides {
            let scaled = try opaque(square, side: min(side, max(square.width, square.height)))
            for q in qualities {
                let out = try Photos.jpeg(scaled, quality: q)
                if out.count <= maxBytes, !JpegSegments.hasMetadata(out), ImageType.sniff(out) == .jpeg { return out }
            }
        }
        throw PhotoError(.cannotFit)
    }

    /// The centred square of a picture of [w]×[h].
    public static func centreSquare(_ w: Int, _ h: Int) -> CGRect {
        let side = min(w, h)
        return CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
    }

    /// [image] at [side]×[side] in a plain 8-bit sRGB bitmap, drawn on white (JPEG has no alpha: a transparent picture on
    /// white rather than black).
    static func opaque(_ image: CGImage, side: Int) throws -> CGImage {
        let s = max(1, side)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { throw PhotoError(.unreadable) }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: s, height: s))
        guard let out = ctx.makeImage() else { throw PhotoError(.unreadable) }
        return out
    }
}
