#if DEBUG
import Foundation
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The fake vault's messages (VAULT-MESSAGING §10.5, §10.5.2), answered with the shapes, codes, events and
/// recipients of vettid-vault `features/messaging`: `message.new` to every owner device for a message the peer delivered
/// (`NotifyAllDevices`) but not to the sending device for its own send (`NotifyDevices`), `sync.event{message.receipt}`
/// to every device, and `sync.event{message.read}` only to the devices that did not read (so never to this one phone).
/// The other vault is emulated: what it delivers, and the receipts it sends, reach this vault as the real one's would.
struct FakeMessaging {
    struct Delivered {
        var connectionID: String
        var messageID: String
        var text: String
    }

    struct Message {
        var id: String
        var outgoing: Bool
        var text: String
        var sentAt: Date
        var delivered = false
        var read = false
    }

    /// The conversations by connection, in arrival order (vettid-vault's `convs`).
    var conversations: [String: [Message]] = [:]
    /// What this vault sent the other vaults (`message.deliver` and `message.receipt`), in order.
    var delivered: [Delivered] = []
    var receiptsSent: [(messageID: String, receipt: String)] = []
    /// The peer's vault answers each delivery with its `delivered` receipt at once, unless the test holds them.
    var holdReceipts = false
    /// The peer's `delivered` receipt reaches this phone before the answer to its `message.send`.
    var receiptFirst = false
    /// The peer's mailbox cannot be reached: `message.send` is `connection_unavailable`.
    var peerUnreachable = false
    /// A page of more messages than this cannot be sealed (`response_too_large`, §8.1); nil: no such limit.
    var sealableMessages: Int?
}

extension FakeVaultService {
    /// vettid-vault's `MaxText`, `MaxLimit`, `DefaultLimit` and `pageBytes`.
    static let maxMessageText = 16 * 1_024
    static let maxPageLimit: UInt64 = 500
    static let defaultPageLimit: UInt64 = 100
    static let pageBytes = 131_072

    /// The message requests (§10.5); `unsupported_type` for any other. Callers hold ``cond``.
    func messagesRequest(_ m: Inner, _ body: JsonObject) throws {
        switch m.type {
        case "message.send": try messageSend(m, body)
        case "message.list": try messageList(m, body)
        case "message.get", "message.read", "message.delete":
            guard let conn = try? body.string("connection_id"), let id = try? body.string("message_id") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
            guard let i = social.messages.conversations[conn]?.firstIndex(where: { $0.id == id }) else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            try messageAt(m, conn, i)
        default: try reply(m.type, "{}", re: m.id, error: "unsupported_type")
        }
    }

    /// `message.get`, `.read` and `.delete` of the message at [i] of [conn]'s conversation. Callers hold ``cond``.
    private func messageAt(_ m: Inner, _ conn: String, _ i: Int) throws {
        guard var msg = social.messages.conversations[conn]?[i] else { return }
        switch m.type {
        case "message.get": try reply(m.type, Self.messageJSON(conn, msg), re: m.id)
        case "message.read":
            guard !msg.outgoing else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            if !msg.read {
                msg.read = true
                social.messages.conversations[conn]?[i] = msg
                social.messages.receiptsSent.append((msg.id, "read"))
            }
            try reply(m.type, "{}", re: m.id)
        default:
            social.messages.conversations[conn]?.remove(at: i)
            try reply(m.type, "{}", re: m.id)
        }
    }

    static func messageJSON(_ conn: String, _ m: FakeMessaging.Message) -> String {
        JsonBuilder().string("connection_id", conn).string("message_id", m.id).string("direction", m.outgoing ? "out" : "in").string("text", m.text).string("sent_at", Timestamps.formatMillis(m.sentAt)).bool("delivered", m.delivered).bool("read", m.read).build()
    }

    /// `message.send` (vettid-vault `send`): `not_found` for an unknown connection, `bad_request` for an empty text or one
    /// above 16 KiB, `connection_unavailable` when the peer cannot be reached; the sender is not sent `message.new`.
    private func messageSend(_ m: Inner, _ body: JsonObject) throws {
        guard let conn = try? body.string("connection_id") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard social.connections[conn] != nil else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        guard !body.has("attachment"), let text = try? body.string("text"), !text.isEmpty, text.utf8.count <= Self.maxMessageText else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard !social.messages.peerUnreachable else { return try reply(m.type, "{}", re: m.id, error: "connection_unavailable") }
        let msg = FakeMessaging.Message(id: Ulid.new(), outgoing: true, text: text, sentAt: Self.millis(Date()))
        social.messages.conversations[conn, default: []].append(msg)
        social.messages.delivered.append(FakeMessaging.Delivered(connectionID: conn, messageID: msg.id, text: text))
        let early = social.messages.receiptFirst && !social.messages.holdReceipts
        if early { try receiptArrived(conn, msg.id, "delivered") }
        try reply(m.type, JsonBuilder().string("message_id", msg.id).string("sent_at", Timestamps.formatMillis(msg.sentAt)).build(), re: m.id)
        if !social.messages.holdReceipts, !early { try receiptArrived(conn, msg.id, "delivered") }
    }

