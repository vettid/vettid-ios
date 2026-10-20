import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault calls of ``MessagesManager``: a conversation per connection, in arrival order, paged as
/// vettid-vault pages it (by count only); every call recorded.
final class FakeMessageOps: MessageOps, @unchecked Sendable {
    var calls: [String] = []
    var errors: [String: VaultOpError] = [:]
    /// The conversations, oldest first.
    var stored: [String: [Message]] = [:]
    /// A page of more messages than this is `response_too_large`.
    var sealable = Int.max
    /// Set: `message.list` waits for it.
    var listGate: TestDeferred<Void>?
    private var sent = 0

    private func call(_ name: String) throws {
        calls.append(name)
        if let e = errors.removeValue(forKey: String(name.prefix { $0 != ":" })) { throw e }
    }

    static func error(_ type: String, _ code: String) -> VaultOpError { VaultOpError(type: type, code: code, detail: "", body: nil) }

    static func message(_ conn: String, _ id: String, outgoing: Bool = false, text: String = "hi", read: Bool = false) -> Message {
        Message(connectionID: conn, messageID: id, direction: outgoing ? "out" : "in", text: text, sentAt: "2026-10-20T12:00:00.000Z", delivered: false, read: read, attachment: nil)
    }

    func messageSend(_ connectionID: String, text: String) async throws -> SentMessage {
        try call("send:\(connectionID)")
        sent += 1
        return SentMessage(messageID: "s\(sent)", sentAt: "2026-10-20T12:30:00.000Z")
    }

    func messagePage(_ connectionID: String, limit: Int?, before: String?) async throws -> MessagePage {
        try call("list:\(connectionID):\(limit ?? 0):\(before ?? "")")
        if let g = listGate { try await g.value() }
        let limit = limit ?? 100
        if limit > sealable { throw Self.error("message.list", "response_too_large") }
        let all = stored[connectionID] ?? []
        var end = all.count
        if let before {
            guard let i = all.firstIndex(where: { $0.messageID == before }) else { throw Self.error("message.list", "not_found") }
            end = i
        }
        let start = max(0, end - limit)
        return MessagePage(messages: Array(all[start..<end]), nextBefore: start > 0 ? all[start].messageID : nil)
    }

    func messageRead(_ connectionID: String, messageID: String) async throws { try call("read:\(messageID)") }
    func messageDelete(_ connectionID: String, messageID: String) async throws { try call("delete:\(messageID)") }
}

