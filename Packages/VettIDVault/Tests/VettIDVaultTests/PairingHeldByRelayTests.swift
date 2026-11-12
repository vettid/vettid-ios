import Foundation
import Testing
@testable import VettIDVault
import VettIDAltChan
import VettIDAltChanTesting
import VettIDCrypto
import VettIDRelay

/// (chosen; not in the spec) Whether this phone's pairing `hs.fin` is held by a relay quota (VAULT-MESSAGING 0.88.8 §8.6): the
/// transfer's comparison code is shown meanwhile, and the vault has not got the fin.
extension InitDepositTests {
    /// A phone whose uptime the test moves, and a transfer started up to the vault's `hs.init` that is ready to answer.
    private func transferringPhone() async throws -> Transferring {
        let up = Box(1_000.0)
        let secrets = DeviceSecrets(
            identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate(),
            apiKey: [UInt8](repeating: 0x30, count: 91)
        )
        let d = try await VaultDevice.create(base.config(InMemoryDeviceStateStore(), uptime: { up.value }), secrets: secrets)
        let v = try FakeVault(relayURL: base.relay.baseURL)
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        return Transferring(d: d, v: v, up: up, initMsg: initMsg, inviteID: inviteID)
    }

    private struct Transferring {
        let d: VaultDevice
        let v: FakeVault
        let up: Box<TimeInterval>
        let initMsg: [UInt8]
        let inviteID: String
    }

    /// The updates of a device, read one at a time; nil when none comes soon.
    private final class Updates: @unchecked Sendable {
        private var iterator: AsyncStream<Bool>.Iterator
        init(_ d: VaultDevice) { iterator = d.pairingHeldUpdates().makeAsyncIterator() }
        func next() async -> Bool? {
            await withTaskGroup(of: Bool?.self) { group in
                group.addTask { await self.iterator.next() }
                group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
    }

    /// The relay answers the fin's deposit with `quota_exceeded`: held, and told; the deposit the relay takes later clears it.
    @Test func aFinRefusedForAQuotaIsHeldUntilItIsDeposited() async throws {
        let td = try await transferringPhone()
        let (d, v, initMsg, inviteID) = (td.d, td.v, td.initMsg, td.inviteID)
        let updates = Updates(d)
        #expect(await updates.next() == false, "the current value first")
        base.relay.refuseStatus = 429
        base.relay.refuseDeposits = RelayError.quotaExceeded
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.pairingHeldByRelay)
        #expect(await updates.next() == true)
        // The relay takes it after the backoff.
        base.relay.refuseDeposits = nil
        td.up.value += 61
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
        #expect(!d.pairingHeldByRelay)
        #expect(await updates.next() == false)
    }

    /// A fin that waits for a quota before any deposit (the mailbox's backoff runs) is held too.
    @Test func aFinWaitingForAQuotaIsHeld() async throws {
        let td = try await transferringPhone()
        let (d, v, initMsg, inviteID) = (td.d, td.v, td.initMsg, td.inviteID)
        let mailbox = try #require(d.mem.withLock { d.st.vault?.mailbox })
        d.mem.withLock { d.quotaBackoff[mailbox] = (td.up.value + 60, 60) }
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["hs.fin"])
        #expect(d.pairingHeldByRelay)
    }

    /// A fin that failed in transport, or that the relay refused for good, is not held by a quota.
    @Test func aFinThatFailsOtherwiseIsNotHeld() async throws {
        let td = try await transferringPhone()
        let (d, v, initMsg, inviteID) = (td.d, td.v, td.initMsg, td.inviteID)
        base.relay.failDeposits = .notConnectedToInternet
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["hs.fin"], "still owed")
        #expect(!d.pairingHeldByRelay)

        base.relay.failDeposits = nil
        let te = try await transferringPhone()
        let (e, w, initMsg2, inviteID2) = (te.d, te.v, te.initMsg, te.inviteID)
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenRevoked
        try await e.handle(try w.respondOpening(initMsg2, e, ctx: inviteID2).message)
        #expect(!e.pairingHeldByRelay)
    }

    /// A held fin dropped at its time (a flush) or by the handshake's end ends the hold, on the stream too.
    @Test func aHeldFinDroppedAtItsTimeEndsTheHold() async throws {
        let td = try await transferringPhone()
        let (d, v, initMsg, inviteID) = (td.d, td.v, td.initMsg, td.inviteID)
        let updates = Updates(d)
        _ = await updates.next()
        base.relay.refuseStatus = 429
        base.relay.refuseDeposits = RelayError.quotaExceeded
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(await updates.next() == true)
        d.mem.withLock { d.st.outbox[0].dropAfterMs = 1 }
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
        #expect(await updates.next() == false)
    }

    /// The held fin's refusal for good, and a new handshake or a dropped pairing, end the hold.
    @Test func theHoldEndsWithTheFin() async throws {
        let td = try await transferringPhone()
        let (d, v, initMsg, inviteID) = (td.d, td.v, td.initMsg, td.inviteID)
        let updates = Updates(d)
        _ = await updates.next()
        base.relay.refuseStatus = 429
        base.relay.refuseDeposits = RelayError.quotaExceeded
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(await updates.next() == true)
        d.dropPairing()
        #expect(!d.pairingHeldByRelay)
        #expect(await updates.next() == false)

        // Refused for good at a later flush.
        base.relay.refuseDeposits = nil
        let te = try await transferringPhone()
        let (e, w, initMsg2, inviteID2) = (te.d, te.v, te.initMsg, te.inviteID)
        let updates2 = Updates(e)
        _ = await updates2.next()
        base.relay.refuseStatus = 429
        base.relay.refuseDeposits = RelayError.quotaExceeded
        try await e.handle(try w.respondOpening(initMsg2, e, ctx: inviteID2).message)
        #expect(e.pairingHeldByRelay)
        #expect(await updates2.next() == true)
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenRevoked
        te.up.value += 61
        await e.flushOutbox()
        #expect(e.mem.withLock { e.st.outbox.isEmpty })
        #expect(!e.pairingHeldByRelay)
        #expect(await updates2.next() == false)
    }
}
