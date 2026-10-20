import Foundation
import VettIDCrypto

// Messaging (VAULT-MESSAGING §10.5) and the paging of `message.list` (§10.5.2): one function per type, the shapes of
// vettid-vault `features/messaging`. Attachments (§10.5.1) come with the photos (IOS-PLAN §8 I2.4). Mirrors the messaging
// part of vettid-android `VaultApi`.
extension VaultApi {
    /// `message.send` of [text] (1 byte to 16 KiB in UTF-8) to an active connection: `bad_request` outside the limits,
    /// `not_found` for an unknown connection, `connection_unavailable` when the vault cannot reach the peer's mailbox.
    public func messageSend(_ connectionID: String, text: String) async throws -> SentMessage {
        let b = JsonBuilder().string("connection_id", connectionID).string("text", text)
        let o = VaultJSON.object(try await device.op("message.send", body: b.bytes()))
        guard let id = VaultJSON.string(o, "message_id"), let at = VaultJSON.string(o, "sent_at") else {
            throw VaultStateError(message: "message.send without message_id or sent_at")
        }
        return SentMessage(messageID: id, sentAt: at)
    }

    /// One page of `message.list` (§10.5.2): without [before] the page ends with the newest message, with it the messages
    /// the vault stored before that `message_id` (exclusive). Oldest first, at most [limit] (1–500; the vault's default
    /// 100) and 131,072 bytes. A [before] the vault does not hold is `not_found` (the app starts again from the newest);
    /// an answer the vault could not seal is `response_too_large` (§8.1). Volatile (§8.2).
    public func messagePage(_ connectionID: String, limit: Int? = nil, before: String? = nil) async throws -> MessagePage {
        let b = JsonBuilder().string("connection_id", connectionID)
        if let limit { b.uint("limit", UInt64(max(limit, 1))) }
        if let before { b.string("before", before) }
        return MessagePage.of(VaultJSON.object(try await device.op("message.list", body: b.bytes())))
    }

    /// `message.get`: one message; `not_found`. Volatile (§8.2).
    public func messageGet(_ connectionID: String, messageID: String) async throws -> Message {
        let b = JsonBuilder().string("connection_id", connectionID).string("message_id", messageID)
        guard let m = Message.of(VaultJSON.object(try await device.op("message.get", body: b.bytes()))) else {
            throw VaultStateError(message: "message.get without a message")
        }
        return m
    }

    /// `message.read` of an incoming message: the vault sends the peer a read receipt and tells the owner's other devices
    /// (`sync.event{message.read}`); `not_found` for an unknown or outgoing one.
    public func messageRead(_ connectionID: String, messageID: String) async throws {
        let b = JsonBuilder().string("connection_id", connectionID).string("message_id", messageID)
        _ = try await device.op("message.read", body: b.bytes())
    }

    /// `message.delete`: on this vault only (the connection keeps its copy); `not_found`.
    public func messageDelete(_ connectionID: String, messageID: String) async throws {
        let b = JsonBuilder().string("connection_id", connectionID).string("message_id", messageID)
        _ = try await device.op("message.delete", body: b.bytes())
    }
}