/// The messages manager over its vault calls: sending and its limits, pages and their merging, the events, reads and
/// deletions, the conversations, and the lock's generation guard. Mirrors the message parts of vettid-android
/// `SocialManager`'s behaviour.
@MainActor
@Suite struct MessagesManagerTests {
    let ops = FakeMessageOps()
    let quiet = FakeMessageOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)

    func manager(connections: [ConnectionInfo] = [ConnectionInfo(id: "c1", name: "", state: .active)]) -> MessagesManager {
        let ops = ops, quiet = quiet, now = now
        return MessagesManager(ops: { ops }, quietOps: { quiet }, connections: { connections }, now: { now })
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    func kind(_ op: () async throws -> some Any) async -> FailureKind? {
        do {
            _ = try await op()
            return nil
        } catch {
            return (error as? VaultFailure)?.kind
        }
    }

    func store(_ conn: String, _ n: Int) {
        ops.stored[conn] = (1...n).map { FakeMessageOps.message(conn, String(format: "m%03d", $0), outgoing: $0 % 3 == 0) }
    }

    /// §10.5: 1 byte to 16 KiB in UTF-8, refused before anything is sent.
    @Test func theTextLimitsAreCheckedBeforeSending() async throws {
        let m = manager()
        #expect(await kind { try await m.send("c1", text: "") } == .limit)
        #expect(await kind { try await m.send("c1", text: String(repeating: "a", count: 16_385)) } == .limit)
        #expect(await kind { try await m.send("c1", text: String(repeating: "é", count: 8_193)) } == .limit, "16,386 bytes")
        #expect(ops.calls.isEmpty)
        try await m.send("c1", text: String(repeating: "é", count: 8_192))
        #expect(ops.calls == ["send:c1"])
        #expect(MessageLimits.fits("a") && !MessageLimits.fits(""))
    }

    /// The vault does not send this device its own message: it joins the conversation from the answer.
    @Test func aSentMessageJoinsItsConversation() async throws {
        let m = manager()
        let sent = try await m.send("c1", text: "hello")
        #expect(sent.outgoing && sent.messageID == "s1" && !sent.delivered && sent.sentAt == FakeDates.date("2026-10-20T12:30:00Z"))
        #expect(m.messages("c1") == [sent])
        ops.errors["send"] = FakeMessageOps.error("message.send", "connection_unavailable")
        #expect(await kind { try await m.send("c1", text: "again") } == .connectionUnavailable)
        #expect(m.messages("c1").count == 1)
    }

    /// §10.5.2: the newest page first, then older ones with `before`, until the start.
    @Test func pagesAreLoadedNewestFirstThenOlder() async throws {
        store("c1", 250)
        let m = manager()
        try await m.load("c1")
        #expect(m.messages("c1").count == 100 && m.messages("c1").last?.messageID == "m250" && m.olderAvailable("c1"))
        try await m.loadOlder("c1")
        try await m.loadOlder("c1")
        #expect(m.messages("c1").map(\.messageID) == (1...250).map { String(format: "m%03d", $0) })
        #expect(!m.olderAvailable("c1"))
        try await m.loadOlder("c1")
        #expect(ops.calls == ["list:c1:100:", "list:c1:100:m151", "list:c1:100:m051"], "nothing older to ask for")
    }

    /// §8.1: a page that cannot be sealed is asked for again with half as many messages, down to one.
    @Test func aPageTooLargeIsAskedForInSmallerPages() async throws {
        store("c1", 30)
        ops.sealable = 12
        let m = manager()
        try await m.load("c1")
        #expect(ops.calls == ["list:c1:100:", "list:c1:50:", "list:c1:25:", "list:c1:12:"])
        #expect(m.messages("c1").count == 12)
        ops.sealable = 0
        #expect(await kind { try await m.load("c1") } == .responseTooLarge)
        #expect(ops.calls.suffix(7) == ["list:c1:100:", "list:c1:50:", "list:c1:25:", "list:c1:12:", "list:c1:6:", "list:c1:3:", "list:c1:1:"])
    }

    /// §10.5.2: a position the vault no longer holds (deleted on another device) starts again from the newest page.
    @Test func aPositionNoLongerHeldStartsAgainFromTheNewest() async throws {
        store("c1", 150)
        let m = manager()
        try await m.load("c1")
        ops.stored["c1"]?.removeAll { $0.messageID == "m051" }
        try await m.loadOlder("c1")
        #expect(ops.calls.suffix(2) == ["list:c1:100:m051", "list:c1:100:"])
        #expect(m.messages("c1").count == 100 && m.messages("c1").first?.messageID == "m050" && m.olderAvailable("c1"))
    }

    /// A reload that replaced the position while an older page was on its way: that page is not the next one.
    @Test func anOlderPageAnsweredAfterAReloadIsDropped() async throws {
        store("c1", 150)
        let m = manager()
        try await m.load("c1")
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let older = Task { try await m.loadOlder("c1") }
        #expect(await eventually { ops.calls.count == 2 })
        ops.listGate = nil
        ops.stored["c1"]?.append(contentsOf: (151...300).map { FakeMessageOps.message("c1", String(format: "m%03d", $0)) })
        try await m.load("c1")
        gate.complete(())
        try await older.value
        #expect(m.messages("c1").first?.messageID == "m201" && m.messages("c1").count == 100, "the page that did not join was not merged")
    }

    /// The vault locked while a read was on its way: its answer is not taken in (chosen; not in the spec).
    @Test func anAnswerAfterTheLockIsDropped() async throws {
        store("c1", 5)
        let m = manager()
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let load = Task { try await m.load("c1") }
        #expect(await eventually { ops.calls.count == 1 })
        m.forgetOpenVault()
        gate.complete(())
        try await load.value
        #expect(m.messages("c1").isEmpty && !m.olderAvailable("c1"))
    }

    /// `message.new`: a new message joins at the end in arrival order, whatever its `sent_at`; one already there is
    /// replaced keeping its receipts. The receipts and another device's read patch it.
    @Test func eventsBringMessagesReceiptsAndReads() async throws {
        let m = manager()
        m.onEvent(event("message.new", #"{"connection_id":"c1","message_id":"m2","direction":"in","text":"later clock","sent_at":"2026-10-20T13:00:00.000Z","delivered":false,"read":false}"#))
        m.onEvent(event("message.new", #"{"connection_id":"c1","message_id":"m1","direction":"out","text":"earlier clock","sent_at":"2026-10-20T11:00:00.000Z","delivered":false,"read":false}"#))
        #expect(m.messages("c1").map(\.messageID) == ["m2", "m1"])
        m.onEvent(event("sync.event", #"{"kind":"message.receipt","connection_id":"c1","message_id":"m1","receipt":"delivered"}"#))
        #expect(m.messages("c1")[1].delivered && !m.messages("c1")[1].read)
        m.onEvent(event("sync.event", #"{"kind":"message.receipt","connection_id":"c1","message_id":"m1","receipt":"read"}"#))
        #expect(m.messages("c1")[1].read)
        m.onEvent(event("message.new", #"{"connection_id":"c1","message_id":"m1","direction":"out","text":"earlier clock","sent_at":"2026-10-20T11:00:00.000Z","delivered":false,"read":false}"#))
        #expect(m.messages("c1").count == 2 && m.messages("c1")[1].read, "a repeat keeps the receipts")
        m.onEvent(event("sync.event", #"{"kind":"message.read","connection_id":"c1","message_id":"m2"}"#))
        #expect(m.messages("c1")[0].read)
        m.onEvent(event("message.new", #"{"connection_id":"c1","message_id":"m3"}"#))
        m.onEvent(event("sync.event", #"{"kind":"message.read","connection_id":"c9","message_id":"m2"}"#))
        #expect(m.messages("c1").count == 2 && m.messages("c9").isEmpty, "malformed or unknown: nothing")
    }

    /// One `message.read` per unread incoming message; one the vault no longer holds is dropped and the others go on
    /// (chosen; not in the spec).
    @Test func markingReadReadsEachUnreadIncomingMessage() async throws {
        ops.stored["c1"] = [
            FakeMessageOps.message("c1", "m1", read: true), FakeMessageOps.message("c1", "m2"),
            FakeMessageOps.message("c1", "m3", outgoing: true), FakeMessageOps.message("c1", "m4"), FakeMessageOps.message("c1", "m5"),
        ]
        let m = manager()
        try await m.load("c1")
        ops.calls = []
        ops.errors["read"] = FakeMessageOps.error("message.read", "not_found")
        try await m.markRead("c1")
        #expect(ops.calls == ["read:m2", "read:m4", "read:m5"])
        #expect(m.messages("c1").map(\.messageID) == ["m1", "m3", "m4", "m5"] && m.messages("c1").allSatisfy { $0.outgoing || $0.read })
        try await m.markRead("c1")
        #expect(ops.calls.count == 3, "nothing unread: nothing sent")
        ops.errors["read"] = FakeMessageOps.error("message.read", "retry")
        m.onEvent(event("message.new", #"{"connection_id":"c1","message_id":"m6","direction":"in","text":"x","sent_at":"t"}"#))
        #expect(await kind { try await m.markRead("c1") } == .retry)
    }

    /// `message.delete` is local to this vault; one already gone is deleted (chosen; not in the spec).
    @Test func deletingRemovesTheMessage() async throws {
        store("c1", 3)
        let m = manager()
        try await m.load("c1")
        try await m.delete("c1", messageID: "m002")
        ops.errors["delete"] = FakeMessageOps.error("message.delete", "not_found")
        try await m.delete("c1", messageID: "m003")
        #expect(m.messages("c1").map(\.messageID) == ["m001"])
        ops.errors["delete"] = FakeMessageOps.error("message.delete", "retry")
        #expect(await kind { try await m.delete("c1", messageID: "m001") } == .retry)
        #expect(m.messages("c1").count == 1)
    }

    /// The rows: every active connection (and another with messages), newest conversation first, with unread counts.
    @Test func conversationsAreTheConnectionsNewestFirst() async throws {
        var a = ConnectionInfo(id: "a", name: "", state: .active)
        a.createdAt = now
        let b = ConnectionInfo(id: "b", name: "", state: .active)
        let gone = ConnectionInfo(id: "g", name: "", state: .stale)
        let quietGone = ConnectionInfo(id: "q", name: "", state: .stale)
        let m = manager(connections: [a, b, gone, quietGone])
        #expect(m.conversations.map(\.id) == ["a", "b"], "without messages: by creation")
        m.onEvent(event("message.new", #"{"connection_id":"b","message_id":"m1","direction":"in","text":"x","sent_at":"2026-10-20T12:00:00.000Z"}"#))
        m.onEvent(event("message.new", #"{"connection_id":"g","message_id":"m2","direction":"in","text":"y","sent_at":"2026-10-20T11:00:00.000Z","read":true}"#))
        #expect(m.conversations.map(\.id) == ["b", "g", "a"])
        #expect(m.conversations.map(\.unread) == [1, 0, 0] && m.conversations.first?.last?.text == "x")
        m.forgetConversation("b")
        #expect(m.conversations.map(\.id) == ["g", "a", "b"] && m.messages("b").isEmpty, "b still listed here: its messages are gone")
    }

    /// Refreshing reads the connections first when none are known, then each active one's newest page; the quiet refresh
    /// goes only over the quiet calls and never reads the connections.
    @Test func refreshingReadsEachActiveConversation() async throws {
        var known: [ConnectionInfo] = []
        let ops = ops, quiet = quiet
        let m = MessagesManager(ops: { ops }, quietOps: { quiet }, connections: { known }, refreshConnections: {
            known = [ConnectionInfo(id: "c1", name: "", state: .active), ConnectionInfo(id: "c2", name: "", state: .pending)]
        })
        try await m.refreshConversations()
        #expect(ops.calls == ["list:c1:100:"])
        await m.refreshConversationsQuietly()
        #expect(ops.calls.count == 1 && quiet.calls == ["list:c1:100:"])
    }

    /// The vault call's failure is a ``VaultFailure``; a connection the vault does not know is `not_found`.
    @Test func failuresAreVaultFailures() async throws {
        let m = manager()
        ops.errors["send"] = FakeMessageOps.error("message.send", "not_found")
        #expect(await kind { try await m.send("c1", text: "x") } == .notFound)
        ops.errors["list"] = FakeMessageOps.error("message.list", "bad_request")
        #expect(await kind { try await m.load("c1") } != nil)
    }
}

// swiftlint:enable line_length
