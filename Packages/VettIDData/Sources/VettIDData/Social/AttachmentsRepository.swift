import Foundation
import Observation
import VettIDCrypto
import VettIDMedia
import VettIDVault

/// A photo on its way out (ANDROID-PLAN "Photo attachments", "Sending"): prepared in memory, uploaded at most once per
/// tap of Send, and sent with one inner id that a Retry repeats. Kept in memory only until the vault's answer arrives or
/// the member cancels, and wiped at a lock. Mirrors vettid-android `PendingPhoto`.
@MainActor
public final class PendingPhoto {
    public let connectionID: String
    public let caption: String
    let photo: PreparedPhoto
    /// The inner id of this photo's `message.send`: a Retry re-sends the same request (§8.2), never a new upload.
    public let requestID: String
    /// The upload in the vault's mailbox, once the relay took it, with its reference (the key wiped with the photo).
    var blobID: String?
    var sealed: SealedRef?
    public internal(set) var sent = false
    /// The send running now: the next one waits for it (a Retry tapped twice must not upload twice).
    var tail: Task<Void, Never>?

    struct SealedRef {
        var key: [UInt8]
        let sha256: [UInt8]
        let size: Int

        mutating func wipe() { key = [UInt8](repeating: 0, count: key.count) }
    }

    init(connectionID: String, caption: String, photo: PreparedPhoto, requestID: String) {
        self.connectionID = connectionID
        self.caption = caption
        self.photo = photo
        self.requestID = requestID
    }

    /// Whether the upload is in the vault's mailbox (a Retry then only re-sends the request).
    public var uploaded: Bool { blobID != nil }

    /// The prepared thumbnail (a copy).
    public var thumbnail: [UInt8] { photo.thumb.copy() }
    public var isWiped: Bool { photo.isWiped }
    public var width: Int { photo.width }
    public var height: Int { photo.height }

    func wipe() {
        sealed?.wipe()
        sealed = nil
        photo.wipe()
    }

    /// TEST ONLY: a pending photo made outside ``AttachmentManager`` (the repository fake).
    public static func testOnly(connectionID: String, caption: String, photo: PreparedPhoto, requestID: String) -> PendingPhoto {
        PendingPhoto(connectionID: connectionID, caption: caption, photo: photo, requestID: requestID)
    }
}

/// A received photo, fetched and checked: the encoded bytes (decoded only for showing) and their sniffed type. What the
/// repository hands out is a copy of its own, which its holder wipes (``wipe()``) when it lets it go.
public final class FetchedPhoto: Sendable, CustomStringConvertible, CustomReflectable {
    public let bytes: PhotoBytes
    public let type: ImageType

    public init(bytes: [UInt8], type: ImageType) {
        self.bytes = PhotoBytes(bytes)
        self.type = type
    }

    public func wipe() { bytes.wipe() }

    /// Whether the bytes still are a photo of [type] (a clear zeroes them): nothing wiped ever leaves VettID.
    public var intact: Bool { bytes.withBytes { ImageType.sniff($0) } == type }

    public var description: String { "FetchedPhoto(\(type.rawValue), \(bytes.count))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Photo attachments (VAULT-MESSAGING §10.5.1, ANDROID-PLAN "Photo attachments") on this phone, as ``Repositories.swift``
/// describes the repositories. Everything lives in memory: thumbnails, photos and prepared uploads, wiped by ``clear()``
/// at a lock, on entering the hold or the due state, at a wipe and at an unlink. Nothing from a photo goes to a log. Every
/// failure is a ``VaultFailure`` (``PhotoError`` for a picture that cannot be prepared). Mirrors vettid-android
/// `AttachmentsRepository`.
@MainActor
public protocol AttachmentsRepository: AnyObject, Observable, Sendable {
    /// Whether the vault has attachments (`message.attachment.get{}` after each unlock); no photo button otherwise.
    var available: Bool { get }

    /// Counts every ``clear()``: screens drop the photos, previews and drafts they hold when it changes. Thumbnails and
    /// photos handed out are copies, which a clear cannot zero.
    var cleared: Int { get }

    /// The availability probe: once after each unlock.
    func probe() async

    /// Prepares a picked picture's or a camera shot's bytes for sending, off the main actor: bounds first, orientation,
    /// long edge 2,560, JPEG without metadata, the thumbnail. Throws ``PhotoError``.
    func prepare(_ source: [UInt8]) async throws -> PreparedPhoto

    /// Starts sending [photo] to [connectionID] with [caption] (it goes with the first photo only).
    func begin(_ connectionID: String, caption: String, photo: PreparedPhoto) -> PendingPhoto

    /// Uploads [p] (unless it already is) and sends `message.send` with it under ``PendingPhoto/requestID``. A lost or
    /// late answer leaves [p] uploaded: calling this again is the member's Retry, the same request without a new upload.
    /// The relay refusing the upload with `quota_exceeded` is ``FailureKind/limit`` with code `quota_exceeded`, and nothing
    /// is retried until the member taps Send again.
    @discardableResult
    func send(_ p: PendingPhoto) async throws -> MessageInfo

    /// Cancel before `message.send` answered: `message.attachment.discard{blob_id}` for an upload, then wiped.
    func cancel(_ p: PendingPhoto) async

    /// ``cancel(_:)`` without waiting (the screen that held [p] is gone).
    func abandon(_ p: PendingPhoto)

    /// The thumbnail of a message's photo: from `message.new`, or fetched (`part: "thumb"`); memory only; a copy.
    func thumbnail(_ connectionID: String, messageID: String) async throws -> [UInt8]

    /// The photo itself: fetched from this phone's mailbox, checked, decrypted and deleted there; memory only; a copy.
    func photo(_ connectionID: String, messageID: String) async throws -> FetchedPhoto

    /// The thumbnail in memory, if any (no request); a copy.
    func cachedThumbnail(_ connectionID: String, messageID: String) -> [UInt8]?

    /// Drops every thumbnail, photo, share offer and pending upload (zeroed).
    func clear()
}

/// The vault calls behind ``AttachmentManager`` (§10.5.1), one per step, as ``VaultApi`` has them; a test passes its own.
public protocol AttachmentOps: Sendable {
    func attachmentsSupported() async throws -> Bool?
    func uploadBlob(_ blob: [UInt8]) async throws -> String
    func messageSendPhoto(
        _ connectionID: String, text: String?, attachment: AttachmentSend, requestID: String
    ) async throws -> SentAttachment
    func messageAttachmentDiscard(_ blobID: String) async throws
    func attachmentThumb(_ connectionID: String, messageID: String) async throws -> [UInt8]
    func attachmentContent(_ connectionID: String, messageID: String) async throws -> FetchedAttachment
    func fetchBlob(_ blobID: String) async throws -> [UInt8]
    func deleteBlob(_ blobID: String) async throws
}

extension VaultApi: AttachmentOps {}
