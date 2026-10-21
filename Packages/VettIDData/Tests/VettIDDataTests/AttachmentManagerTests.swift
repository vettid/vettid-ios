import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDMedia
import VettIDRelay
@testable import VettIDVault

/// The vault calls of ``AttachmentManagerTests``: recorded, failing on demand, serving a sealed blob.
@MainActor
final class FakeAttachmentOps: AttachmentOps {
    var calls: [String] = []
    var uploads: [[UInt8]] = []
    struct Send {
        let requestID: String
        let text: String?
        let attachment: AttachmentSend
    }

    var sends: [Send] = []
    var sendFailures: [any Error] = []
    var uploadFailure: (any Error)?
    var supported: Bool? = true
    var served: [UInt8] = []
    var servedRef: BlobRef?
    /// When set, `message.send`, the thumb and the blob fetch wait for it (a request on its way).
    var gate: TestDeferred<Void>?
    /// Runs when an upload arrives (a clear while it is on its way).
    var uploadHook: (@MainActor () -> Void)?
    /// When set, the upload waits for it before answering.
    var uploadGate: TestDeferred<Void>?

    func attachmentsSupported() async throws -> Bool? { supported }

    func uploadBlob(_ blob: [UInt8]) async throws -> String {
        calls.append("upload")
        if let f = uploadFailure {
            uploadFailure = nil
            throw f
        }
        uploads.append(blob)
        uploadHook?()
        if let uploadGate { try await uploadGate.value() }
        return "blob\(uploads.count)"
    }

    func messageSendPhoto(
        _ connectionID: String, text: String?, attachment: AttachmentSend, requestID: String
    ) async throws -> SentAttachment {
        calls.append("send:\(requestID)")
        sends.append(Send(requestID: requestID, text: text, attachment: attachment))
        if let gate { try await gate.value() }
        if !sendFailures.isEmpty { throw sendFailures.removeFirst() }
        return SentAttachment(messageID: "M1", sentAt: "2026-10-15T10:00:00Z", attID: "ATT1")
    }

    func messageAttachmentDiscard(_ blobID: String) async throws { calls.append("discard:\(blobID)") }

    func attachmentThumb(_ connectionID: String, messageID: String) async throws -> [UInt8] {
        calls.append("thumb:\(messageID)")
        if let gate { try await gate.value() }
        return [0xFF, 0xD8, 0xFF, 1]
    }

    func attachmentContent(_ connectionID: String, messageID: String) async throws -> FetchedAttachment {
        calls.append("content:\(messageID)")
        return FetchedAttachment(blob: servedRef!, expiresAt: "2026-10-22T10:00:00Z")
    }

    func fetchBlob(_ blobID: String) async throws -> [UInt8] {
        calls.append("fetch:\(blobID)")
        if let gate { try await gate.value() }
        return served
    }

    func deleteBlob(_ blobID: String) async throws { calls.append("delete:\(blobID)") }

    func serve(_ content: [UInt8], flip: Bool = false, sizeOff: Int64 = 0) throws {
        let s = try ClaimBlob.seal(content)
        served = s.blob
        if flip { served[30] ^= 1 }
        servedRef = BlobRef(
            id: "B9", key: Base64s.encodeStd(s.key), sha256: Base64s.encodeStd(s.sha256), size: Int64(content.count) + sizeOff,
            mime: "image/png", name: "../x.png"
        )
    }
}

