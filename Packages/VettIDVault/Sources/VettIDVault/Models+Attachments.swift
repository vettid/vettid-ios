import Foundation
import VettIDCrypto

// Body models of VAULT-MESSAGING §10.5.1 (photo attachments, release A). Read from the strict JSON object of the body;
// unknown members are ignored (§10.1). Mirrors the attachment models of vettid-android `Models.kt`.

/// The device view of an attachment (§10.5.1): never a blob key or id. [mime] is the type the vault sniffed, present once
/// stored; [name] the sender's, as stored (shown only after sanitizing); [state] and [reason] as §10.5.1's table; [thumb]
/// base64, in `message.new` and `message.attachment.get{part: "thumb"}` only.
public struct AttachmentView: Equatable, Sendable {
    public let attID: String
    public let kind: String
    public let mime: String?
    public let size: Int64
    public let width: Int
    public let height: Int
    public let name: String?
    public let state: String
    public let reason: String?
    public let thumb: String?

    /// An `attachment` member; nil without its `att_id`.
    public static func of(_ o: JsonObject) -> AttachmentView? {
        guard let id = VaultJSON.string(o, "att_id") else { return nil }
        return AttachmentView(
            attID: id, kind: VaultJSON.string(o, "kind") ?? "photo", mime: VaultJSON.string(o, "mime"),
            size: VaultJSON.int(o, "size") ?? 0, width: Int(clamping: VaultJSON.int(o, "width") ?? 0),
            height: Int(clamping: VaultJSON.int(o, "height") ?? 0), name: VaultJSON.string(o, "name"),
            state: VaultJSON.string(o, "state") ?? "", reason: VaultJSON.string(o, "reason"), thumb: VaultJSON.string(o, "thumb")
        )
    }
}

extension Message {
    /// The message's attachment as the device view (§10.5.1), nil without one.
    public var attachmentView: AttachmentView? { attachment.flatMap(AttachmentView.of) }
}

/// A §5.5 blob reference: [key] and [sha256] base64; [size] the content's length; [mime] and [name] the sender's claims.
public struct BlobRef: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let id: String
    public let key: String
    public let sha256: String
    public let size: Int64
    public let mime: String
    public let name: String?

    public init(id: String, key: String, sha256: String, size: Int64, mime: String = "", name: String? = nil) {
        self.id = id
        self.key = key
        self.sha256 = sha256
        self.size = size
        self.mime = mime
        self.name = name
    }

    /// A `blob` member; nil without its `id`, `key`, `sha256` or `size`.
    public static func of(_ o: JsonObject) -> BlobRef? {
        guard let id = VaultJSON.string(o, "id"), let key = VaultJSON.string(o, "key"), let sha = VaultJSON.string(o, "sha256"),
              let size = VaultJSON.int(o, "size") else { return nil }
        let mime = VaultJSON.string(o, "mime") ?? ""
        return BlobRef(id: id, key: key, sha256: sha, size: size, mime: mime, name: VaultJSON.string(o, "name"))
    }

    // The key never reaches a log, a dump or a mirror.
    public var description: String { "BlobRef(size: \(size))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The device send view of a photo (§10.5.1): the reference of its upload, its size in pixels and its thumbnail. Apps
/// send no `name` for a photo.
public struct AttachmentSend: Sendable, CustomStringConvertible, CustomReflectable {
    public let blobID: String
    public let key: [UInt8]
    public let sha256: [UInt8]
    public let size: Int
    public let mime: String
    public let width: Int
    public let height: Int
    public let thumb: [UInt8]

    public init(blobID: String, key: [UInt8], sha256: [UInt8], size: Int, mime: String, width: Int, height: Int, thumb: [UInt8]) {
        self.blobID = blobID
        self.key = key
        self.sha256 = sha256
        self.size = size
        self.mime = mime
        self.width = width
        self.height = height
        self.thumb = thumb
    }

    /// `{blob: {id, key, sha256, size, mime}, kind: "photo", width, height, thumb}`.
    public var json: String {
        let blob = JsonBuilder().string("id", blobID).base64("key", key).base64("sha256", sha256).uint("size", UInt64(size))
            .string("mime", mime)
        return JsonBuilder().raw("blob", blob.build()).string("kind", "photo").uint("width", UInt64(width))
            .uint("height", UInt64(height)).base64("thumb", thumb).build()
    }

    public var description: String { "AttachmentSend(\(width)×\(height))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `message.send` with an attachment: answered once the vault's checks passed.
public struct SentAttachment: Equatable, Sendable {
    public let messageID: String
    public let sentAt: String
    public let attID: String

    public init(messageID: String, sentAt: String, attID: String) {
        self.messageID = messageID
        self.sentAt = sentAt
        self.attID = attID
    }
}

/// `message.attachment.get{part: "content"}`: a fresh blob the vault uploaded to this device's mailbox.
public struct FetchedAttachment: Equatable, Sendable {
    public let blob: BlobRef
    public let expiresAt: String?

    public init(blob: BlobRef, expiresAt: String? = nil) {
        self.blob = blob
        self.expiresAt = expiresAt
    }
}
