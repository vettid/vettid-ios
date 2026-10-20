import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The messaging calls (VAULT-MESSAGING §10.5, §10.5.2) against the fake vault: the request bodies as vettid-vault
/// `features/messaging` reads them, and the answers' models.
@Suite struct MessageOpsTests {
    let ops = CredentialOpsTests()

    @Test func sendSendsTheTextAndReadsTheIdAndTime() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let send = Task { try await api.messageSend("c1", text: "hé \"there\"") }
        let req = try await ops.answer(v, d, "message.send", #"{"message_id":"01JMSG0000000000000000000A","sent_at":"2026-10-20T12:00:00.123Z"}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"connection_id":"c1","text":"hé \"there\""}"#)
        #expect(try await send.value == SentMessage(messageID: "01JMSG0000000000000000000A", sentAt: "2026-10-20T12:00:00.123Z"))
    }

    @Test func sendWithoutAnIdIsAnError() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let send = Task { try await api.messageSend("c1", text: "hi") }
        try await ops.answer(v, d, "message.send", #"{"sent_at":"2026-10-20T12:00:00.123Z"}"#)
        await #expect(throws: VaultStateError.self) { _ = try await send.value }
    }

    /// §10.5.2: `limit` and `before` only when given; the page oldest first with its `next_before`.
    @Test func aPageAsksWithItsPositionAndReadsNextBefore() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let first = Task { try await api.messagePage("c1") }
        var req = try await ops.answer(v, d, "message.list", #"{"messages":[]}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"connection_id":"c1"}"#)
        #expect(try await first.value.messages.isEmpty)

        let older = Task { try await api.messagePage("c1", limit: 50, before: "01JMSG0000000000000000000B") }
        let page = #"{"messages":[{"connection_id":"c1","message_id":"m1","direction":"in","text":"one","sent_at":"2026-10-20T12:00:00.000Z","delivered":false,"read":true},{"connection_id":"c1","message_id":"m2","direction":"out","text":"","sent_at":"2026-10-20T12:00:01.000Z","delivered":true,"read":false,"attachment":{"att_id":"a1"}}],"next_before":"m1"}"#
        req = try await ops.answer(v, d, "message.list", page)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"connection_id":"c1","limit":50,"before":"01JMSG0000000000000000000B"}"#)
        let p = try await older.value
        #expect(p.nextBefore == "m1" && p.messages.map(\.messageID) == ["m1", "m2"])
        #expect(p.messages[0].direction == "in" && p.messages[0].read && !p.messages[0].delivered && p.messages[0].attachment == nil)
        #expect(p.messages[1].delivered && p.messages[1].text.isEmpty && p.messages[1].attachment != nil)
    }

    /// `not_found` and `response_too_large` reach the caller with their codes.
    @Test func aPagesErrorsKeepTheirCodes() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let page = Task { try await api.messagePage("c1", limit: 100) }
        try await ops.answer(v, d, "message.list", code: "response_too_large", errorBody: "{}")
        do {
            _ = try await page.value
            Issue.record("expected an error")
        } catch let e as VaultOpError {
            #expect(e.code == "response_too_large")
        }
    }

    @Test func readDeleteAndGetNameTheMessage() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let body = #"{"connection_id":"c1","message_id":"m1"}"#
        let read = Task { try await api.messageRead("c1", messageID: "m1") }
        #expect(String(bytes: try await ops.answer(v, d, "message.read").body, encoding: .utf8) == body)
        try await read.value
        let delete = Task { try await api.messageDelete("c1", messageID: "m1") }
        #expect(String(bytes: try await ops.answer(v, d, "message.delete").body, encoding: .utf8) == body)
        try await delete.value
        let get = Task { try await api.messageGet("c1", messageID: "m1") }
        let req = try await ops.answer(v, d, "message.get", #"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"2026-10-20T12:00:00.000Z","delivered":false,"read":false}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == body)
        #expect(try await get.value.text == "hi")
    }

    /// §10.1: unknown members are ignored; an entry without a required member is left out; an empty `next_before` is none.
    @Test func modelsReadWhatTheVaultSends() throws {
        let ok = try StrictJson.parseObject(#"{"connection_id":"c1","message_id":"m1","direction":"out","text":"x","sent_at":"t","extra":1}"#)
        let m = try #require(Message.of(ok))
        #expect(m.direction == "out" && !m.delivered && !m.read)
        for missing in ["connection_id", "message_id", "direction", "text", "sent_at"] {
            var fields = ["connection_id": "c1", "message_id": "m1", "direction": "in", "text": "x", "sent_at": "t"]
            fields[missing] = nil
            let b = fields.keys.sorted().reduce(JsonBuilder()) { $0.string($1, fields[$1] ?? "") }
            #expect(Message.of(try StrictJson.parseObject(b.build())) == nil, "\(missing)")
        }
        let page = MessagePage.of(try StrictJson.parseObject(#"{"messages":[{"message_id":"m0"},{"connection_id":"c1","message_id":"m1","direction":"in","text":"x","sent_at":"t"}],"next_before":""}"#))
        #expect(page.messages.map(\.messageID) == ["m1"] && page.nextBefore == nil)
    }
}

// swiftlint:enable line_length
