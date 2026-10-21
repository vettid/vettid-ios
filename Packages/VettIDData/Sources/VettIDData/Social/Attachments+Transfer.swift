import Foundation
import VettIDCrypto
import VettIDMedia
import VettIDRelay
import VettIDVault

// The transfers of ``AttachmentManager``: the upload and `message.send` of a photo (§10.5.1 "Sending" steps 1–2), and
// the fetch of a received one (§10.5.1 "Fetching", §5.5's checks).
extension AttachmentManager {
    func sendNow(_ p: PendingPhoto) async throws -> MessageInfo {
        if p.sent { throw VaultFailure(.conflict, code: Self.codeAlreadySent) }
        let mark = cleared
        // A photo a clear wiped (a lock, the hold) is never sealed, uploaded or sent: its bytes are zeros.
        try live(p, since: mark)
        if p.blobID == nil { try await upload(p, since: mark) }
        try live(p, since: mark)
        guard let blobID = p.blobID, let sealed = p.sealed else { throw VaultFailure(.other, code: Self.codeNoUpload) }
        var att = AttachmentSend(
            blobID: blobID, key: sealed.key.withUnsafeBufferPointer { Array($0) }, sha256: sealed.sha256, size: sealed.size,
            mime: ImageType.jpeg.mime, width: p.photo.width, height: p.photo.height, thumb: p.photo.thumb.copy()
        )
        defer { att.wipe() }
        let answer: SentAttachment
        do {
            let (caption, id) = (p.caption.isEmpty ? nil : p.caption, p.requestID)
            answer = try await guarded { try await ops().messageSendPhoto(p.connectionID, text: caption, attachment: att, requestID: id) }
        } catch let f as VaultFailure {
            // A lost or late answer, `busy` or a relay error: the same request again on Retry (the upload stays). Any other
            // refusal is final (the vault answers the same id from its cache, and has deleted the upload).
            if !Self.retryable(f) { finish(p) }
            throw f
        }
        let m = MessageInfo(
            connectionID: p.connectionID, messageID: answer.messageID, outgoing: true, text: p.caption,
            sentAt: ConnectionParser.instant(answer.sentAt) ?? now(),
            attachment: AttachmentInfo(
                attID: answer.attID, state: .preparing, size: Int64(sealed.size), width: p.photo.width, height: p.photo.height
            )
        )
        p.sent = true
        // Answered after a clear (a lock meanwhile): nothing of it is kept in memory (chosen; not in the spec).
        if mark == cleared {
            thumbs.put(key(p.connectionID, answer.messageID), PhotoBytes(p.photo.thumb.copy()))
            finish(p)
            onSent(m)
        } else {
            finish(p)
        }
        return m
    }

    /// Seals the photo under a fresh key (§5.5) and uploads it to the vault's mailbox; only the key and the hash are kept
    /// once the relay took it.
    func upload(_ p: PendingPhoto, since mark: Int) async throws {
        p.sealed?.wipe()
        p.sealed = nil
        var sealed = try p.photo.jpeg.withBytes { try ClaimBlob.seal($0) }
        defer { sealed.wipe() }
        let id = try await guarded {
            do {
                return try await ops().uploadBlob(sealed.blob)
            } catch let r as RelayError where r.code == RelayError.quotaExceeded {
                throw VaultFailure(.limit, code: Self.codeQuota, cause: r)
            }
        }
        // Cleared while uploading: the upload is left to expire (the vault is not open to discard it).
        try live(p, since: mark)
        p.blobID = id
        let key = sealed.key.withUnsafeBufferPointer { Array($0) } // storage of its own: the sealed copy is zeroed
        p.sealed = PendingPhoto.SealedRef(key: key, sha256: sealed.sha256, size: sealed.size)
    }

    /// Throws `unavailable` when a clear came since [mark], or [p] was wiped or let go.
    func live(_ p: PendingPhoto, since mark: Int) throws {
        guard mark == cleared, !p.photo.isWiped, pending[ObjectIdentifier(p)] != nil else {
            if pending[ObjectIdentifier(p)] != nil { finish(p) }
            throw VaultFailure(.other, code: Self.codeUnavailable)
        }
    }

    /// The content's blob from this phone's mailbox, deleted there whatever its checks say (§5.5: the mailbox's blob
    /// storage is shared), then checked and opened; the type by sniffing, never the peer's `mime`.
    func fetch(_ connectionID: String, _ messageID: String) async throws -> FetchedPhoto {
        let ref = try await guarded { try await ops().attachmentContent(connectionID, messageID: messageID) }.blob
        var raw: [UInt8]
        do {
            raw = try await guarded { try await ops().fetchBlob(ref.id) }
        } catch {
            await deleteQuietly(ref.id)
            throw error
        }
        await deleteQuietly(ref.id)
        defer { Bytes.wipe(&raw) }
        guard raw.count <= PhotoLimits.maxBlobBytes else { throw VaultFailure(.other, code: Self.codeBad) }
        var content = try Self.openBlob(raw, ref)
        guard let type = ImageType.sniff(content) else {
            Bytes.wipe(&content)
            throw VaultFailure(.other, code: Self.codeType)
        }
        let got = FetchedPhoto(bytes: content, type: type)
        Bytes.wipe(&content)
        return got
    }

    func deleteQuietly(_ blobID: String) async {
        // It expires after the blob TTL otherwise.
        try? await guarded { try await ops().deleteBlob(blobID) }
    }

    /// The §5.5 checks with the reference's key and hash, each exactly 32 bytes; a malformed one is a bad blob.
    static func openBlob(_ raw: [UInt8], _ ref: BlobRef) throws -> [UInt8] {
        guard var key = try? Base64s.decodeStd(ref.key, keyBytes) else { throw VaultFailure(.other, code: codeBad) }
        defer { Bytes.wipe(&key) }
        guard let sha = try? Base64s.decodeStd(ref.sha256, keyBytes), ref.size > 0 else { throw VaultFailure(.other, code: codeBad) }
        do {
            return try ClaimBlob.open(raw, key: key, sha256: sha, size: UInt64(ref.size))
        } catch {
            throw VaultFailure(.other, code: codeBad)
        }
    }
}
