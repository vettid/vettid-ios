#if DEBUG
import Foundation
import VettIDCrypto
import VettIDMedia
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The fake vault's photo attachments (VAULT-MESSAGING §10.5.1, release A) and the blobs of both mailboxes
/// (RELAY-PROTOCOL §6.8): the device's upload to the vault's mailbox, checked as the vault checks it (§5.5, sniffing) and
/// stored; `message.attachment.get` (the probe, the thumb, a fresh blob of the content in the device's mailbox) and
/// `.discard`; the states as `sync.event{message.attachment}`; and the other member's photos as `message.new` with the
/// device view and its thumbnail. Synchronous where the vault works in the background.
struct FakePhotos {
    struct Stored {
        var connectionID: String
        var messageID: String
        var attID: String
        var outgoing: Bool
        var content: [UInt8]
        var thumb: [UInt8]
        var width: Int
        var height: Int
        var state: String
        var reason: String?
    }

    /// The vault has release A (`message.attachment.get{}` is `bad_request`); without it every attachment type is
    /// `unsupported_type`.
    var releaseA = true
    /// The vault's mailbox: what the device uploaded.
    var vaultBlobs: [String: [UInt8]] = [:]
    /// The device's mailbox: what the vault uploaded for it.
    var deviceBlobs: [String: [UInt8]] = [:]
    /// The stored attachments, by message id.
    var stored: [String: Stored] = [:]
    var discarded: [String] = []
    var uploads = 0
    var deviceBlobsDeleted: [String] = []
    /// The relay refuses the device's uploads with this code (`quota_exceeded`: the vault's mailbox is full).
    var refuseUploads: String?
    /// What the vault delivered to the other member: each photo's content, by connection.
    var peerPhotos: [String: [[UInt8]]] = [:]
    /// The peer's vault reports `stored` at once (`delivered`), unless the test holds it.
    var holdDelivery = false
}

extension FakeVaultService {
    static let photoBlobTTL = "2026-10-28T00:00:00Z"

    // MARK: - The relays' blobs

