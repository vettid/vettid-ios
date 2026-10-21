import Foundation
import VettIDMedia
import VettIDVault

// Messages as the app shows them (VAULT-MESSAGING §10.5; ANDROID-PLAN §4 Messages, Conversation), with their photos
// (§10.5.1). Mirrors the message part of vettid-android `SocialModels.kt`.

/// Where a message's attachment stands (VAULT-MESSAGING §10.5.1 "state"): outgoing ``preparing``, ``sending``,
/// ``delivered``; incoming ``fetching``, ``stored``; either way ``failed`` with a reason. ``unknown`` for a state a newer
/// vault may add. Mirrors vettid-android `AttachmentState`.
public enum AttachmentState: String, Sendable, CaseIterable {
    case preparing, sending, delivered, fetching, stored, failed
    case unknown = ""

    public static func of(_ wire: String?) -> AttachmentState {
        guard let wire, !wire.isEmpty else { return .unknown }
        return AttachmentState(rawValue: wire) ?? .unknown
    }
}

/// A message's photo as the vault describes it (the device view: never a blob key or id). [mime] is the type the vault
/// sniffed, once stored; [name] the sender's, sanitized for showing and never used as a file name; [width] and [height]
/// the sender's claim, for a placeholder only. The thumbnail and the photo live in memory only (``AttachmentsRepository``),
/// never here. Mirrors vettid-android `AttachmentInfo`.
public struct AttachmentInfo: Equatable, Sendable {
    public var attID: String
    public var state: AttachmentState
    public var reason: String?
    public var mime: String?
    public var size: Int64
    public var width: Int
    public var height: Int
    public var name: String?

    public init(
        attID: String, state: AttachmentState, reason: String? = nil, mime: String? = nil, size: Int64 = 0, width: Int = 0,
        height: Int = 0, name: String? = nil
    ) {
        self.attID = attID
        self.state = state
        self.reason = reason
        self.mime = mime
        self.size = size
        self.width = width
        self.height = height
        self.name = name
    }

    /// Whether the photo can be fetched (`message.attachment.get` serves only a stored attachment).
    public var viewable: Bool { state == .stored || state == .sending || state == .delivered }

    /// The device view of an attachment (§10.5.1); the thumbnail is not kept here, the name is sanitized.
    public static func of(_ a: AttachmentView) -> AttachmentInfo {
        AttachmentInfo(
            attID: a.attID, state: .of(a.state), reason: a.reason, mime: a.mime, size: a.size, width: a.width, height: a.height,
            name: AttachmentNames.sanitize(a.name)
        )
    }
}

/// One message (§10.5). [sentAt] is the sender's clock, for display only: the order of a conversation is the vault's
/// (arrival order, ``MessagePages``). [attachment]: the message's photo (0.32.0, release A); [text] is then its caption.
public struct MessageInfo: Equatable, Sendable, Identifiable {
    public var connectionID: String
    public var messageID: String
    public var outgoing: Bool
    public var text: String
    public var sentAt: Date
    /// Outgoing: the peer's vault stored it (a `delivered` receipt, or `read`).
    public var delivered: Bool
    /// Outgoing: the peer read it; incoming: this member read it (on this device or another).
    public var read: Bool
    public var attachment: AttachmentInfo?

    public var id: String { messageID }

    /// Whether the message carries a photo.
    public var hasAttachment: Bool { attachment != nil }

    public init(
        connectionID: String, messageID: String, outgoing: Bool, text: String, sentAt: Date, delivered: Bool = false,
        read: Bool = false, attachment: AttachmentInfo? = nil
    ) {
        self.connectionID = connectionID
        self.messageID = messageID
        self.outgoing = outgoing
        self.text = text
        self.sentAt = sentAt
        self.delivered = delivered
        self.read = read
        self.attachment = attachment
    }

    /// A vault message (`message.new`, `message.list`, `message.get`); a `sent_at` that does not parse is the epoch, as
    /// vettid-android has it.
    public static func of(_ m: Message) -> MessageInfo {
        MessageInfo(
            connectionID: m.connectionID, messageID: m.messageID, outgoing: m.direction == "out", text: m.text,
            sentAt: ConnectionParser.instant(m.sentAt) ?? Date(timeIntervalSince1970: 0), delivered: m.delivered, read: m.read,
            attachment: m.attachmentView.map(AttachmentInfo.of)
        )
    }
}

/// One row of the Messages screen: a connection with its latest message (in the vault's order) and its unread count.
public struct ConversationSummary: Equatable, Sendable, Identifiable {
    public var connection: ConnectionInfo
    public var last: MessageInfo?
    public var unread: Int

    public var id: String { connection.id }

    public init(connection: ConnectionInfo, last: MessageInfo?, unread: Int) {
        self.connection = connection
        self.last = last
        self.unread = unread
    }

    /// The rows (vettid-android `SocialManager.summaries`): every active connection, and any other with messages
    /// loaded, newest conversation first (by its latest message's `sent_at`, else the connection's creation).
    static func of(_ connections: [ConnectionInfo], _ messages: [String: [MessageInfo]]) -> [ConversationSummary] {
        connections.filter { $0.state == .active || !(messages[$0.id] ?? []).isEmpty }
            .map { c in
                let list = messages[c.id] ?? []
                return ConversationSummary(connection: c, last: list.last, unread: list.count { !$0.outgoing && !$0.read })
            }
            .sorted { $0.latest > $1.latest }
    }

    /// When the conversation last moved: its latest message's `sent_at`, else the connection's creation.
    var latest: Date { last?.sentAt ?? connection.createdAt ?? .distantPast }
}
