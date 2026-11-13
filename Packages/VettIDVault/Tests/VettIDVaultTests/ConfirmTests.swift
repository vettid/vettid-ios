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

    private func message(_ id: String = Ulid.new(), at: Date = Date()) -> Inner {
        Inner(id: id, type: "message.new", ts: at, body: Array(#"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"x"}"#.utf8))
    }

    /// A paired device that answered the vault's rekey and got its `hs.fin`; the confirmation and `device.features` are taken.
    /// [up]: the monotonic clock, for a test whose days really pass (the vault's time moves with it); nil: the real one.
    private func rekeyed(_ clock: Box<Date>, up: Box<TimeInterval>? = nil) async throws -> Rekeyed {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        var uptime: (@Sendable () -> TimeInterval)?
        if let up { uptime = { up.value } }
        let (d, v) = try await pairedDevice(store: store, secrets: secrets, cfg: config(store, now: { clock.value }, uptime: uptime))
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
        // At +30 s, still nothing; after the minute, again.
        clock.value = clock.value.addingTimeInterval(30)
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        #expect(await relay.noDeposit(within: 0.3))
        clock.value = clock.value.addingTimeInterval(31)
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

    @Test func noSecondConfirmWhileOneIsStillInTheOutbox() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        relay.refuseDeposits = "unavailable" // retryable: the entry stays
        relay.refuseStatus = 503
        let confirms = { r.device.mem.withLock { r.device.st.outbox.filter { $0.type == "hs.confirm" }.count } }
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        #expect(confirms() == 1)
        clock.value = clock.value.addingTimeInterval(61)
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        #expect(confirms() == 1)
    }

    /// §6.3.1 "Responder": the activation and its `hs.confirm` are in the same write.
    @Test func theActivationAndItsConfirmationAreSavedTogether() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let old = try #require(v.keyring.current())
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        relay.refuseDeposits = "unavailable"
        relay.refuseStatus = 503
        try await d.handle(v.msg(res.fin))
        let saved = try savedState(store)
        #expect(saved.vault?.confirmed == old.ctx && saved.vault?.awaiting.isEmpty == true)
        #expect(saved.outbox.map(\.type) == ["hs.confirm", "device.features"])
        #expect(saved.vault?.confirmAtMs != nil)
    }

    /// A refusal for good (`token_revoked`) takes the entry out; the next is due a minute later, not 12 days later, and
    /// not at once. A retryable refusal or `quota_exceeded` keeps its time (the entry stays, or goes 12 days on).
    @Test func aConfirmationRefusedForGoodIsDueAgainAMinuteLater() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        relay.refuseDeposits = RelayError.tokenRevoked
        clock.value = clock.value.addingTimeInterval(12 * 86_400 + 60)
        await r.device.tickConfirm()
        #expect(relay.refused == 1)
        #expect(try savedState(r.store).outbox.isEmpty)
        // Not again at once (every message would retry it), but a minute later.
        await r.device.tickConfirm()
        clock.value = clock.value.addingTimeInterval(30)
        await r.device.tickConfirm()
        #expect(relay.refused == 1)
        clock.value = clock.value.addingTimeInterval(31)
        await r.device.tickConfirm()
        #expect(relay.refused == 2)
    }

    @Test func aRetryableRefusalOrAFullQuotaKeepsTheTime() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        clock.value = clock.value.addingTimeInterval(12 * 86_400 + 60)
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseStatus = 429
        await r.device.tickConfirm()
        let at = try #require(try savedState(r.store).vault?.confirmAtMs)
        #expect(at == VaultDevice.ms(clock.value))
        clock.value = clock.value.addingTimeInterval(120)
        await r.device.tickConfirm()
        #expect(try savedState(r.store).vault?.confirmAtMs == at)
    }

    @Test func aDroppedPairingForgetsTheConfirmedEpoch() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        r.device.dropPairing()
        #expect(r.device.mem.withLock { r.device.st.vault?.confirmed == nil && r.device.st.vault?.confirmAtMs == nil })
    }

    /// (0.88.1) The 12-day re-send when collecting starts (every return to the foreground).
    @Test func aCollectionStartAfterTwelveDaysConfirmsAgain() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        relay.serveMailbox = true
        clock.value = clock.value.addingTimeInterval(12 * 86_400 + 60)
        r.device.start()
        defer { r.device.stop() }
        #expect(try await take(r.new).type == "hs.confirm")
    }

    /// (0.88.1) The 12-day re-send after a handled message that neither confirms nor brings a confirmation: one under a
    /// third, retired epoch.
    @Test func aMessageAfterTwelveDaysConfirmsAgain() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        // A second rekey under the confirmed epoch: the unconfirmed one (r.new) is retired, the old stays confirmed.
        let ini = try r.vault.rekey(r.device)
        try await r.device.handle(r.vault.msg(ini.envelope))
        #expect(try await take(r.new).type == "hs.confirm")
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: r.device.relayAddr.pk, now: Date())
        try await r.device.handle(r.vault.msg(res.fin))
        #expect(try await take(res.epoch).type == "hs.confirm")
        #expect(try await take(res.epoch).type == "device.features")
        clock.value = clock.value.addingTimeInterval(12 * 86_400 + 60)
        try await r.device.handle(r.vault.msg(try r.new.seal(message(at: clock.value))))
        #expect(try await take(res.epoch).type == "hs.confirm")
    }

    /// A redelivered `hs.fin` (a new msg_id, the same inner) opens under the new epoch and confirms nothing: only a message
    /// other than `hs.fin` does (§6.3.1 "Responder").
    @Test func aRedeliveredFinConfirmsNothing() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let old = try #require(v.keyring.current())
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        try await d.handle(v.msg(res.fin))
        #expect(try await take(res.epoch).type == "hs.confirm")
        #expect(try await take(res.epoch).type == "device.features")
        try await d.handle(v.msg(res.fin))
        #expect(try savedState(store).vault?.confirmed == old.ctx)
    }

    /// A save that fails after the activation: the activation stands in memory, so its hs.confirm and device.features are
    /// kept and still go out, and the time of the confirmation stays.
    @Test func aFailedSaveAfterTheActivationKeepsItsConfirmation() async throws {
        let store = FlakyStore()
        let (d, v) = try await pairedDevice(store: store)
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        store.arm()
        await #expect(throws: (any Error).self) { try await d.handle(v.msg(res.fin)) }
        #expect(d.mem.withLock { d.keyring.current()?.id } == res.epoch.id)
        #expect(d.mem.withLock { d.st.vault?.confirmAtMs } != nil)
        #expect(try await take(res.epoch).type == "hs.confirm")
        #expect(try await take(res.epoch).type == "device.features")
        store.disarm()
    }

    /// The kept epoch's 48 days (§6.3.1 table): on day 47 a message under it still brings hs.confirm; on day 49 it no
    /// longer opens. The days really pass (the monotonic clock moves too): a wall clock alone moving on does not hide it
    /// while the vault's time still keeps it (``VaultDevice/pruneTimeLocked(_:)``).
    @Test func theConfirmedEpochKeepsItsKeysFortyEightDays() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let r = try await rekeyed(clock, up: up)
        clock.value = clock.value.addingTimeInterval(47 * 86_400)
        up.value += 47 * 86_400
        try await r.device.handle(r.vault.msg(try r.old.seal(message(at: clock.value))))
        #expect(try await take(r.new).type == "hs.confirm")
        _ = relay.dropDeposits() // the standing token's renewal, due by now (§7.2)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        up.value += 2 * 86_400
        try await r.device.handle(r.vault.msg(try r.old.seal(message(at: clock.value))))
        #expect(await relay.noDeposit(within: 0.5))
    }

    /// Every sealed message carries the inner `features`, a request sent once included (§10.8 "On every message").
    @Test func aRequestSentOnceCarriesTheFeatures() async throws {
        let (d, v) = try await pairedDevice()
        let op = Task { try await d.opOnce("vault.status") }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(req.type == "vault.status" && req.features == ["hs_confirm"])
        try await d.handle(try v.seal("vault.status", "{}", re: req.id, status: Inner.statusOK))
        _ = try await op.value
    }

    /// An hs.confirm not yet deposited is still in the outbox after a restart (an outbox type), and goes at the next flush.
    @Test func anUndeliveredConfirmationSurvivesARestart() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        relay.refuseDeposits = "unavailable"
        relay.refuseStatus = 503
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        r.device.stop()
        let again = try #require(try VaultDevice.load(config(r.store, now: { clock.value }), secrets: r.secrets))
        #expect(again.mem.withLock { again.st.outbox.map(\.type) } == ["hs.confirm"])
        relay.refuseDeposits = nil
        _ = relay.dropDeposits()
        await again.flushOutbox()
        #expect(try await take(r.new).type == "hs.confirm")
    }

    /// A new pairing's hs.resp starts with its own epoch confirmed: a confirmed epoch and time left from before are cleared
    /// (as dropPairing does).
    @Test func aNewPairingClearsTheConfirmedEpoch() async throws {
        let d = try await VaultDevice.create(config(InMemoryDeviceStateStore()), secrets: try DeviceSecrets.generate())
        let v = try FakeVault(relayURL: relay.baseURL)
        try await d.handle(try v.enrolled(d))
        try await d.awaitEnrolled(timeout: 1)
        d.mem.withLock {
            d.st.vault?.confirmed = Base64s.encodeStd([UInt8](repeating: 7, count: Suite.epochIDSize))
            d.st.vault?.confirmAtMs = 5
        }
        let paired = Task { try await d.completeEnrollment(timeout: 10) }
        let (_, initMsg) = try await relay.nextDeposit()
        try await d.handle(try v.respond(initMsg, d))
        #expect(d.mem.withLock { d.st.vault?.confirmed == nil && d.st.vault?.confirmAtMs == nil })
        try v.fin(try await relay.nextDeposit().payload, d)
        try await d.handle(try v.seal("device.paired", #"{"device_id":"dev-1","role":"app","vault_id":"\#(v.vaultID)"}"#))
        try await paired.value
    }

    /// A refusal for good met by the outbox flush (``flushOutbox()``) sets the same floor: due again a minute later.
    @Test func aRefusalForGoodDuringAFlushSetsTheFloor() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        relay.refuseDeposits = "unavailable" // the confirmation a message brings stays in the outbox
        relay.refuseStatus = 503
        try await r.device.handle(r.vault.msg(try r.old.seal(message())))
        #expect(r.device.mem.withLock { r.device.st.outbox.map(\.type) } == ["hs.confirm"])
        relay.refuseDeposits = RelayError.tokenRevoked
        relay.refuseStatus = 403
        await r.device.flushOutbox()
        #expect(try savedState(r.store).outbox.isEmpty)
        let floor = VaultDevice.ms(clock.value) - Int64((VaultDevice.confirmResend - VaultDevice.reconfirmEvery) * 1000)
        #expect(try savedState(r.store).vault?.confirmAtMs == floor)
    }

    @Test func anHsConfirmFromTheVaultIsIgnored() async throws {
        let (d, v) = try await pairedDevice()
        try await d.handle(try v.seal("hs.confirm", "{}"))
        await #expect(throws: VaultStateError.self) { _ = try await d.awaitEvent("hs.confirm", timeout: 0.2) }
    }

    /// The 12-day `hs.confirm` of a collection's start keeps the stop mark of that start: after a stop since, it is queued,
    /// not deposited.
    @Test func theTwelveDayConfirmOfAStartStoppedSinceIsNotDeposited() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        let mark = r.device.stopMark
        r.device.stop()
        clock.value = clock.value.addingTimeInterval(12 * 86_400 + 60)
        await r.device.tickConfirm(since: mark)
        #expect(r.device.mem.withLock { r.device.st.outbox.map(\.type) } == ["hs.confirm"])
        #expect(await relay.noDeposit(within: 0.2))
    }

    /// A queued `hs.confirm` held at its deposit (the lock went pending after the first ask) reports held, and one asked for
    /// before a stop is not deposited after it.
    @Test func aConfirmHeldAtItsDepositReportsHeldAndHonoursTheStopMark() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        let asks = Box(0)
        r.device.setFlushGate {
            asks.value += 1
            return asks.value == 1
        }
        clock.value = clock.value.addingTimeInterval(12 * 86_400 + 60)
        let e = try #require(await r.device.lock.withLock { r.device.tickConfirmLocked(r.device.now(), save: true) })
        #expect(try await r.device.deliverQueued(e) == false)
        #expect(r.device.mem.withLock { r.device.st.outbox.map(\.type) == ["hs.confirm"] && r.device.outboxInFlight.isEmpty })
        r.device.setFlushGate { true }
        let mark = r.device.stopMark
        r.device.stop()
        #expect(await r.device.deliverConfirm(e, since: mark) == false)
        #expect(await relay.noDeposit(within: 0.2))
    }

    /// The 12-day `hs.confirm` of a collection's start asks the lock gate: while a lock is pending it is queued, not
    /// deposited; the next flush the gate admits sends it.
    @Test func theTwelveDayConfirmWaitsForTheLockGate() async throws {
        let clock = Box(Date())
        let r = try await rekeyed(clock)
        let open = Box(false)
        r.device.setFlushGate { open.value }
        clock.value = clock.value.addingTimeInterval(12 * 86_400 + 60)
        await r.device.tickConfirm()
        #expect(r.device.mem.withLock { r.device.st.outbox.map(\.type) } == ["hs.confirm"])
        #expect(await relay.noDeposit(within: 0.2))
        open.value = true
        await r.device.flushOutbox()
        #expect(try await take(r.new).type == "hs.confirm")
    }
}

// swiftlint:enable line_length