    /// `PUT /v1/blob/{vault_mailbox}`: the device's upload.
    func vaultBlobPut(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        locked {
            if let code = photos.refuseUploads { return .json(409, #"{"code":"\#(code)","message":"","quota":"mailbox_blobs"}"#) }
            let id = Ulid.new()
            photos.vaultBlobs[id] = r.body
            photos.uploads += 1
            return .json(201, #"{"blob_id":"\#(id)","expires_at":"\#(Self.photoBlobTTL)"}"#)
        }
    }

    /// `GET` and `DELETE /v1/blob/{id}` in the device's own mailbox.
    func deviceBlob(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        let id = String(r.path.dropFirst("/v1/blob/".count))
        return locked {
            if r.method == "DELETE" {
                photos.deviceBlobs[id] = nil
                photos.deviceBlobsDeleted.append(id)
                return .json(200, "{}")
            }
            guard let b = photos.deviceBlobs[id] else { return .json(404, #"{"code":"blob_unknown","message":""}"#) }
            return .bytes(200, b)
        }
    }

    // MARK: - The requests

    /// `message.attachment.get` and `.discard` (§10.5.1). Callers hold ``cond``.
    func attachmentRequest(_ m: Inner, _ body: JsonObject) throws {
        guard photos.releaseA else { return try reply(m.type, "{}", re: m.id, error: "unsupported_type") }
        if m.type == "message.attachment.discard" {
            guard let id = try? body.string("blob_id") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
            photos.discarded.append(id)
            photos.vaultBlobs[id] = nil
            return try reply(m.type, "{}", re: m.id)
        }
        // The shape before anything else: `{}` is the availability probe's `bad_request`.
        guard let conn = try? body.string("connection_id"), let id = try? body.string("message_id") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        let part = (try? body.optString("part")) ?? nil
        guard let s = photos.stored[id], s.connectionID == conn else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        if part == "thumb" { return try reply(m.type, JsonBuilder().base64("thumb", s.thumb).build(), re: m.id) }
        guard s.state == "stored" || s.state == "sending" || s.state == "delivered" else { return try reply(m.type, "{}", re: m.id, error: "unavailable") }
        let sealed = try ClaimBlob.seal(s.content)
        let blobID = Ulid.new()
        photos.deviceBlobs[blobID] = sealed.blob
        let ref = JsonBuilder().string("id", blobID).base64("key", sealed.key).base64("sha256", sealed.sha256).uint("size", UInt64(sealed.size)).string("mime", "image/jpeg").build()
        try reply(m.type, JsonBuilder().raw("blob", ref).string("expires_at", Self.photoBlobTTL).build(), re: m.id)
    }

    /// `message.send` with a photo (§10.5.1 "Sending"): the shape and the thumbnail checked, the message stored and
    /// answered, then the upload fetched and checked (`failed` with `bad` or `type`, the message not sent), and the
    /// peer's `stored` (`delivered`). Callers hold ``cond``.
    func photoSend(_ m: Inner, _ body: JsonObject) throws {
        guard photos.releaseA else { return try reply(m.type, "{}", re: m.id, error: "unsupported_type") }
        guard let conn = try? body.string("connection_id"), let att = try? body.obj("attachment"), let ref = try? att.obj("blob"),
              let blobID = try? ref.string("id"), let key = try? ref.base64("key", 32), let sha = try? ref.base64("sha256", 32),
              let size = try? ref.uint("size", min: 1, max: UInt64(PhotoLimits.attachmentMaxBytes)), (try? att.string("kind")) == "photo",
              let width = try? att.uint("width", min: 1, max: 8_192), let height = try? att.uint("height", min: 1, max: 8_192),
              let thumb = try? att.base64("thumb"), !thumb.isEmpty, thumb.count <= PhotoLimits.thumbMaxBytes, ImageType.sniff(thumb) != nil,
              !ref.has("name") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard social.connections[conn] != nil else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        let text = (try? body.optString("text")) ?? nil
        let msg = FakeMessaging.Message(id: Ulid.new(), outgoing: true, text: text ?? "", sentAt: Self.millis(Date()))
        var s = FakePhotos.Stored(connectionID: conn, messageID: msg.id, attID: Ulid.new(), outgoing: true, content: [], thumb: thumb, width: Int(width), height: Int(height), state: "preparing")
        social.messages.conversations[conn, default: []].append(msg)
        try reply(m.type, JsonBuilder().string("message_id", msg.id).string("sent_at", Timestamps.formatMillis(msg.sentAt)).string("att_id", s.attID).build(), re: m.id)
        // Step 5: the upload fetched from the vault's mailbox, checked, and deleted there.
        let blob = photos.vaultBlobs.removeValue(forKey: blobID)
        if let blob, let content = try? ClaimBlob.open(blob, key: key, sha256: sha, size: size) {
            s.content = content
            s.state = ImageType.sniff(content) == nil ? "failed" : "sending"
            s.reason = s.state == "failed" ? "type" : nil
        } else {
            s.state = "failed"
            s.reason = "bad"
        }
        try setPhoto(s)
        guard s.state == "sending" else { return }
        photos.peerPhotos[conn, default: []].append(s.content)
        if !photos.holdDelivery {
            s.state = "delivered"
            try setPhoto(s)
        }
    }

    /// Stores [s], its message's device view, and tells every device its state. Callers hold ``cond``.
    func setPhoto(_ s: FakePhotos.Stored) throws {
        photos.stored[s.messageID] = s
        if let i = social.messages.conversations[s.connectionID]?.firstIndex(where: { $0.id == s.messageID }) {
            social.messages.conversations[s.connectionID]?[i].attachment = Self.deviceView(s, thumb: false)
        }
        let b = JsonBuilder().string("kind", "message.attachment").string("connection_id", s.connectionID).string("message_id", s.messageID).string("state", s.state)
        if let r = s.reason { b.string("reason", r) }
        try reply("sync.event", b.build())
    }

    static func deviceView(_ s: FakePhotos.Stored, thumb: Bool) -> String {
        let b = JsonBuilder().string("att_id", s.attID).string("kind", "photo")
        if s.state != "failed", let t = ImageType.sniff(s.content) { b.string("mime", t.mime) }
        b.uint("size", UInt64(s.content.count)).uint("width", UInt64(s.width)).uint("height", UInt64(s.height)).string("state", s.state)
        if let r = s.reason { b.string("reason", r) }
        if thumb { b.base64("thumb", s.thumb) }
        return b.build()
    }

    // MARK: - The other member

    /// The connection's member sent a photo (`message.attachment.deliver`): the vault stored it, and every device gets
    /// `message.new` with the device view and its thumbnail. Returns the message id.
    @discardableResult
    public func peerSendsPhoto(_ connectionID: String, content: [UInt8], thumb: [UInt8], caption: String = "", width: Int = 2_560, height: Int = 1_920, name: String? = nil) throws -> String {
        try locked {
            guard social.connections[connectionID] != nil else { throw CryptoError.format("unknown connection") }
            var msg = FakeMessaging.Message(id: Ulid.new(), outgoing: false, text: caption, sentAt: Self.millis(Date()))
            let s = FakePhotos.Stored(connectionID: connectionID, messageID: msg.id, attID: Ulid.new(), outgoing: false, content: content, thumb: thumb, width: width, height: height, state: "stored")
            msg.attachment = Self.deviceView(s, thumb: false)
            photos.stored[msg.id] = s
            social.messages.conversations[connectionID, default: []].append(msg)
            social.messages.receiptsSent.append((msg.id, "delivered"))
            var view = Self.deviceView(s, thumb: true)
            if let name { view = String(view.dropLast()) + #","name":\#(JsonBuilder.quote(name))}"# }
            let b = JsonBuilder().string("connection_id", connectionID).string("message_id", msg.id).string("direction", "in").string("text", caption).string("sent_at", Timestamps.formatMillis(msg.sentAt)).bool("delivered", false).bool("read", false).raw("attachment", view)
            try reply("message.new", b.build())
            return msg.id
        }
    }

    /// The peer's vault reported `stored` for an outgoing photo held back (``holdsPhotoDelivery``).
    public func peerStoresPhoto(_ messageID: String) throws {
        try locked {
            guard var s = photos.stored[messageID] else { return }
            s.state = "delivered"
            try setPhoto(s)
        }
    }

    // MARK: - Switches and what the test reads

    public var attachmentsReleaseA: Bool {
        get { locked { photos.releaseA } }
        set { locked { photos.releaseA = newValue } }
    }

    public var refusesPhotoUploads: String? {
        get { locked { photos.refuseUploads } }
        set { locked { photos.refuseUploads = newValue } }
    }

    public var holdsPhotoDelivery: Bool {
        get { locked { photos.holdDelivery } }
        set { locked { photos.holdDelivery = newValue } }
    }

    /// The photos this vault delivered to the connection's member, in order (what the other member's app shows).
    public func peerPhotos(_ connectionID: String) -> [[UInt8]] { locked { photos.peerPhotos[connectionID] ?? [] } }

    /// How many blobs the device uploaded to the vault's mailbox.
    public var photoUploads: Int { locked { photos.uploads } }

    /// The blob ids the vault was asked to discard.
    public var discardedBlobs: [String] { locked { photos.discarded } }

    /// The device's uploads still in the vault's mailbox.
    public var vaultMailboxBlobs: Int { locked { photos.vaultBlobs.count } }

    /// The vault's uploads still in the device's mailbox, and those the device deleted.
    public var deviceMailboxBlobs: Int { locked { photos.deviceBlobs.count } }
    public var deviceBlobsDeleted: [String] { locked { photos.deviceBlobsDeleted } }

    /// A stored attachment's state and reason, by message id.
    public func photoState(_ messageID: String) -> String? { locked { photos.stored[messageID]?.state } }

    /// The ids of the attachment (`att_id`) of every stored photo.
    public var photoAttIDs: [String] { locked { photos.stored.values.map(\.attID) } }
}

// swiftlint:enable line_length
#endif
