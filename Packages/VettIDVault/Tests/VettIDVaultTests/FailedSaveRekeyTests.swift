import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// A save that fails after a rekey's activation (VAULT-MESSAGING §6.3.1 "Responder", §6.5; RELAY-PROTOCOL §6.3): the failed
/// handling is not acked, so the relay delivers the `hs.fin` again; after a restart the disk still holds the awaiting
/// responder and the old current epoch, and the redelivery activates the same epoch; without a restart the activation
/// stands, and the redelivery confirms nothing new.
extension VaultDeviceTests {
    private struct FailedFin {
        let device: VaultDevice
        let vault: FakeVault
        let store: FlakyStore
        let secrets: DeviceSecrets
        let old: Epoch
        let new: Epoch
        /// The vault's `hs.fin`, as the relay delivers it (the same msg_id each time).
        let fin: RelayMessage
    }

    private func take(_ e: Epoch) async throws -> Inner { try e.open(try Envelope.parse(try await relay.nextDeposit().payload)) }

    /// A paired device that answered the vault's rekey; the vault's `hs.fin` is ready.
    private func readyToFail() async throws -> FailedFin {
        let store = FlakyStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        let old = try #require(v.keyring.current())
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        return FailedFin(device: d, vault: v, store: store, secrets: secrets, old: old, new: res.epoch, fin: v.msg(res.fin))
    }

    private func outbox(_ d: VaultDevice, _ type: String) -> Int { d.mem.withLock { d.st.outbox.filter { $0.type == type }.count } }

    private func newMessage() -> Inner {
        Inner(id: Ulid.new(), type: "message.new", ts: Date(), body: Array(#"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"x"}"#.utf8))
    }

    /// The collector acks a message only after the handler returned (``MailboxCollector``): a handler that throws (the save
    /// failed) ends the round with that error, and the `hs.fin` is not acked, so the relay keeps it.
    @Test func aSaveFailingAfterTheActivationLeavesTheFinUnacked() async throws {
        let f = try await readyToFail()
        relay.serveMailbox = true
        relay.queue(f.fin)
        f.store.arm()
        await #expect(throws: (any Error).self) { _ = try await f.device.pollOnce() }
        #expect(f.device.mem.withLock { f.device.keyring.current()?.id } == f.new.id) // the activation stands in memory
        #expect(await relay.waitAcked(f.fin.msgID, timeout: 0.5) == false)
        // The kept entries are still deposited.
        #expect(try await take(f.new).type == "hs.confirm")
        #expect(try await take(f.new).type == "device.features")
        // Control: the same message handled with a store that works is acked.
        f.store.disarm()
        relay.queue(f.fin)
        #expect(try await f.device.pollOnce() == 1)
        #expect(await relay.waitAcked(f.fin.msgID))
    }

    /// After a restart the disk holds the state before the `hs.fin`: the awaiting responder and the old current epoch. The
    /// redelivered `hs.fin` (the same msg_id) activates the new epoch the vault confirmed, and the device reads it.
    @Test func aRestartActivatesTheSameEpochAtTheRedeliveredFin() async throws {
        let f = try await readyToFail()
        f.store.arm()
        await #expect(throws: (any Error).self) { try await f.device.handle(f.fin) }
        #expect(try await take(f.new).type == "hs.confirm")
        #expect(try await take(f.new).type == "device.features")
        f.device.stop()
        f.store.disarm()
        // The disk, as it was: the responder awaits, the old epoch is current, nothing is confirmed yet.
        let disk = try #require(f.store.state)
        #expect(disk.vault?.awaiting.count == 1)
        #expect(disk.vault?.confirmed == nil)
        let again = try #require(try VaultDevice.load(config(f.store), secrets: f.secrets))
        #expect(again.mem.withLock { again.keyring.current()?.id } == f.old.id)
        try await again.handle(f.fin)
        #expect(again.mem.withLock { again.keyring.current()?.id } == f.new.id)
        #expect(again.mem.withLock { again.st.vault?.confirmed } == f.old.ctx)
        #expect(again.mem.withLock { again.awaiting.isEmpty })
        // The confirmation of the redelivery is under the epoch the vault already confirmed.
        #expect(try await take(f.new).type == "hs.confirm")
        #expect(try await take(f.new).type == "device.features")
        // A message the vault seals under the new epoch opens.
        let env = try f.new.seal(newMessage())
        #expect(again.mem.withLock { try? again.keyring.open(try Envelope.parse(env), now: Date()) } != nil)
        try await again.handle(f.vault.msg(env))
        #expect(again.mem.withLock { again.st.vault?.confirmed } == nil) // a message under the current epoch confirms it
    }

    /// Without a restart the activation stands in memory: the redelivered `hs.fin` opens under the current epoch, activates
    /// nothing again, queues no second `hs.confirm`, and the state stays consistent.
    @Test func withoutARestartTheRedeliveredFinConfirmsNothingNew() async throws {
        let f = try await readyToFail()
        f.store.arm()
        await #expect(throws: (any Error).self) { try await f.device.handle(f.fin) }
        #expect(try await take(f.new).type == "hs.confirm")
        #expect(try await take(f.new).type == "device.features")
        f.store.disarm()
        let d = f.device
        let confirmAt = d.mem.withLock { d.st.vault?.confirmAtMs }
        try await d.handle(f.fin)
        #expect(await relay.noDeposit(within: 0.5))
        #expect(d.mem.withLock { d.keyring.current()?.id } == f.new.id)
        #expect(d.mem.withLock { d.st.vault?.confirmed } == f.old.ctx)
        #expect(d.mem.withLock { d.st.vault?.confirmAtMs } == confirmAt)
        #expect(d.mem.withLock { d.awaiting.isEmpty })
        #expect(outbox(d, "hs.confirm") <= 1 && outbox(d, "device.features") <= 1)
        // The redelivery's save succeeded: the disk now holds the activation, and a restart from it agrees.
        let disk = try #require(f.store.state)
        #expect(disk.vault?.confirmed == f.old.ctx && disk.vault?.awaiting.isEmpty == true)
        d.stop()
        let again = try #require(try VaultDevice.load(config(f.store), secrets: f.secrets))
        #expect(again.mem.withLock { again.keyring.current()?.id } == f.new.id)
    }
}

// swiftlint:enable line_length
