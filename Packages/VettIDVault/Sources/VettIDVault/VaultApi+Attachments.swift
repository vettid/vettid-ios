import Foundation
import VettIDCrypto

// Photo attachments (VAULT-MESSAGING §10.5.1, release A): the app's calls. A desktop is answered `forbidden`. Mirrors
// vettid-android `AttachmentApi.kt`.
extension VaultApi {
    /// Whether the vault has attachments (§10.5.1 "Compatibility"): `message.attachment.get{}` is `bad_request` on a vault
    /// of release A (held or not) and `unsupported_type` on an older one. Nil when the answer said neither.
    public func attachmentsSupported() async throws -> Bool? {
        do {
            _ = try await device.op("message.attachment.get")
            return nil
        } catch let e as VaultOpError {
            switch e.code {
            case "bad_request": return true
            case "unsupported_type": return false
            default: return nil
            }
        }
    }

    /// Uploads a sealed photo blob to the vault's own mailbox (§10.5.1 "Sending" step 1); returns its `blob_id`.
    public func uploadBlob(_ blob: [UInt8]) async throws -> String { try await device.uploadBlobToVault(blob) }

    /// Fetches a blob the vault uploaded to this device's mailbox (§10.5.1 "Fetching"), at most `max_blob_bytes`.
    public func fetchBlob(_ blobID: String) async throws -> [UInt8] { try await device.fetchOwnBlob(blobID) }

    /// Deletes a blob in this device's mailbox, whether it passed its checks or not.
    public func deleteBlob(_ blobID: String) async throws { try await device.deleteOwnBlob(blobID) }

    /// `message.send` with a photo (§10.5.1 step 2): [attachment] the device send view; [text] the caption (0 bytes to
    /// 16 KiB, absent when empty). Sent with inner id [requestID], so that a Retry after a lost answer is the same request.
    public func messageSendPhoto(
        _ connectionID: String, text: String?, attachment: AttachmentSend, requestID: String
    ) async throws -> SentAttachment {
        let b = JsonBuilder().string("connection_id", connectionID)
        if let text, !text.isEmpty { b.string("text", text) }
        b.raw("attachment", attachment.json)
        let o = VaultJSON.object(try await device.op("message.send", body: b.bytes(), innerID: requestID))
        guard let id = VaultJSON.string(o, "message_id"), let at = VaultJSON.string(o, "sent_at"),
              let att = VaultJSON.string(o, "att_id") else {
            throw VaultStateError(message: "message.send without message_id, sent_at or att_id")
        }
        return SentAttachment(messageID: id, sentAt: at, attID: att)
    }

    /// The thumbnail of a message's attachment, inline (`part: "thumb"`): its decoded bytes.
    public func attachmentThumb(_ connectionID: String, messageID: String) async throws -> [UInt8] {
        let body = Self.attachmentRef(connectionID, messageID, "thumb")
        let o = VaultJSON.object(try await device.op("message.attachment.get", body: body))
        guard let t = VaultJSON.string(o, "thumb") else { throw VaultStateError(message: "message.attachment.get without thumb") }
        return try Base64s.decodeStd(t)
    }

    /// The content of a message's attachment (`part: "content"`): a fresh blob in this device's mailbox.
    public func attachmentContent(_ connectionID: String, messageID: String) async throws -> FetchedAttachment {
        let body = Self.attachmentRef(connectionID, messageID, "content")
        let o = VaultJSON.object(try await device.op("message.attachment.get", body: body))
        guard let ref = VaultJSON.obj(o, "blob").flatMap(BlobRef.of) else {
            throw VaultStateError(message: "message.attachment.get without blob")
        }
        return FetchedAttachment(blob: ref, expiresAt: VaultJSON.string(o, "expires_at"))
    }

    /// Asks the vault to delete a blob this device uploaded and will not send (Cancel before `message.send`).
    public func messageAttachmentDiscard(_ blobID: String) async throws {
        _ = try await device.op("message.attachment.discard", body: JsonBuilder().string("blob_id", blobID).bytes())
    }

    static func attachmentRef(_ connectionID: String, _ messageID: String, _ part: String) -> [UInt8] {
        JsonBuilder().string("connection_id", connectionID).string("message_id", messageID).string("part", part).bytes()
    }
}
