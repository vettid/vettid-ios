import Foundation
import VettIDVault

// Messages as the app shows them (VAULT-MESSAGING §10.5; ANDROID-PLAN §4 Messages, Conversation). Mirrors the message
// part of vettid-android `SocialModels.kt`; the photo of a message (§10.5.1) joins it with the photos (IOS-PLAN §8 I2.4).

/// One message (§10.5). [sentAt] is the sender's clock, for display only: the order of a conversation is the vault's
/// (arrival order, ``MessagePages``). [hasAttachment]: the message carries a photo (0.32.0, release A), shown with the
/// photos (I2.4); [text] is then its caption.
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
    public var hasAttachment = false

    public var id: String { messageID }

    public init(
        connectionID: String, messageID: String, outgoing: Bool, text: String, sentAt: Date, delivered: Bool = false,
        read: Bool = false, hasAttachment: Bool = false
    ) {
        self.connectionID = connectionID
        self.messageID = messageID
        self.outgoing = outgoing
        self.text = text
        self.sentAt = sentAt
        self.delivered = delivered
        self.read = read
        self.hasAttachment = hasAttachment
    }

    /// A vault message (`message.new`, `message.list`, `message.get`); a `sent_at` that does not parse is the epoch, as
    /// vettid-android has it.
    public static func of(_ m: Message) -> MessageInfo {
        MessageInfo(
            connectionID: m.connectionID, messageID: m.messageID, outgoing: m.direction == "out", text: m.text,
            sentAt: ConnectionParser.instant(m.sentAt) ?? Date(timeIntervalSince1970: 0), delivered: m.delivered, read: m.read,
            hasAttachment: m.attachment != nil
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
