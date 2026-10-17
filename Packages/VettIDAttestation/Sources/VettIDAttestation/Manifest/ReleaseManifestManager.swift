import Foundation

/// A release the vault unlocked into: its PCR0 and number.
public struct ReleaseRef: Equatable, Sendable {
    public let pcr0: String
    public let number: UInt64

    public init(pcr0: String, number: UInt64) {
        self.pcr0 = pcr0
        self.number = number
    }
}

/// What the app keeps about releases (VAULT-MESSAGING §11.10.6): public data, but its integrity matters. The
/// persistent store comes with the app's data layer; tests and a fresh install use ``InMemoryReleaseStateStore``.
public protocol ReleaseStateStore: AnyObject, Sendable {
    /// The highest manifest serial seen (0: none).
    var highestSerial: UInt64 { get set }
    /// The last verified served document (its exact bytes), or nil.
    var servedManifest: [UInt8]? { get set }
    /// When the manifest was last fetched and verified.
    var lastFetchAt: Date? { get set }
    /// The release the vault last unlocked into, or nil before the first unlock.
    var lastRelease: ReleaseRef? { get set }
}

/// A process-local ``ReleaseStateStore``.
public final class InMemoryReleaseStateStore: ReleaseStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var serial: UInt64 = 0
    private var served: [UInt8]?
    private var fetched: Date?
    private var last: ReleaseRef?

    public init() {}

    public var highestSerial: UInt64 {
        get { lock.withLock { serial } }
        set { lock.withLock { serial = newValue } }
    }

    public var servedManifest: [UInt8]? {
        get { lock.withLock { served } }
        set { lock.withLock { served = newValue } }
    }

    public var lastFetchAt: Date? {
        get { lock.withLock { fetched } }
        set { lock.withLock { fetched = newValue } }
    }

    public var lastRelease: ReleaseRef? {
        get { lock.withLock { last } }
        set { lock.withLock { last = newValue } }
    }
}

/// What the app does before sending a PIN to a routed release (§11.2 step 4, §11.10.6).
public enum UnlockDecision: Equatable, Sendable {
    /// The release the vault last unlocked into (or the first one): send the PIN.
    case proceed(Release)
    /// A newer listed release: the vault was moved from another device; tell the user first.
    case updated(from: ReleaseRef, release: Release)
    /// Deprecated or retired: show the status and `ends_at`, offer the newest active release.
    case endOfLife(Release, newest: Release?)
    /// Removed: the release has ended; the vault can no longer be opened there.
    case removed(Release)
}

/// Keeps the verified release manifest and the release rules of VAULT-MESSAGING §11.2 and §11.10.6: the signed
/// manifest is the only source of trusted PCRs, there is no bundled fallback, the serial never goes back, and the
/// release the vault last unlocked into is remembered. Fetching is the caller's (the alternate channel): it passes the
/// served bytes to ``accept(_:now:)`` before each enroll and unlock. Mirrors vettid-android `ReleaseManifestManager`.
public final class ReleaseManifestManager: @unchecked Sendable {
    public static let refreshInterval: TimeInterval = 24 * 3600

    private let verifier: ManifestVerifier
    private let store: ReleaseStateStore
    private let lock = NSLock()

    public init(verifier: ManifestVerifier, store: ReleaseStateStore) {
        self.verifier = verifier
        self.store = store
    }

    /// Verifies a freshly fetched served document (signature under a pinned key, strict format) and applies the
    /// serial rule against the highest serial seen; on success stores it and raises the serial.
    public func accept(_ served: [UInt8], now: Date) throws -> ReleaseManifest {
        try lock.withLock {
            let m = try verifier.verify(served)
            try m.checkSerial(seen: store.highestSerial)
            store.highestSerial = m.serial
            store.servedManifest = served
            store.lastFetchAt = now
            return m
        }
    }

    /// The cached manifest, verified again (nil if none, or if it no longer verifies).
    public func cached() -> ReleaseManifest? {
        lock.withLock {
            guard let b = store.servedManifest, let m = try? verifier.verify(b), m.serial >= store.highestSerial else { return nil }
            return m
        }
    }

    /// Whether a background refresh is due (enroll and unlock always fetch first).
    public func refreshDue(now: Date, interval: TimeInterval = refreshInterval) -> Bool {
        guard let last = store.lastFetchAt else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Enrollment goes only to an `active` release (§11.2 step 2, §11.10.1).
    public func checkEnroll(_ m: ReleaseManifest, pcr0: String) throws -> Release {
        guard let r = m.byPcr0(pcr0) else { throw AttestationError.release("not listed", unknown: true) }
        guard r.status == .active else { throw AttestationError.release("not active") }
        return r
    }

    /// Decides what to do before sending a PIN to [pcr0], the release the API routed to. A release absent from the
    /// manifest, or one with a lower number than the release last unlocked into (a rollback), is refused.
    public func decideUnlock(_ m: ReleaseManifest, pcr0: String) throws -> UnlockDecision {
        try lock.withLock {
            guard let r = m.byPcr0(pcr0) else { throw AttestationError.release("not listed", unknown: true) }
            let last = store.lastRelease
            if let last, r.number < last.number { throw AttestationError.release("rollback") }
            if r.status == .removed { return .removed(r) }
            if let last, r.number > last.number { return .updated(from: last, release: r) }
            if r.status == .deprecated || r.status == .retired { return .endOfLife(r, newest: m.newest()) }
            return .proceed(r)
        }
    }

    /// Records the release a successful unlock reached (or a confirmed move or abandon).
    public func recordUnlocked(_ r: Release) {
        lock.withLock { store.lastRelease = ReleaseRef(pcr0: r.pcr0, number: r.number) }
    }
}
