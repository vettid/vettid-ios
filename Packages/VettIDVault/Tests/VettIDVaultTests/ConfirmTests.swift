import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// Activation on confirmation, the device's responder half (VAULT-MESSAGING 0.87.0–0.88.1, §6.3.1 "Responder",
/// "Devices and agents"). The fake vault stays on its old epoch after a rekey, as a release-29 vault keeps its pending
/// epoch until `hs.confirm` arrives; the device's deposits are opened with the rekey's epoch. Mirrors vettid-vault
/// `client/reconfirm_test.go` and `vault/r29_device_test.go`.
extension VaultDeviceTests {
    private struct Rekeyed {
        let device: VaultDevice
        let vault: FakeVault
        let old: Epoch
        let new: Epoch
        let store: InMemoryDeviceStateStore
        let secrets: DeviceSecrets
    }

    private func message(_ id: String = Ulid.new()) -> Inner {
        Inner(id: id, type: "message.new", ts: Date(), body: Array(#"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"x"}"#.utf8))
    }

    /// A paired device that answered the vault's rekey and got its `hs.fin`; the confirmation and `device.features` are taken.
    private func rekeyed(_ clock: Box<Date>) async throws -> Rekeyed {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets, cfg: config(store, now: { clock.value }))
        let old = try #require(v.keyring.current())
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        #expect(res.inner.features == ["hs_confirm"]) // hs.resp carries the list too
        try await d.handle(v.msg(res.fin))
        #expect(try await take(res.epoch).type == "hs.confirm")
        #expect(try await take(res.epoch).type == "device.features")
        return Rekeyed(device: d, vault: v, old: old, new: res.epoch, store: store, secrets: secrets)
    }

    private func take(_ e: Epoch) async throws -> Inner { try e.open(try Envelope.parse(try await relay.nextDeposit().payload)) }

    @Test func theOldEpochStaysConfirmedAndAMessageUnderItConfirmsAgainOnceAMinute() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        #expect(try savedState(r.store).vault?.confirmed == r.old.ctx)
        #expect(try savedState(r.store).vault?.confirmAtMs != nil)
        // The vault, still on its old epoch, sends under it: hs.confirm again, under the new epoch.
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        let again = try await take(r.new)
        #expect(again.type == "hs.confirm" && String(bytes: again.body, encoding: .utf8) == "{}")
        // Within the minute, nothing more.
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        #expect(await relay.noDeposit(within: 0.5))
        // After it, again.
        clock.value = clock.value.addingTimeInterval(61)
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        #expect(try await take(r.new).type == "hs.confirm")
    }

    @Test func aMessageUnderTheNewEpochConfirmsItAndEndsTheOld() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        try await r.device.handle(r.vault.msg(try r.new.seal(message())))
        #expect(try savedState(r.store).vault?.confirmed == nil)
        // The old epoch keeps its receive key (16 days) but not its rk: a message under it brings no confirmation, and a
        // rekey under it is not answered.
        clock.value = clock.value.addingTimeInterval(120)
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        try await r.device.handle(r.vault.msg(try r.vault.rekey(r.device).envelope))
        #expect(await relay.noDeposit(within: 0.5))
        // Released: its rk is gone and its receive key ends 16 days on, not 48 (§6.3.1 table).
        let found = { (t: Date) in r.device.mem.withLock { r.device.keyring.find(r.old.id, now: t) } }
        #expect(found(clock.value)?.hasRK == false)
        #expect(found(clock.value.addingTimeInterval(17 * 86_400)) == nil)
    }

    @Test func aRekeyUnderTheConfirmedEpochIsAnsweredAsIfCurrent() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        // The vault never got hs.confirm and rekeys again from its old epoch.
        let ini = try r.vault.rekey(r.device)
        try await r.device.handle(r.vault.msg(ini.envelope))
        // The hs.init under the confirmed epoch brings hs.confirm again, then the answer.
        #expect(try await take(r.new).type == "hs.confirm")
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: r.device.relayAddr.pk, now: Date())
        try await r.device.handle(r.vault.msg(res.fin))
        #expect(try await take(res.epoch).type == "hs.confirm")
        #expect(try await take(res.epoch).type == "device.features")
        // The confirmed epoch is still the old one: the unconfirmed one was retired, not kept.
        #expect(try savedState(r.store).vault?.confirmed == r.old.ctx)
        try await r.device.handle(r.vault.msg(try res.epoch.seal(message())))
        #expect(try savedState(r.store).vault?.confirmed == nil)
    }

    @Test func hsConfirmGoesAgainTwelveDaysAfterTheLastWhileUnconfirmed() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        let outboxConfirms = { r.device.mem.withLock { r.device.st.outbox.filter { $0.type == "hs.confirm" }.count } }
        relay.refuseDeposits = "unavailable" // kept in the outbox, so it can be counted
        relay.refuseStatus = 503
        clock.value = clock.value.addingTimeInterval(12 * 86_400 - 60)
        await r.device.tickConfirm()
        #expect(outboxConfirms() == 0)
        clock.value = clock.value.addingTimeInterval(120)
        await r.device.tickConfirm()
        #expect(outboxConfirms() == 1)
        #expect(try savedState(r.store).outbox.contains { $0.type == "hs.confirm" })
        // Not a second while one is still in the outbox.
        clock.value = clock.value.addingTimeInterval(13 * 86_400)
        await r.device.tickConfirm()
        #expect(outboxConfirms() == 1)
        // Once confirmed, none.
        relay.refuseDeposits = nil
        await r.device.flushOutbox()
        try await r.device.handle(r.vault.msg(try r.new.seal(message())))
        clock.value = clock.value.addingTimeInterval(30 * 86_400)
        await r.device.tickConfirm()
        #expect(outboxConfirms() == 0)
    }

    @Test func theConfirmedEpochSurvivesARestart() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        r.device.stop()
        let again = try #require(try VaultDevice.load(config(r.store, now: { clock.value }), secrets: r.secrets))
        // Day 20: past the 16 days a plain retirement keeps, within the confirmed epoch's 48.
        clock.value = clock.value.addingTimeInterval(20 * 86_400)
        try await again.handle(r.vault.msg(try r.old.seal(message())))
        #expect(try await take(r.new).type == "hs.confirm")
    }

    @Test func anHsConfirmFromTheVaultIsIgnored() async throws {
        let (d, v) = try await pairedDevice()
        try await d.handle(try v.seal("hs.confirm", "{}"))
        await #expect(throws: VaultStateError.self) { _ = try await d.awaitEvent("hs.confirm", timeout: 0.2) }
    }
}

// swiftlint:enable line_length