/// Sending, retrying, cancelling and fetching photos (VAULT-MESSAGING §10.5.1, ANDROID-PLAN "Photo attachments"). Mirrors
/// vettid-android `AttachmentManagerTest`.
@MainActor
@Suite struct AttachmentManagerTests {
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + (0..<500).map { UInt8($0 & 0xFF) }
    static let thumb: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDB] + [UInt8](repeating: 0, count: 50)
    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 7, count: 100)

    let ops = FakeAttachmentOps()
    let shared = SharedPhotos()
    let m: AttachmentManager
    let sent: SentBox

    @MainActor
    final class SentBox {
        var messages: [MessageInfo] = []
    }

    init() {
        let ops = ops, sent = SentBox(), ids = LockedCounter()
        self.sent = sent
        m = AttachmentManager(
            ops: { ops }, onSent: { sent.messages.append($0) }, newRequestID: { "REQ\(ids.next())" }, shared: shared
        )
    }

    func photo() -> PreparedPhoto { PreparedPhoto(jpeg: Self.jpeg, thumb: Self.thumb, width: 2_560, height: 1_920) }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    @Test func theProbeReadsReleaseAFromTheAnswer() async {
        await m.probe()
        #expect(m.available)
        ops.supported = false
        await m.probe()
        #expect(!m.available)
        ops.supported = nil
        await m.probe()
        #expect(!m.available)
    }

    @Test func aPhotoIsUploadedSealedAndSentWithItsReference() async throws {
        let p = m.begin("c1", caption: "caption", photo: photo())
        let msg = try await m.send(p)
        #expect(ops.calls == ["upload", "send:REQ1"])
        let att = try #require(ops.sends.first?.attachment)
        #expect(att.blobID == "blob1" && att.mime == "image/jpeg" && att.width == 2_560 && att.height == 1_920)
        #expect(!att.json.contains("\"name\""), "apps send no name for a photo")
        // What was uploaded opens with the reference sent.
        let opened = try ClaimBlob.open(try #require(ops.uploads.first), key: att.key, sha256: att.sha256, size: UInt64(att.size))
        #expect(opened == Self.jpeg && att.thumb == Self.thumb && ops.sends.first?.text == "caption")
        #expect(msg.messageID == "M1" && msg.attachment?.state == .preparing && msg.attachment?.attID == "ATT1")
        #expect(sent.messages == [msg])
        #expect(m.cachedThumbnail("c1", messageID: "M1") == Self.thumb, "the thumbnail is shown from memory")
        #expect(p.isWiped, "prepared bytes dropped after the answer")
    }

    @Test func retryReSendsTheSameInnerIdAndMakesNoUpload() async throws {
        ops.sendFailures = [VaultFailure(.noResponse), VaultOpError(type: "message.send", code: "busy", detail: "", body: nil)]
        let p = m.begin("c1", caption: "", photo: photo())
        #expect(await failure { try await m.send(p) }?.kind == .noResponse)
        #expect(p.uploaded)
        #expect(await failure { try await m.send(p) }?.code == "busy")
        try await m.send(p)
        #expect(ops.calls.count { $0 == "upload" } == 1)
        #expect(ops.calls.filter { $0.hasPrefix("send") } == ["send:REQ1", "send:REQ1", "send:REQ1"])
        #expect(ops.sends.first?.text == nil, "no caption: text absent")
    }

    @Test func cancelAfterTheUploadAsksTheVaultToDiscardIt() async {
        ops.sendFailures = [VaultFailure(.noResponse)]
        let p = m.begin("c1", caption: "", photo: photo())
        _ = await failure { try await m.send(p) }
        await m.cancel(p)
        #expect(ops.calls.last == "discard:blob1")
        #expect(p.isWiped)
    }

    @Test func cancelBeforeAnyUploadSendsNothing() async {
        let p = m.begin("c1", caption: "", photo: photo())
        await m.cancel(p)
        #expect(ops.calls.isEmpty && p.isWiped)
    }

    @Test func aFullMailboxIsNotRetriedUntilSendIsTappedAgain() async throws {
        ops.uploadFailure = RelayError(status: 409, code: RelayError.quotaExceeded, quota: "mailbox_blobs")
        let p = m.begin("c1", caption: "", photo: photo())
        let e = await failure { try await m.send(p) }
        #expect(e?.kind == .limit && e?.code == AttachmentManager.codeQuota)
        #expect(!p.uploaded && ops.calls == ["upload"])
        try await m.send(p) // the member taps Send again
        #expect(ops.calls == ["upload", "upload", "send:REQ1"])
    }

    @Test func aFinalRefusalEndsThePendingPhoto() async {
        ops.sendFailures = [VaultOpError(type: "message.send", code: "limit", detail: "", body: nil)]
        let p = m.begin("c1", caption: "", photo: photo())
        #expect(await failure { try await m.send(p) }?.kind == .limit)
        #expect(p.isWiped)
    }

    @Test func aFetchedPhotoIsCheckedDecryptedDeletedAndCached() async throws {
        try ops.serve(Self.png)
        let got = try await m.photo("c1", messageID: "M7")
        #expect(got.bytes.copy() == Self.png && got.type == .png)
        #expect(ops.calls == ["content:M7", "fetch:B9", "delete:B9"])
        _ = try await m.photo("c1", messageID: "M7")
        #expect(ops.calls.count == 3, "from memory the second time")
    }

    @Test func aBadBlobIsRefusedAndStillDeleted() async throws {
        try ops.serve([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 100), flip: true)
        #expect(await failure { try await m.photo("c1", messageID: "M8") }?.code == AttachmentManager.codeBad)
        #expect(ops.calls.last == "delete:B9")
        ops.calls = []
        try ops.serve([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 100), sizeOff: 1)
        #expect(await failure { try await m.photo("c1", messageID: "M8") }?.code == AttachmentManager.codeBad)
        #expect(ops.calls.last == "delete:B9")
    }

    @Test func aBlobThatIsNoPhotoByItsBytesIsRefused() async throws {
        try ops.serve(Array("GIF89a not accepted".utf8))
        #expect(await failure { try await m.photo("c1", messageID: "M9") }?.code == AttachmentManager.codeType)
    }

    @Test func clearWipesThumbnailsPhotosOffersAndPendingUploads() async throws {
        let p = m.begin("c1", caption: "", photo: photo())
        _ = try await m.thumbnail("c1", messageID: "M5")
        try ops.serve(Self.png)
        let kept = try await m.photo("c1", messageID: "M6")
        let token = shared.offer(kept.bytes.copy(), type: .png)
        m.clear() // a lock, the hold, a wipe or an unlink
        #expect(m.cachedThumbnail("c1", messageID: "M5") == nil)
        #expect(m.cleared == 1 && p.isWiped && !shared.live(token))
        #expect(m.thumbs.count == 0 && m.photos.count == 0 && m.pending.isEmpty, "the memory cache is empty after the lock")
        ops.calls = []
        _ = try await m.thumbnail("c1", messageID: "M5")
        #expect(ops.calls == ["thumb:M5"])
    }

    @Test func aThumbnailFromMessageNewIsKeptInMemory() throws {
        let b64 = Base64s.encodeStd(Self.thumb)
        let view = #"{"att_id":"A3","kind":"photo","size":10,"width":320,"height":240,"state":"fetching","thumb":"\#(b64)"}"#
        let head = #""connection_id":"c1","message_id":"M3","direction":"in","text":"","sent_at":"2026-10-15T10:00:00Z""#
        let body = "{\(head),\"attachment\":\(view)}"
        m.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "message.new", ts: Date(), body: Array(body.utf8))))
        #expect(m.cachedThumbnail("c1", messageID: "M3") == Self.thumb)
    }

    @Test func aMalformedReferenceIsABadBlobNotACrash() async throws {
        try ops.serve([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 10))
        let ref = try #require(ops.servedRef)
        ops.servedRef = BlobRef(id: ref.id, key: "not base64!", sha256: ref.sha256, size: ref.size)
        #expect(await failure { try await m.photo("c1", messageID: "M10") }?.code == AttachmentManager.codeBad)
        try ops.serve([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 10))
        let ref2 = try #require(ops.servedRef)
        ops.servedRef = BlobRef(id: ref2.id, key: ref2.key, sha256: Base64s.encodeStd([UInt8](repeating: 0, count: 31)), size: ref2.size)
        #expect(await failure { try await m.photo("c1", messageID: "M11") }?.code == AttachmentManager.codeBad)
        #expect(ops.calls.last == "delete:B9")
    }

    @Test func cachesAreKeyedByConversationAndHandOutCopies() async throws {
        let p = m.begin("c1", caption: "", photo: photo())
        try await m.send(p)
        #expect(m.cachedThumbnail("c2", messageID: "M1") == nil)
        var a = try #require(m.cachedThumbnail("c1", messageID: "M1"))
        a[0] = 9
        #expect(m.cachedThumbnail("c1", messageID: "M1") == Self.thumb)
        #expect(await failure { try await m.send(p) }?.code == "already_sent")
        #expect(ops.calls.count { $0 == "upload" } == 1)
    }

    /// An answer that arrives after a clear (the vault locked meanwhile) leaves nothing in memory and adds no message.
    @Test func anAnswerAfterAClearKeepsNothing() async throws {
        let gate = TestDeferred<Void>()
        ops.gate = gate
        try ops.serve(Self.png)
        let fetching = Task { try await m.photo("c1", messageID: "M6") }
        let thumbing = Task { try await m.thumbnail("c1", messageID: "M7") }
        let sending = Task { try await m.send(m.begin("c1", caption: "", photo: photo())) }
        #expect(await eventually { ops.calls.contains("fetch:B9") && ops.calls.contains("send:REQ1") && ops.calls.contains("thumb:M7") })
        m.clear()
        gate.complete()
        // A photo or a thumbnail that arrives across the clear is not shown either.
        #expect(await failure { try await fetching.value }?.code == AttachmentManager.codeUnavailable)
        #expect(await failure { try await thumbing.value }?.code == AttachmentManager.codeUnavailable)
        _ = try await sending.value
        #expect(m.photos.count == 0 && m.thumbs.count == 0)
        #expect(sent.messages.isEmpty && m.cachedThumbnail("c1", messageID: "M1") == nil)
    }

    /// Leaving the conversation while its photo uploads (abandon, then the upload's answer): the vault, still open, is
    /// asked to discard the upload at once, and nothing is sent with it.
    @Test func anUploadAbandonedOnItsWayIsDiscarded() async {
        let gate = TestDeferred<Void>()
        ops.uploadGate = gate
        let p = m.begin("c1", caption: "", photo: photo())
        let sending = Task { try await m.send(p) }
        #expect(await eventually { ops.calls == ["upload"] })
        await m.cancel(p) // the screen went: nothing uploaded yet to discard
        gate.complete()
        #expect(await failure { try await sending.value }?.code == AttachmentManager.codeUnavailable)
        #expect(ops.calls == ["upload", "discard:blob1"] && p.isWiped)
    }

    /// At most two content fetches of this device at once (`attachment_fetches`): a third waits for one to end.
    @Test func atMostTwoFetchesAtOnce() async throws {
        let gate = TestDeferred<Void>()
        ops.gate = gate
        try ops.serve(Self.png)
        let fetches = ["M1", "M2", "M3"].map { id in Task { try await m.photo("c1", messageID: id) } }
        #expect(await eventually { ops.calls.count { $0.hasPrefix("fetch:") } == 2 })
        for _ in 0..<50 { await Task.yield() }
        #expect(ops.calls.count { $0.hasPrefix("content:") } == 2, "the third has not started")
        gate.complete()
        for f in fetches { _ = try await f.value }
        #expect(ops.calls.count { $0.hasPrefix("content:") } == 3)
    }

    /// A photo a clear wiped is never sealed or uploaded: its bytes are zeros.
    @Test func aPhotoWipedByAClearIsNeverUploaded() async {
        let p = m.begin("c1", caption: "", photo: photo())
        m.clear()
        #expect(await failure { try await m.send(p) }?.code == AttachmentManager.codeUnavailable)
        #expect(ops.calls.isEmpty)
        // Cleared while the upload was on its way: nothing is sent with it.
        let q = m.begin("c1", caption: "", photo: photo())
        ops.uploadHook = { [m] in m.clear() }
        #expect(await failure { try await m.send(q) }?.code == AttachmentManager.codeUnavailable)
        #expect(ops.calls == ["upload"] && q.isWiped)
    }
}

/// A counter the request-id closure can capture.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func next() -> Int {
        lock.withLock {
            n += 1
            return n
        }
    }
}
