import Foundation
import VettIDCrypto

// Body models of VAULT-MESSAGING §10.5 and §10.5.2 (messaging and the paging of `message.list`). Read from the strict
// JSON object of the body; unknown members are ignored (§10.1). Mirrors the message models of vettid-android `Models.kt`.

/// `message.new`, an entry of `message.list` and `message.get` (§10.5): [direction] `in` or `out`; [sentAt] the sender's
/// clock (RFC 3339), never the order; [delivered] and [read] the receipts the vault holds. (0.32.0, release A)
/// [attachment] is the device view of §10.5.1, kept as the vault sent it for the photos (IOS-PLAN §8 I2.4); [text] is
/// then its caption, `""` without one.
public struct Message: Sendable {
    public let connectionID: String
    public let messageID: String
    public let direction: String
    public let text: String
    public let sentAt: String
    public let delivered: Bool
    public let read: Bool
    public let attachment: JsonObject?

    /// A `<message.new body>`; nil without its `connection_id`, `message_id`, `direction`, `text` or `sent_at`.
    public static func of(_ o: JsonObject) -> Message? {
        guard let conn = VaultJSON.string(o, "connection_id"), let id = VaultJSON.string(o, "message_id"),
              let dir = VaultJSON.string(o, "direction"), let text = VaultJSON.string(o, "text"),
              let sentAt = VaultJSON.string(o, "sent_at") else { return nil }
        return Message(
            connectionID: conn, messageID: id, direction: dir, text: text, sentAt: sentAt,
            delivered: VaultJSON.bool(o, "delivered") ?? false, read: VaultJSON.bool(o, "read") ?? false,
            attachment: VaultJSON.obj(o, "attachment")
        )
    }
}

/// One page of `message.list` (§10.5.2): [messages] oldest first; [nextBefore] the `message_id` of the page's oldest
/// message when older ones remain (the next page's `before`), nil at the start of the conversation.
public struct MessagePage: Sendable {
    public let messages: [Message]
    public let nextBefore: String?

    public init(messages: [Message], nextBefore: String?) {
        self.messages = messages
        self.nextBefore = nextBefore
    }

    /// `{messages, next_before?}`. An entry that is not a message is left out (chosen; not in the spec: vettid-android
    /// refuses the whole page), and an empty `next_before` counts as absent.
    public static func of(_ o: JsonObject) -> MessagePage {
        let next = VaultJSON.string(o, "next_before").flatMap { $0.isEmpty ? nil : $0 }
        return MessagePage(messages: VaultJSON.objects(o, "messages").compactMap(Message.of), nextBefore: next)
    }
}

/// `message.send`'s answer (§10.5): the vault's id for the message and its `sent_at`.
public struct SentMessage: Equatable, Sendable {
    public let messageID: String
    public let sentAt: String

    public init(messageID: String, sentAt: String) {
        self.messageID = messageID
        self.sentAt = sentAt
    }
}
