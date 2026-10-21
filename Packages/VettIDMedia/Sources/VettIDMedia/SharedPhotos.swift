import Foundation
import Security

/// Photos the member chose to share with another app (ANDROID-PLAN "Saving and sharing leave VettID", 0.1.39), offered
/// from memory only: no file is written. Each offer has a random token; the share sheet's item asks for the bytes by
/// it when the chosen app reads them (``data(_:)``), and ``clear()`` (at a lock, the hold, a wipe, an unlink, or when
/// the viewer goes) withdraws every offer, after which every read is refused. Mirrors vettid-android `SharedPhotos`
/// without its content provider: iOS hands the bytes to the chosen app through the share sheet's item.
public final class SharedPhotos: @unchecked Sendable {
    /// The offers of this process.
    public static let shared = SharedPhotos()

    struct Offer {
        let bytes: PhotoBytes
        let type: ImageType
    }

    static let maxOffers = 4
    static let tokenBytes = 16

    private let lock = NSLock()
    private var offers: [String: Offer] = [:]
    /// Oldest first.
    private var order: [String] = []

    public init() {}

    /// Offers [bytes] (a copy) for one share; returns its token.
    public func offer(_ bytes: [UInt8], type: ImageType) -> String {
        let token = Self.newToken()
        var dropped: [Offer] = []
        lock.withLock {
            // At most a few offers at once: the oldest goes (zeroed) first.
            while order.count >= Self.maxOffers {
                if let o = offers.removeValue(forKey: order.removeFirst()) { dropped.append(o) }
            }
            order.append(token)
            offers[token] = Offer(bytes: PhotoBytes(bytes.withUnsafeBufferPointer { Array($0) }), type: type)
        }
        dropped.forEach { $0.bytes.wipe() }
        return token
    }

    /// The bytes of a live offer (a copy), nil once withdrawn.
    public func data(_ token: String) -> Data? {
        guard let o = lock.withLock({ offers[token] }) else { return nil }
        return o.bytes.withBytes { Data($0) }
    }

    /// The type of a live offer.
    public func type(_ token: String) -> ImageType? { lock.withLock { offers[token]?.type } }

    public func live(_ token: String) -> Bool { lock.withLock { offers[token] != nil } }

    /// Withdraws every offer (zeroed).
    public func clear() {
        let all: [Offer] = lock.withLock {
            let all = Array(offers.values)
            offers.removeAll()
            order.removeAll()
            return all
        }
        all.forEach { $0.bytes.wipe() }
    }

    static func newToken() -> String {
        var b = [UInt8](repeating: 0, count: tokenBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }
}
