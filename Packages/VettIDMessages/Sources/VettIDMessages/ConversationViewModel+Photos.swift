import Foundation
import VettIDData
import VettIDMedia

// The photos of a conversation (VAULT-MESSAGING §10.5.1; ANDROID-PLAN "Photo attachments"): pictures picked or taken,
// prepared in memory one at a time, sent one after another (the caption with the first), retried as the same request,
// cancelled with a discard, and dropped at every clear of the attachment memory. Mirrors the photo part of vettid-android
// `ConversationViewModel`.
extension ConversationViewModel {
    /// A picked picture's reader: its bytes in memory, nil when it cannot be read. Called one at a time.
    public typealias PhotoSource = @Sendable () async -> [UInt8]?

    public func startCapture() { local.capturing = true }

    public func stopCapture() { local.capturing = false }

    /// Pictures the Photos picker handed over, read into memory and prepared one at a time (bounds, orientation, JPEG,
    /// thumbnail): only one source and one prepared photo are being worked on at once. A pick that cannot be read or
    /// prepared is counted and said.
    public func onPicked(_ sources: [PhotoSource]) {
        guard let attachments, !sources.isEmpty else { return }
        photosCancelled = false
        local.photoDraft = PhotoDraft(preparing: true)
        photoTask = work.launch { [weak self] in await self?.preparePicks(Array(sources.prefix(PhotoDraft.maxPhotos)), attachments) }
    }

    /// A shot from the app's camera, encoded in memory (never a file); zeroed here once prepared.
    public func onShot(_ shot: [UInt8]) {
        guard let attachments else { return }
        photosCancelled = false
        local.capturing = false
        local.photoDraft = PhotoDraft(preparing: true)
        photoTask = work.launch { [weak self] in await self?.preparePicks([{ shot }], attachments, camera: true) }
    }

    public func setPhotoCaption(_ v: String) {
        local.photoDraft?.caption = v
        local.photoDraft?.problem = nil
    }

    /// Sends the draft's photos one after another, each as its own message, the caption with the first; the next upload
    /// starts after the previous message's answer. A lost answer stops with Retry offered (the same request, no new
    /// upload); a full mailbox or vault says so; any other refusal ends that photo. Cancel is offered only between requests
    /// (``PhotoDraft/inFlight``); a cancel stops the loop before the next photo is begun.
    public func sendPhotos() {
        guard let attachments, let draft = local.photoDraft, !draft.sending, !draft.preparing, !draft.photos.isEmpty else { return }
        photosCancelled = false
        var d = draft
        d.sending = true
        d.problem = nil
        d.retry = false
        local.photoDraft = d
        photoTask = work.launch { [weak self] in await self?.sendLoop(d, attachments) }
    }

    /// Cancel: no further photo is begun, an upload not yet sent is discarded at the vault, and the prepared photos are
    /// wiped. Not while a request is on its way (the vault may already act on it): the screen disables it then.
    public func cancelPhotos() {
        guard local.photoDraft?.inFlight != true else { return }
        dropPhotos(discard: true)
    }

    public func dismissPhotoProblem() {
        guard let d = local.photoDraft else { return }
        if d.photos.isEmpty {
            local.photoDraft = nil
        } else {
            local.photoDraft?.problem = nil
        }
    }

    /// A message's thumbnail, from memory or fetched (`part: "thumb"`); nil when it cannot be had.
    public func thumbnail(_ messageID: String) async -> [UInt8]? {
        guard let attachments else { return nil }
        if let t = attachments.cachedThumbnail(connectionID, messageID: messageID) { return t }
        return try? await attachments.thumbnail(connectionID, messageID: messageID)
    }

    // MARK: - Internals

    func preparePicks(_ sources: [PhotoSource], _ attachments: any AttachmentsRepository, camera: Bool = false) async {
        var ready: [PreparedPhoto] = []
        var problem: PhotoProblem?
        var failed = 0
        for read in sources {
            if photosCancelled || Task.isCancelled { break }
            let src = await read()
            if photosCancelled || Task.isCancelled { break }
            let (photo, failure) = await prepareOne(src, attachments)
            if let photo { ready.append(photo) }
            if let failure {
                failed += 1
                problem = failure
            }
        }
        if photosCancelled || Task.isCancelled {
            // Cancelled (Cancel, a clear, the screen gone): nothing prepared is kept.
            ready.forEach { $0.wipe() }
            photoHold.remove(ready)
            return
        }
        local.photoDraft = PhotoDraft(photos: ready, problem: problem, failedPicks: ready.isEmpty || camera ? 0 : failed)
    }

