import Foundation
import Observation
import VettIDCrypto
import VettIDMedia
import VettIDVault

/// Photo attachments over the vault client (VAULT-MESSAGING §10.5.1, ANDROID-PLAN "Photo attachments"). Thumbnails,
/// photos and prepared uploads are in memory only (``MemoryCache``, at most 64 MiB of photos and 8 MiB of thumbnails),
/// never in a file: nothing of a photo is written to the phone. Mirrors vettid-android `AttachmentManager`.
@MainActor
@Observable
public final class AttachmentManager: AttachmentsRepository {
    public private(set) var available = false
    public private(set) var cleared = 0

    @ObservationIgnored let ops: @MainActor () async throws -> any AttachmentOps
    @ObservationIgnored let quietOps: @MainActor () async throws -> any AttachmentOps
    /// A sent photo's message joins its conversation (``MessagesManager/addSent(_:)``).
    @ObservationIgnored let onSent: @MainActor (MessageInfo) -> Void
    @ObservationIgnored let newRequestID: @Sendable () -> String
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored let shared: SharedPhotos
    @ObservationIgnored let thumbs = MemoryCache<String, PhotoBytes>(maxBytes: PhotoLimits.thumbCacheBytes, sizeOf: { $0.count }) {
        $0.wipe()
    }
    @ObservationIgnored let photos = MemoryCache<String, FetchedPhoto>(maxBytes: PhotoLimits.photoCacheBytes, sizeOf: { $0.bytes.count }) {
        $0.wipe()
    }
    @ObservationIgnored var pending: [ObjectIdentifier: PendingPhoto] = [:]
    /// `attachment_fetches`: at most 2 `content` fetches of this device at once (§10.5.1).
    @ObservationIgnored let fetches = Gate(permits: AttachmentManager.maxFetches)

    /// The relay refused the upload: the vault's mailbox is full.
    public static let codeQuota = "quota_exceeded"
    /// A fetched blob failed its checks (hash, length, padding, decryption).
    public static let codeBad = "bad"
    /// Not JPEG, PNG or WebP by its bytes.
    public static let codeType = "type"
    static let codeAlreadySent = "already_sent"
    static let codeNoUpload = "no_upload"
    static let maxFetches = 2
    static let keyBytes = 32

    /// [ops] the vault's calls, opened when needed; [quietOps] those of the probe (only over the session already open;
    /// nil: [ops]); [onSent] a sent photo's message.
    public init(
        ops: @escaping @MainActor () async throws -> any AttachmentOps,
        quietOps: (@MainActor () async throws -> any AttachmentOps)? = nil,
        onSent: @escaping @MainActor (MessageInfo) -> Void = { _ in },
        newRequestID: @escaping @Sendable () -> String = { Ulid.new() },
        now: @escaping @Sendable () -> Date = { Date() },
        shared: SharedPhotos = .shared
    ) {
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.onSent = onSent
        self.newRequestID = newRequestID
        self.now = now
        self.shared = shared
    }

    /// Whether a failed `message.send` is retried as the same request: no answer, `busy`, or a relay error.
    public static func retryable(_ e: VaultFailure) -> Bool {
        e.kind == .noResponse || e.kind == .network || e.code == "busy" || e.code == "relay_error"
    }

    /// Caches are keyed by conversation and message: a message id is unique only within its connection.
    func key(_ connectionID: String, _ messageID: String) -> String { connectionID + "\u{0}" + messageID }

    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one).
    func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    // MARK: - AttachmentsRepository

    public func probe() async {
        let supported = try? await guarded { try await quietOps().attachmentsSupported() }
        available = supported == true
    }

    public func prepare(_ source: [UInt8]) async throws -> PreparedPhoto {
        try await Task.detached(priority: .userInitiated) { try Photos.prepare(source) }.value
    }

    public func begin(_ connectionID: String, caption: String, photo: PreparedPhoto) -> PendingPhoto {
        let p = PendingPhoto(connectionID: connectionID, caption: caption, photo: photo, requestID: newRequestID())
        pending[ObjectIdentifier(p)] = p
        return p
    }

    /// One send of a photo at a time: a second waits for the first, then finds it sent or uploaded.
    @discardableResult
    public func send(_ p: PendingPhoto) async throws -> MessageInfo {
        let previous = p.tail
        let task = Task { @MainActor in
            await previous?.value
            return try await self.sendNow(p)
        }
        p.tail = Task { _ = try? await task.value }
        return try await task.value
    }

    public func cancel(_ p: PendingPhoto) async {
        let blob = p.blobID
        finish(p)
        guard let blob, !p.sent else { return }
        // Best effort: the upload expires after the blob TTL otherwise.
        try? await guarded { try await ops().messageAttachmentDiscard(blob) }
    }

    public func abandon(_ p: PendingPhoto) {
        Task { await self.cancel(p) }
    }

    public func cachedThumbnail(_ connectionID: String, messageID: String) -> [UInt8]? {
        thumbs.get(key(connectionID, messageID))?.copy()
    }

    public func thumbnail(_ connectionID: String, messageID: String) async throws -> [UInt8] {
        if let t = thumbs.get(key(connectionID, messageID)) { return t.copy() }
        let mark = cleared
        let t = try await guarded { try await ops().attachmentThumb(connectionID, messageID: messageID) }
        guard Self.acceptableThumb(t) else { throw VaultFailure(.other, code: Self.codeType) }
        if mark == cleared { thumbs.put(key(connectionID, messageID), PhotoBytes(t)) }
        return t
    }

    public func photo(_ connectionID: String, messageID: String) async throws -> FetchedPhoto {
        let k = key(connectionID, messageID)
        if let p = photos.get(k) { return FetchedPhoto(bytes: p.bytes.copy(), type: p.type) }
        let mark = cleared
        await fetches.acquire()
        defer { fetches.release() }
        let got = try await fetch(connectionID, messageID)
        let copy = FetchedPhoto(bytes: got.bytes.copy(), type: got.type)
        // Fetched after a clear (a lock meanwhile): handed to the screen that asked, which the clear told; not kept.
        if mark == cleared { photos.put(k, got) } else { got.wipe() }
        return copy
    }

    public func clear() {
        cleared += 1
        thumbs.clear()
        photos.clear()
        shared.clear() // every share offer is withdrawn: the share sheet's item refuses every read from now on
        for p in pending.values { p.wipe() }
        pending = [:]
    }

    /// Clears and forgets that the vault has attachments (signed out, a wipe, or another vault).
    public func reset() {
        clear()
        available = false
    }

    /// A thumbnail that arrived inline in `message.new` (§10.5.1), kept in memory.
    public func onEvent(_ m: VaultMessage) {
        guard m.type == "message.new", let msg = Message.of(m.object), let b64 = msg.attachmentView?.thumb,
              let bytes = try? Base64s.decodeStd(b64), Self.acceptableThumb(bytes) else { return }
        thumbs.put(key(msg.connectionID, msg.messageID), PhotoBytes(bytes))
    }

    /// 1 to `thumb_max_bytes`, and JPEG, PNG or WebP by its bytes.
    static func acceptableThumb(_ t: [UInt8]) -> Bool {
        !t.isEmpty && t.count <= PhotoLimits.thumbMaxBytes && ImageType.sniff(t) != nil
    }

    func finish(_ p: PendingPhoto) {
        pending[ObjectIdentifier(p)] = nil
        p.wipe()
    }
}

/// A counting gate on the main actor: at most [permits] holders at once, the others wait in order.
@MainActor
final class Gate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) { free = permits }

    func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            free += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