    static func millis(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000) }

    /// `message.list` (vettid-vault `listFor`, §10.5.2): newest first from `before` (exclusive; `not_found` when the vault
    /// does not hold it) or the newest, within `limit` and the 131,072-byte budget, returned oldest first with
    /// `next_before` while older messages remain.
    private func messageList(_ m: Inner, _ body: JsonObject) throws {
        let conn: String, limit: Int, before: String?
        do {
            conn = try body.string("connection_id")
            limit = Int(try body.optUint("limit", min: 1, max: Self.maxPageLimit) ?? Self.defaultPageLimit)
            before = try body.optString("before")
        } catch {
            return try reply(m.type, "{}", re: m.id, error: "bad_request")
        }
        if let n = social.messages.sealableMessages, limit > n { return try reply(m.type, "{}", re: m.id, error: "response_too_large") }
        let ms = social.messages.conversations[conn] ?? []
        var end = ms.count
        if let before {
            guard let i = ms.firstIndex(where: { $0.id == before }) else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            end = i
        }
        var size = #"{"messages":[]}"#.utf8.count
        var items: [String] = []
        var start = end
        while start > 0, items.count < limit {
            let item = Self.messageJSON(conn, ms[start - 1])
            var n = size + item.utf8.count + (items.isEmpty ? 0 : 1)
            if start - 1 > 0 { n += #","next_before":""#.utf8.count + ms[start - 1].id.utf8.count }
            if !items.isEmpty, n > Self.pageBytes { break }
            size += item.utf8.count + (items.isEmpty ? 0 : 1)
            items.append(item)
            start -= 1
        }
        var b = JsonBuilder().raw("messages", JsonBuilder.array(items.reversed()))
        if start > 0 { b = b.string("next_before", ms[start].id) }
        try reply(m.type, b.build(), re: m.id)
    }

    /// The peer's `message.receipt` for an outgoing message (vettid-vault `receipt`): marked, and every device is told.
    /// Callers hold ``cond``.
    func receiptArrived(_ conn: String, _ id: String, _ receipt: String) throws {
        guard let i = social.messages.conversations[conn]?.firstIndex(where: { $0.id == id && $0.outgoing }) else { return }
        social.messages.conversations[conn]?[i].delivered = true
        if receipt == "read" { social.messages.conversations[conn]?[i].read = true }
        try reply("sync.event", JsonBuilder().string("kind", "message.receipt").string("connection_id", conn).string("message_id", id).string("receipt", receipt).build())
    }

    // MARK: - The other member, and the owner's other devices

    /// The connection's member sent [text] (`message.deliver`, vettid-vault `deliver`): stored in arrival order, every
    /// device gets `message.new`, and the peer gets the `delivered` receipt. [sentAt] is the sender's clock. Returns the
    /// message id.
    @discardableResult
    public func peerSends(_ connectionID: String, _ text: String, sentAt: Date = Date()) throws -> String {
        try locked {
            guard social.connections[connectionID] != nil else { throw CryptoError.format("unknown connection") }
            let msg = FakeMessaging.Message(id: Ulid.new(), outgoing: false, text: text, sentAt: Self.millis(sentAt))
            social.messages.conversations[connectionID, default: []].append(msg)
            social.messages.receiptsSent.append((msg.id, "delivered"))
            try reply("message.new", Self.messageJSON(connectionID, msg))
            return msg.id
        }
    }

    /// The connection's member read (or their vault stored, `delivered`) the outgoing message [messageID].
    public func peerReceipt(_ connectionID: String, _ messageID: String, _ receipt: String = "read") throws {
        try locked { try receiptArrived(connectionID, messageID, receipt) }
    }

    /// Another device of the owner read the incoming message [messageID]: this phone gets `sync.event{message.read}`.
    public func otherDeviceReads(_ connectionID: String, _ messageID: String) throws {
        try locked {
            guard let i = social.messages.conversations[connectionID]?.firstIndex(where: { $0.id == messageID }) else { return }
            social.messages.conversations[connectionID]?[i].read = true
            try reply("sync.event", JsonBuilder().string("kind", "message.read").string("connection_id", connectionID).string("message_id", messageID).build())
        }
    }

    /// Another device of the owner deleted [messageID] (`message.delete` sends no event).
    public func otherDeviceDeletes(_ connectionID: String, _ messageID: String) {
        locked { social.messages.conversations[connectionID]?.removeAll { $0.id == messageID } }
    }

    /// Messages stored without any event, as if they arrived while this phone was away: [count] incoming texts.
    public func storeMessages(_ connectionID: String, count: Int, text: (Int) -> String = { "message \($0)" }) {
        locked {
            for n in 0..<count {
                social.messages.conversations[connectionID, default: []].append(FakeMessaging.Message(id: Ulid.new(), outgoing: n % 2 == 1, text: text(n), sentAt: Self.millis(Date())))
            }
        }
    }

    // MARK: - Switches and what the test reads

    public var holdsReceipts: Bool {
        get { locked { social.messages.holdReceipts } }
        set { locked { social.messages.holdReceipts = newValue } }
    }

    public var receiptsBeforeAnswers: Bool {
        get { locked { social.messages.receiptFirst } }
        set { locked { social.messages.receiptFirst = newValue } }
    }

    public var peerUnreachable: Bool {
        get { locked { social.messages.peerUnreachable } }
        set { locked { social.messages.peerUnreachable = newValue } }
    }

    public var sealableMessages: Int? {
        get { locked { social.messages.sealableMessages } }
        set { locked { social.messages.sealableMessages = newValue } }
    }

    /// The texts this vault delivered to the connection's member, in order (what the other member's app shows).
    public func peerInbox(_ connectionID: String) -> [String] {
        locked { social.messages.delivered.filter { $0.connectionID == connectionID }.map(\.text) }
    }

    /// The receipts this vault sent the other vaults: `delivered` for each message received, `read` for each read here.
    public var receiptsSent: [(messageID: String, receipt: String)] { locked { social.messages.receiptsSent } }

    /// The ids of the vault's messages with [connectionID], in arrival order.
    public func messageIDs(_ connectionID: String) -> [String] {
        locked { social.messages.conversations[connectionID]?.map(\.id) ?? [] }
    }
}

// swiftlint:enable line_length
#endif