    /// Prepares one picked picture and zeroes its source; the problem when it cannot be used.
    private func prepareOne(_ src: [UInt8]?, _ attachments: any AttachmentsRepository) async -> (PreparedPhoto?, PhotoProblem?) {
        guard var src, !src.isEmpty else { return (nil, .unreadable) }
        defer { src.withUnsafeMutableBufferPointer { p in for i in p.indices { p[i] = 0 } } }
        do {
            let p = try await attachments.prepare(src)
            photoHold.add(p)
            return (p, nil)
        } catch let e as PhotoError {
            return (nil, .of(e.failure))
        } catch {
            return (nil, .unreadable)
        }
    }

    func sendLoop(_ start: PhotoDraft, _ attachments: any AttachmentsRepository) async {
        var d = start
        while let first = d.photos.first {
            if photosCancelled { return }
            let p = photoHold.pending ?? attachments.begin(
                connectionID, caption: d.sent == 0 ? d.caption.trimmingCharacters(in: .whitespacesAndNewlines) : "", photo: first
            )
            photoHold.pending = p
            local.photoDraft?.inFlight = true
            do {
                try await attachments.send(p)
                photoHold.pending = nil
                photoHold.remove([first])
                d.photos.removeFirst()
                d.sent += 1
                if photosCancelled { return }
                d.inFlight = false
                local.photoDraft = d
            } catch {
                if photosCancelled { return }
                local.photoDraft = refused(error, &d, first)
                return
            }
        }
        local.photoDraft = nil
    }

    /// The draft after a refused send: a full mailbox or vault, a lost answer (Retry), or a final refusal, which drops
    /// that photo (the others wait for Send).
    private func refused(_ error: any Error, _ d: inout PhotoDraft, _ first: PreparedPhoto) -> PhotoDraft {
        let f = error as? VaultFailure ?? VaultFailure(.other)
        let retry = AttachmentManager.retryable(f)
        let quota = f.code == AttachmentManager.codeQuota
        let problem: PhotoProblem = quota ? .mailboxFull : f.kind == .limit ? .vaultFull : retry ? .noAnswer : .notSent
        if !retry, !quota {
            photoHold.pending = nil
            photoHold.remove([first])
            first.wipe()
            d.photos.removeFirst()
        }
        d.sending = false
        d.inFlight = false
        d.problem = problem
        d.retry = retry
        return d
    }

    /// Everything of the photos in this conversation goes: the draft, the pending upload, the camera.
    func dropPhotos(discard: Bool) {
        photosCancelled = true
        photoTask?.cancel()
        photoTask = nil
        let draft = local.photoDraft
        let p = photoHold.pending
        photoHold.pending = nil
        local.photoDraft = nil
        local.capturing = false
        if let p, discard { attachments?.abandon(p) }
        draft?.photos.forEach { $0.wipe() }
        photoHold.wipeAll()
    }

    /// A clear of the attachment memory (not the value seen when the conversation opened).
    func onCleared(_ generation: Int) {
        defer { photoHold.lastCleared = generation }
        guard let last = photoHold.lastCleared, last != generation else { return }
        dropPhotos(discard: false)
        local.photoGeneration = generation
    }
}

/// The photos a conversation holds, where its `deinit` reaches them: the prepared photos not sent yet and the upload on
/// its way. Leaving the conversation wipes the photos and abandons the upload (a discard at the vault).
final class PhotoHold: @unchecked Sendable {
    private let lock = NSLock()
    private var photos: [ObjectIdentifier: PreparedPhoto] = [:]
    private var pendingValue: PendingPhoto?
    private var lastClearedValue: Int?

    var pending: PendingPhoto? {
        get { lock.withLock { pendingValue } }
        set { lock.withLock { pendingValue = newValue } }
    }

    var lastCleared: Int? {
        get { lock.withLock { lastClearedValue } }
        set { lock.withLock { lastClearedValue = newValue } }
    }

    func add(_ p: PreparedPhoto) { lock.withLock { photos[ObjectIdentifier(p)] = p } }

    func remove(_ ps: [PreparedPhoto]) { lock.withLock { for p in ps { photos[ObjectIdentifier(p)] = nil } } }

    func wipeAll() {
        let all = lock.withLock {
            defer { photos = [:] }
            return Array(photos.values)
        }
        all.forEach { $0.wipe() }
    }

    func release(_ attachments: (any AttachmentsRepository)?) {
        wipeAll()
        let p = lock.withLock {
            defer { pendingValue = nil }
            return pendingValue
        }
        if let p, let attachments { Task { @MainActor in attachments.abandon(p) } }
    }
}
