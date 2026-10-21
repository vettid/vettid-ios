import Foundation
import VettIDData
import VettIDMedia

/// Photos picked or taken for one conversation (ANDROID-PLAN "Photo attachments", "Preparing it, in memory"), prepared
/// and waiting for Send or Cancel. In memory only. Never printed or mirrored. Mirrors vettid-android `PhotoDraft`.
public struct PhotoDraft: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var photos: [PreparedPhoto] = []
    public var caption = ""
    public var preparing = false
    public var sending = false
    /// Photos of this draft already sent (the caption went with the first).
    public var sent = 0
    public var problem: PhotoProblem?
    /// The last answer was lost: Retry re-sends the same request, without a new upload.
    public var retry = false
    /// A request is on its way to the vault: Cancel waits for its answer.
    public var inFlight = false
    /// Picked pictures that could not be read or prepared (the others are here).
    public var failedPicks = 0

    /// The Photos picker hands at most this many.
    public static let maxPhotos = 10

    public init(photos: [PreparedPhoto] = [], preparing: Bool = false, problem: PhotoProblem? = nil, failedPicks: Int = 0) {
        self.photos = photos
        self.preparing = preparing
        self.problem = problem
        self.failedPicks = failedPicks
    }

    public var canSend: Bool {
        !photos.isEmpty && !sending && !preparing && caption.utf8.count <= MessageLimits.maxTextBytes
    }

    public static func == (a: PhotoDraft, b: PhotoDraft) -> Bool {
        a.photos.map(ObjectIdentifier.init) == b.photos.map(ObjectIdentifier.init) && a.caption == b.caption
            && a.preparing == b.preparing && a.sending == b.sending && a.sent == b.sent && a.problem == b.problem
            && a.retry == b.retry && a.inFlight == b.inFlight && a.failedPicks == b.failedPicks
    }

    public var description: String {
        "PhotoDraft(photos: \(photos.count), sent: \(sent), preparing: \(preparing), sending: \(sending), "
            + "problem: \(problem.map { "\($0)" } ?? "nil"))"
    }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What went wrong with a photo, in the plan's words (the screen says each). Mirrors vettid-android `PhotoProblem`.
public enum PhotoProblem: Equatable, Sendable, CaseIterable {
    case tooLarge
    case unsupported
    case unreadable
    /// The relay refused the upload: the vault's mailbox is full.
    case mailboxFull
    /// `limit` `attachment_storage` or `attachments`.
    case vaultFull
    /// No answer, `busy` or a relay error: Retry.
    case noAnswer
    case notSent

    public static func of(_ f: PhotoFailure) -> PhotoProblem {
        switch f {
        case .tooLarge: .tooLarge
        case .unsupported: .unsupported
        case .unreadable, .cannotFit: .unreadable
        }
    }
}

/// The line under a photo bubble: its state and, for a failure, the reason (ANDROID-PLAN "The bubble"). The screen says
/// each with the connection's name where [withName]. Mirrors vettid-android `PhotoStatus`.
public struct PhotoStatus: Equatable, Sendable {
    public enum Text: Equatable, Sendable, CaseIterable {
        case sending, delivered, receiving
        case notSentBubble, peerNoPhotos, unconfirmed, notDelivered
        case inFull, inRate, inType, inWithdrawn, inNever
    }

    public let text: Text
    public var withName = false
    public var failed = false

    public init(_ text: Text, withName: Bool = false, failed: Bool = false) {
        self.text = text
        self.withName = withName
        self.failed = failed
    }

    /// [a]'s state and reason as the bubble says them; nil for a stored incoming photo (nothing to say).
    public static func of(_ a: AttachmentInfo, outgoing: Bool) -> PhotoStatus? {
        let reason = a.reason ?? ""
        switch a.state {
        case .preparing, .sending: return PhotoStatus(.sending)
        case .delivered: return PhotoStatus(.delivered)
        case .fetching: return PhotoStatus(.receiving)
        case .stored, .unknown: return nil
        case .failed: return outgoing ? outgoingFailure(reason) : incomingFailure(reason)
        }
    }

    private static func outgoingFailure(_ reason: String) -> PhotoStatus {
        switch reason {
        case "bad", "type": PhotoStatus(.notSentBubble, failed: true)
        case "unsupported": PhotoStatus(.peerNoPhotos, withName: true, failed: true)
        case "unconfirmed": PhotoStatus(.unconfirmed, failed: true)
        default: PhotoStatus(.notDelivered, failed: true)
        }
    }

    private static func incomingFailure(_ reason: String) -> PhotoStatus {
        if reason == "full" { return PhotoStatus(.inFull, failed: true) }
        if reason == "rate" { return PhotoStatus(.inRate, withName: true, failed: true) }
        if reason == "type" { return PhotoStatus(.inType, failed: true) }
        if reason.hasPrefix("withdrawn") { return PhotoStatus(.inWithdrawn, withName: true, failed: true) }
        return PhotoStatus(.inNever, failed: true)
    }
}
