import ImageIO
import SwiftUI
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

/// Decoded profile photos for list rows, kept in memory only (IOS-PLAN §4.7; a photo is vault data, so the cache is emptied
/// when the vault is no longer open, ``clear()``). A row asks for a photo with ``cached(_:)`` (at once, from the cache) or
/// ``image(_:)`` (decoded off the main actor, down to the tile size by ``ProfilePhotos/decode(_:)``).
///
/// (Chosen; not in the spec: 128 photos at most, evicted by the system under memory pressure; vettid-android decodes once per
/// distinct photo, `rememberProfilePhoto`.)
@MainActor
public final class ProfilePhotoCache {
    public static let shared = ProfilePhotoCache()

    static let limit = 128

    private let store: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = limit
        return cache
    }()
    /// Bumped by ``clear()``: a decode that was under way is not stored after it.
    private var generation = 0

    init() {}

    /// The photo [base64] decoded earlier, if it is still held.
    public func cached(_ base64: String?) -> UIImage? {
        guard let base64, !base64.isEmpty else { return nil }
        return store.object(forKey: base64 as NSString)
    }

    /// The photo [base64], decoded off the main actor unless it is held; nil when it does not decode (the initial tile shows).
    public func image(_ base64: String?) async -> UIImage? {
        guard let base64, !base64.isEmpty else { return nil }
        if let held = store.object(forKey: base64 as NSString) { return held }
        let started = generation
        guard let image = await ProfilePhotos.decoded(base64) else { return nil }
        if started == generation { store.setObject(image, forKey: base64 as NSString) }
        return image
    }

    /// Drops every photo, and the ones being decoded: the vault is no longer open.
    public func clear() {
        generation += 1
        store.removeAllObjects()
    }
}

/// A row's photo, loaded off the main actor: [content] gets the cached photo at once, else nil (the initial tile) until the
/// photo is decoded, then the photo. A photo that changes is loaded again; the row is not blocked meanwhile.
public struct ProfilePhotoLoading<Content: View>: View {
    private let base64: String?
    private let content: (UIImage?) -> Content
    @State private var loaded: UIImage?

    public init(_ base64: String?, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.base64 = base64
        self.content = content
    }

    public var body: some View {
        content(loaded ?? ProfilePhotoCache.shared.cached(base64))
            .task(id: base64) {
                loaded = nil
                loaded = await ProfilePhotoCache.shared.image(base64)
            }
    }
}
