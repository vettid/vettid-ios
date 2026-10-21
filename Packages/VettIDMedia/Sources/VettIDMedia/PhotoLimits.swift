import Foundation

/// The bounds of ANDROID-PLAN "Photo attachments" (0.1.39) and VAULT-MESSAGING §10.5.1's release constants. Mirrors
/// vettid-android `PhotoLimits`.
public enum PhotoLimits {
    /// A picked or taken picture larger than this on a side is refused before it is decoded ("too large to send").
    public static let sourceMaxSide = 16_384
    /// … or larger than this many pixels.
    public static let sourceMaxPixels: Int64 = 100_000_000
    /// The most bytes read from a picked picture into memory.
    public static let sourceMaxBytes = 64 * 1_024 * 1_024

    /// The long edge of a sent photo.
    public static let sendLongEdge = 2_560
    /// `attachment_max_bytes` at vettid.org: the largest content whose blob fits the relay's 8 MiB.
    public static let attachmentMaxBytes = 8_257_532
    /// The relay's `max_blob_bytes`: a fetched blob larger than this is refused before it is hashed.
    public static let maxBlobBytes = 8_388_608

    /// The JPEG quality a photo starts at, lowered in steps until it fits.
    public static let sendQuality = 85
    public static let minQuality = 40
    public static let qualityStep = 10

    /// The thumbnail's long edge and its bound (`thumb_max_bytes`).
    public static let thumbLongEdge = 320
    public static let thumbMaxBytes = 32_768
    public static let thumbQuality = 80
    public static let thumbMinQuality = 20

    /// A received photo: `photo_max_side` and 40 megapixels; nothing larger is decoded.
    public static let viewMaxSide = 8_192
    public static let viewMaxPixels: Int64 = 40_000_000

    /// A received thumbnail: the sender makes 320, anything over 1,024 on a side is refused from its header.
    public static let thumbViewMaxSide = 1_024
    public static let thumbViewMaxPixels: Int64 = 1_024 * 1_024

    /// A sent name, as shown: at most 64 characters.
    public static let nameMaxChars = 64

    /// The memory-only caches: photos, and thumbnails.
    public static let photoCacheBytes = 64 * 1_024 * 1_024
    public static let thumbCacheBytes = 8 * 1_024 * 1_024
}

/// A peer's `name` made safe to show; it is never used as a file name. Mirrors vettid-android `AttachmentNames`.
public enum AttachmentNames {
    private static let bidi: Set<UInt32> = Set([0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069))

    /// Removes control and bidirectional formatting characters (and every other format character, zero-width ones
    /// included), path separators and leading dots; trims; at most ``PhotoLimits/nameMaxChars`` characters (Unicode
    /// scalars, never cut in half). Nil when nothing is left.
    public static func sanitize(_ name: String?) -> String? {
        guard let name else { return nil }
        var kept = String.UnicodeScalarView()
        for s in name.unicodeScalars where !drops(s) { kept.append(s) }
        var s = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        guard s.unicodeScalars.count > PhotoLimits.nameMaxChars else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.prefix(PhotoLimits.nameMaxChars)))
    }

    private static func drops(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control, .format, .unassigned, .lineSeparator, .paragraphSeparator: return true
        default: return bidi.contains(s.value) || s == "/" || s == "\\"
        }
    }
}

/// A memory-only cache bounded by bytes, least recently used out first (ANDROID-PLAN "Memory only, wiped at lock"):
/// thumbnails, photos and prepared uploads never go to a file, a database, the defaults or an image library's disk
/// cache. ``clear()`` runs at lock, on entering the hold or the due state, at a wipe and at an unlink; [onEvict] zeroes
/// what it can. Mirrors vettid-android `MemoryCache`.
public final class MemoryCache<Key: Hashable & Sendable, Value: AnyObject>: @unchecked Sendable {
    public let maxBytes: Int
    private let sizeOf: (Value) -> Int
    private let onEvict: (Value) -> Void
    private let lock = NSLock()
    private var map: [Key: Value] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private var bytes = 0

    public init(maxBytes: Int, sizeOf: @escaping (Value) -> Int, onEvict: @escaping (Value) -> Void = { _ in }) {
        self.maxBytes = maxBytes
        self.sizeOf = sizeOf
        self.onEvict = onEvict
    }

    public var count: Int { lock.withLock { map.count } }

    public var usedBytes: Int { lock.withLock { bytes } }

    /// The value for [key], now the most recently used.
    public func get(_ key: Key) -> Value? {
        lock.withLock {
            guard let v = map[key] else { return nil }
            touch(key)
            return v
        }
    }

    /// Keeps [value] unless it alone exceeds the bound; evicts the least recently used until it fits. The same object put
    /// again is not evicted (its bytes would be zeroed under the caller).
    public func put(_ key: Key, _ value: Value) {
        var evicted: [Value] = []
        lock.withLock {
            let n = sizeOf(value)
            if let old = map.removeValue(forKey: key) {
                order.removeAll { $0 == key }
                bytes -= sizeOf(old)
                if old !== value { evicted.append(old) }
            }
            if n <= maxBytes {
                map[key] = value
                order.append(key)
                bytes += n
                while bytes > maxBytes, let oldest = order.first, oldest != key {
                    order.removeFirst()
                    if let v = map.removeValue(forKey: oldest) {
                        bytes -= sizeOf(v)
                        evicted.append(v)
                    }
                }
            }
        }
        evicted.forEach(onEvict)
    }

    public func remove(_ key: Key) {
        let v: Value? = lock.withLock {
            order.removeAll { $0 == key }
            guard let v = map.removeValue(forKey: key) else { return nil }
            bytes -= sizeOf(v)
            return v
        }
        if let v { onEvict(v) }
    }

    /// Drops everything (``onEvict`` zeroes what it can).
    public func clear() {
        let all: [Value] = lock.withLock {
            let all = Array(map.values)
            map.removeAll()
            order.removeAll()
            bytes = 0
            return all
        }
        all.forEach(onEvict)
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
