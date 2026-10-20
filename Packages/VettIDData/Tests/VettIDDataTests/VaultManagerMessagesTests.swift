import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

// Request bodies stay on one line each.
// swiftlint:disable line_length

/// Messages end to end (VAULT-MESSAGING §10.5, §10.5.2; IOS-PLAN §8 I2.2's acceptance: messages both ways with the
/// peer): this phone against ``FakeVaultService``, which answers the message types as vettid-vault's
/// `features/messaging` does and emulates the other member's vault (its messages, its receipts) and the owner's other
/// devices. On the dev stack the other member is `vaultctl`'s peer.
@MainActor
@Suite(.serialized) struct VaultManagerMessagesTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var c: ConnectionsManager { phone.manager.connections }
    var msgs: MessagesManager { phone.manager.messages }

    /// Enrolled and open, connected with another member; returns the connection id.
    func connected() async throws -> String {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        let r = try await c.acceptInvite(try service.peerInvite(first: "Morgan", last: "Lee", name: "Mo"))
        #expect(await eventually { c.requests.first?.sas != nil })
        try service.peerApproves(r.connectionID)
        try await c.approveOutgoing(r.connectionID)
        #expect(await eventually { c.connections.map(\.id) == [r.connectionID] })
        return r.connectionID
    }

    func kind(_ op: () async throws -> some Any) async -> FailureKind? {
        do {
            _ = try await op()
            return nil
        } catch {
            return (error as? VaultFailure)?.kind
        }
    }

    func reads() -> Int { service.requestsSeen.filter { $0 == "message.list" }.count }

    /// I2.2's acceptance: a message to the other member reaches them and their vault's receipts come back; a message from
    /// them arrives, is read here, and their vault is told.
    @Test func messagesBothWaysWithThePeer() async throws {
        defer { phone.close() }
        let id = try await connected()
        let sent = try await msgs.send(id, text: "Hello Morgan, see https://example.com/a.")
        #expect(service.peerInbox(id) == ["Hello Morgan, see https://example.com/a."])
        #expect(await eventually { msgs.messages(id).first?.delivered == true }, "the peer's vault stored it")
        try service.peerReceipt(id, sent.messageID, "read")
        #expect(await eventually { msgs.messages(id).first?.read == true })
        #expect(MessageLinks.links(in: sent.text).map(\.host) == ["example.com"])

        let inID = try service.peerSends(id, "Hi! vettid://connect#x is not a link")
        #expect(await eventually { msgs.messages(id).map(\.messageID) == [sent.messageID, inID] })
        let incoming = try #require(msgs.messages(id).last)
        #expect(!incoming.outgoing && !incoming.read && MessageLinks.links(in: incoming.text).isEmpty)
        #expect(msgs.conversations.first?.unread == 1 && msgs.conversations.first?.last?.messageID == inID)
        #expect(service.receiptsSent.map(\.receipt) == ["delivered"])
        try await msgs.markRead(id)
        #expect(msgs.conversations.first?.unread == 0)
        #expect(service.receiptsSent.map(\.receipt) == ["delivered", "read"] && service.receiptsSent.last?.messageID == inID)

        // What the vault holds is what the phone shows.
        msgs.forgetConversation(id)
        try await msgs.load(id)
        #expect(msgs.messages(id).map(\.messageID) == service.messageIDs(id))
        #expect(msgs.messages(id).allSatisfy { $0.outgoing ? $0.delivered && $0.read : $0.read })
    }

    /// The fake refuses what vettid-vault refuses, and the manager reports it.
    @Test func refusalsAsTheVaultAnswersThem() async throws {
        defer { phone.close() }
        let id = try await connected()
        #expect(await kind { try await msgs.send("01JNOCONNECTION00000000000", text: "x") } == .notFound)
        service.peerUnreachable = true
        #expect(await kind { try await msgs.send(id, text: "x") } == .connectionUnavailable)
        // IOS-PLAN §4.4 (2): a code this app does not map names itself.
        service.refuseNext("message.send", code: "internal", message: "detail")
        #expect(await kind { try await msgs.send(id, text: "x") } == .vaultCode("internal"))
        #expect(msgs.messages(id).isEmpty && service.peerInbox(id).isEmpty)
        service.peerUnreachable = false
        let api = try m.openApi(try await m.openSession())
        for bad in [#"{"connection_id":"\#(id)","text":""}"#, #"{"connection_id":"\#(id)","text":"\#(String(repeating: "a", count: 16_385))"}"#, #"{"connection_id":"\#(id)"}"#] {
            await #expect(throws: VaultOpError.self) { _ = try await api.device.op("message.send", body: Array(bad.utf8)) }
        }
        for bad in [#"{"connection_id":"\#(id)","limit":0}"#, #"{"connection_id":"\#(id)","limit":501}"#, #"{"connection_id":"\#(id)","before":7}"#] {
            await #expect(throws: VaultOpError.self) { _ = try await api.device.op("message.list", body: Array(bad.utf8)) }
        }
    }

    /// §10.5.2: a long history in pages of 100, older ones as the member scrolls, and the 131,072-byte budget for long
    /// messages; a position deleted on another device starts again from the newest page.
    @Test func aLongHistoryInPages() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.storeMessages(id, count: 230)
        try await msgs.load(id)
        #expect(msgs.messages(id).count == 100 && msgs.olderAvailable(id))
        try await msgs.loadOlder(id)
        try await msgs.loadOlder(id)
        #expect(msgs.messages(id).map(\.messageID) == service.messageIDs(id) && !msgs.olderAvailable(id))

        // Thirty messages of 16 KiB: a page stops before 128 KiB, and paging still reaches them all.
        service.storeMessages(id, count: 30) { _ in String(repeating: "x", count: 16_384) }
        msgs.forgetConversation(id)
        try await msgs.load(id)
        #expect(msgs.messages(id).count == 7, "7 × ~16.5 KB fit in 131,072 bytes, 8 do not")
        service.otherDeviceDeletes(id, try #require(msgs.messages(id).first?.messageID))
        try await msgs.loadOlder(id)
        #expect(msgs.messages(id).count == 7 && msgs.messages(id).last?.messageID == service.messageIDs(id).last)
    }

    /// §8.1: a page that cannot be sealed is asked for again in smaller pages.
    @Test func aPageThatCannotBeSealedIsAskedForInSmallerPages() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.storeMessages(id, count: 40)
        service.sealableMessages = 20
        try await msgs.load(id)
        #expect(msgs.messages(id).count == 12, "100, 50 and 25 refused; 12 fit")
    }

    /// Receipts, another device's read and its own sends reach this phone as events; a deletion is local to the vault.
    @Test func theOwnersOtherDevicesAndDeletion() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.holdsReceipts = true
        let sent = try await msgs.send(id, text: "one")
        try await Task.sleep(for: .milliseconds(200))
        #expect(msgs.messages(id).first?.delivered == false, "no receipt yet")
        try service.peerReceipt(id, sent.messageID, "delivered")
        #expect(await eventually { msgs.messages(id).first?.delivered == true && msgs.messages(id).first?.read == false })
        let inID = try service.peerSends(id, "two")
        #expect(await eventually { msgs.messages(id).count == 2 })
        try service.otherDeviceReads(id, inID)
        #expect(await eventually { msgs.messages(id).last?.read == true })
        try await msgs.markRead(id)
        #expect(service.receiptsSent.map(\.receipt) == ["delivered"], "already read on the other device: nothing sent")
        try await msgs.delete(id, messageID: sent.messageID)
        #expect(msgs.messages(id).map(\.messageID) == [inID] && service.messageIDs(id) == [inID])
        #expect(service.peerInbox(id) == ["one"], "the connection keeps its copy")
    }

    /// Locked, no message is kept in memory and nothing of them was ever written to the phone; the unlock reads the
    /// conversations again. A removed connection's conversation goes with it.
    @Test func messagesFollowTheLockAndTheConnection() async throws {
        defer { phone.close() }
        let id = try await connected()
        try service.peerSends(id, "kept in the vault only")
        #expect(await eventually { msgs.messages(id).count == 1 })
        try await m.lock()
        #expect(msgs.messages(id).isEmpty && msgs.conversations.isEmpty)
        // The device keeps saving its state (atomic writes): a temporary file listed here may be renamed before it is
        // read, and is then read under its final name.
        let files = try FileManager.default.contentsOfDirectory(atPath: phone.directory.path)
        for f in files {
            guard let data = try? Data(contentsOf: phone.directory.appendingPathComponent(f)) else { continue }
            #expect(data.range(of: Data("kept in the vault only".utf8)) == nil, "\(f)")
        }
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { msgs.messages(id).map(\.text) == ["kept in the vault only"] }, "read again at the opening")
        try await c.remove(id)
        #expect(msgs.messages(id).isEmpty && msgs.conversations.isEmpty)
    }

    /// Nothing the vault sends is taken in while a lock is pending (as vettid-android).
    @Test func eventsWhileALockIsPendingAreNotTaken() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        let body = #"{"connection_id":"\#(id)","message_id":"01JMSG0000000000000000000A","direction":"in","text":"late","sent_at":"2026-10-20T12:00:00.000Z"}"#
        m.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "message.new", ts: Date(), body: Array(body.utf8))))
        #expect(msgs.messages(id).isEmpty)
        #expect(await kind { try await msgs.send(id, text: "x") } == .other, "nothing goes to a vault whose lock is pending")
        #expect(service.peerInbox(id).isEmpty)
    }

    /// The opening and a passed owner check read the conversations (after the connections); in the background a read
    /// nobody asked for sends nothing and opens no session.
    @Test func quietReadsAtTheOpeningButNeverInTheBackground() async throws {
        defer { phone.close() }
        _ = try await connected()
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { reads() == 1 }, "the conversation read at the opening")
        #expect(try await m.ownerChecks.check(pin: pin, password: "correct horse battery", holdOff: nil) == .passed)
        #expect(await eventually { reads() == 2 })
        await m.onBackground()
        #expect(m.session == nil)
        await msgs.refreshConversationsQuietly()
        #expect(m.session == nil && reads() == 2)
    }

    /// The peer's receipt can reach this phone before the answer to its send: it is kept and applied (chosen; not in the
    /// spec).
    @Test func aReceiptBeforeTheAnswerIsApplied() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.receiptsBeforeAnswers = true
        let sent = try await msgs.send(id, text: "fast peer")
        #expect(msgs.messages(id).map(\.messageID) == [sent.messageID])
        #expect(msgs.messages(id).first?.delivered == true && msgs.pendingReceipts.isEmpty)
    }
}

// swiftlint:enable line_length
