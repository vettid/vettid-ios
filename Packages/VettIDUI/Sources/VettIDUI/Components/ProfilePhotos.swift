import ImageIO
import UIKit

/// Profile photos (VAULT-MESSAGING §10.8): `photo` is the standard base64 of a JPEG or PNG of at most 65,536 bytes.
///
/// ``decode(_:)`` reads a photo for display (the member's own, or a peer's self-asserted one) defensively: over the
/// size limit, not a JPEG or PNG, undecodable, or with absurd dimensions, it is nil and the initial tile is shown.
/// Encoding the member's own photo is VettIDMedia's `ProfilePhotoEncoder`.
///
/// Mirrors vettid-android `core/ui/…/components/ProfilePhotos.kt` (decoding).
public enum ProfilePhotos {
    /// §10.8: at most 65,536 bytes of image.
    public static let maxBytes = 65_536

    /// Dimensions a peer's photo may declare before it is refused unread (a decompression bomb).
    static let maxDecodeSide = 4_096
    /// The side a photo is decoded down to for display (tiles are at most 88 pt).
    static let displaySide = 256
    /// Base64 of 65,536 bytes is 87,384 characters: anything longer is over the limit, unread.
    static let maxBase64Chars = (maxBytes + 2) / 3 * 4

    /// A photo from the vault for display, or nil (absent, too large, not a JPEG or PNG, undecodable). The decoded image
    /// bytes are zeroed once the image is made (or refused): no copy of the photo's file stays in memory after it
    /// (IOS-PLAN §4.7).
    public static func decode(_ base64: String?) -> UIImage? {
        guard let base64, !base64.isEmpty, base64.utf8.count <= maxBase64Chars, var bytes = Data(base64Encoded: base64) else {
            return nil
        }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard bytes.count <= maxBytes, isJPEG(bytes) || isPNG(bytes) else { return nil }
        return bytes.withUnsafeBytes { image(of: $0) }
    }

    /// [bytes] of a JPEG or PNG of at most ``maxBytes`` for display (a taken photo before it is saved), or nil; the caller
    /// keeps (and zeroes) the bytes.
    public static func decodeImage(_ bytes: [UInt8]) -> UIImage? {
        let known = (bytes.count > jpeg.count && bytes.starts(with: jpeg)) || (bytes.count > png.count && bytes.starts(with: png))
        guard known, bytes.count <= maxBytes else { return nil }
        return bytes.withUnsafeBytes { image(of: $0) }
    }

    /// The image of [raw], read in place (no copy the zeroing would miss), decoded down to the display size.
    private static func image(of raw: UnsafeRawBufferPointer) -> UIImage? {
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
              let data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, base, raw.count, kCFAllocatorNull),
              let source = CGImageSourceCreateWithData(data, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              sane(width), sane(height)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(displaySide, 1) * 2,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// ``decode(_:)`` off the main actor (vettid-android `rememberProfilePhoto` decodes once per distinct photo).
    public static func decoded(_ base64: String?) async -> UIImage? {
        guard let base64 else { return nil }
        return await Task.detached { decode(base64) }.value
    }

    static func sane(_ side: Int) -> Bool { (1...maxDecodeSide).contains(side) }

    public static func isJPEG(_ b: Data) -> Bool { b.count > jpeg.count && b.prefix(jpeg.count).elementsEqual(jpeg) }
    public static func isPNG(_ b: Data) -> Bool { b.count > png.count && b.prefix(png.count).elementsEqual(png) }

    private static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
    private static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
}
