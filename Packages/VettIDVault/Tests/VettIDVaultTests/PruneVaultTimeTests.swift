import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// A phone clock set far ahead destroys no kept epoch (as vettid-android #350): retained epochs are destroyed, at each
/// activation, by the earlier of this phone's time and the vault's plus five minutes; nothing is destroyed before the vault has
/// shown its time in this process; envelopes are opened against the same time; and a message under an epoch only this phone's
/// clock hides is left for redelivery. The fake vault stays on its old epoch after a rekey, as in ``ConfirmTests``, so the old
/// epoch is the kept confirmed one (48 days).
extension VaultDeviceTests {
    private struct Kept {
        let device: VaultDevice
        let vault: FakeVault
        let old: Epoch
        let new: Epoch
        let store: InMemoryDeviceStateStore
        let secrets: DeviceSecrets
    }

    private static let day: TimeInterval = 86_400

    private func note(_ text: String = "hi", at: Date = Date()) -> Inner {
        Inner(id: Ulid.new(), type: "message.new", ts: at, body: Array(#"{"connection_id":"c1","message_id":"\#(Ulid.new())","direction":"in","text":"\#(text)","sent_at":"x"}"#.utf8))
    }

    /// A paired device that answered the vault's rekey and got its `hs.fin`, on [clock] and [up].
    private func kept(_ clock: Box<Date>, _ up: Box<TimeInterval>) async throws -> Kept {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets, cfg: config(store, now: { clock.value }, uptime: { up.value }))
        let old = try #require(v.keyring.current())
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        try await d.handle(v.msg(res.fin))
        relay.dropDeposits() // hs.confirm, device.features
        return Kept(device: d, vault: v, old: old, new: res.epoch, store: store, secrets: secrets)
    }

    private func restarted(_ k: Kept, _ clock: Box<Date>, _ up: Box<TimeInterval>) throws -> Kept {
        k.device.stop()
        let d = try #require(try VaultDevice.load(config(k.store, now: { clock.value }, uptime: { up.value }), secrets: k.secrets))
        return Kept(device: d, vault: k.vault, old: k.old, new: k.new, store: k.store, secrets: k.secrets)
    }

    /// Whether the device still holds [e]'s receive key (hidden or not), as opposed to having destroyed it.
    private func holds(_ d: VaultDevice, _ e: Epoch) -> Bool {
        d.mem.withLock { d.keyring.find(e.id, now: .distantPast) != nil }
    }

    /// The vault's rekey under [under], stamped [at], answered; then the phone's wall clock moves by [jump] before its `hs.fin`
    /// arrives and is activated (a point where retained epochs past their life are destroyed).
    private func rekeyAcross(_ k: Kept, under: Epoch, at: Date, jump: TimeInterval, clock: Box<Date>) async throws {
        let ini = try k.vault.rekey(k.device, under: under, at: at)
        try await k.device.handle(k.vault.msg(ini.envelope))
        // Under the kept epoch, the hs.init also brings hs.confirm again (a session message): the hs.resp is the other deposit.
        var resp = try await relay.nextDeposit().payload
        while try Envelope.parse(resp).mode == .session { resp = try await relay.nextDeposit().payload }
        let res = try ini.handleResp(resp, collectSender: k.device.relayAddr.pk, now: at)
        clock.value = clock.value.addingTimeInterval(jump) // the wall clock only
        try await k.device.handle(k.vault.msg(res.fin))
        relay.dropDeposits()
    }

    /// 40 days really pass, the vault rekeys under the kept confirmed epoch with the clocks in step, then the phone's clock
    /// jumps 10 days before `hs.fin`: the activation destroys nothing the vault's time still keeps (48 days), and once the
    /// clock is back a message under the kept epoch opens.
    @Test func anActivationWithTheClockJumpedAheadDestroysNoKeptEpoch() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        clock.value = clock.value.addingTimeInterval(40 * Self.day)
        up.value += 40 * Self.day
        try await rekeyAcross(k, under: k.old, at: clock.value, jump: 10 * Self.day, clock: clock)
        #expect(holds(k.device, k.old), "not destroyed by a clock ahead")
        clock.value = clock.value.addingTimeInterval(-10 * Self.day)
        try await k.device.handle(k.vault.msg(try k.old.seal(note("back", at: clock.value))))
        #expect(VaultJSON.string(try await k.device.awaitEvent("message.new", timeout: 2).object, "text") == "back")
    }

    /// 40 days really pass and the phone's clock reads 50: a message under the kept epoch (48 days by the phone's count),
    /// stamped by the vault's clock, opens: it is not hidden by the clock alone.
    @Test func aMessageUnderTheKeptEpochOpensWhileTheClockIsAhead() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        let vaultAt = clock.value.addingTimeInterval(40 * Self.day)
        up.value += 40 * Self.day
        clock.value = clock.value.addingTimeInterval(50 * Self.day)
        try await k.device.handle(k.vault.msg(try k.old.seal(note("day 40", at: vaultAt))))
        #expect(VaultJSON.string(try await k.device.awaitEvent("message.new", timeout: 2).object, "text") == "day 40")
        #expect(holds(k.device, k.old))
    }

    /// After a restart the vault's time is not known yet: a message under the kept epoch that only the phone's clock (past the
    /// epoch's life) hides is left unacked, never dropped, and opens once the clock is back.
    @Test func aMessageUnderAHiddenEpochIsLeftForRedelivery() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        clock.value = clock.value.addingTimeInterval(50 * Self.day)
        let r = try restarted(k, clock, up)
        let m = r.vault.msg(try r.old.seal(note("hidden")))
        await #expect(throws: LeaveUnacked.self) { try await r.device.handle(m) }
        #expect(try savedState(r.store).seen[m.msgID] == nil, "not taken as handled")
        clock.value = Date()
        try await r.device.handle(m) // the relay's redelivery
        #expect(VaultJSON.string(try await r.device.awaitEvent("message.new", timeout: 2).object, "text") == "hidden")
    }

    /// The kept epoch's life counts from the vault's time: once the vault's time is past its 48 days, an activation destroys it.
    @Test func theKeptEpochIsDestroyedOnceTheVaultsTimeIsPastItsLife() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        clock.value = clock.value.addingTimeInterval(49 * Self.day)
        up.value += 49 * Self.day
        try await rekeyAcross(k, under: k.new, at: clock.value, jump: 0, clock: clock)
        #expect(!holds(k.device, k.old), "destroyed once the vault's time is past its 48 days")
    }

    /// A rekey's verified handshake shows the vault's time after a restart in which 49 days really passed (no other message from
    /// the vault): the kept epoch past its life goes at that rekey's activation; the settlement clock is unchanged.
    @Test func aRekeysHandshakeShowsTheVaultsTime() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        clock.value = clock.value.addingTimeInterval(49 * Self.day)
        let r = try restarted(k, clock, up)
        #expect(r.device.pruneTime(clock.value) == nil)
        let ini = try r.vault.rekey(r.device, under: r.new, at: clock.value)
        try await r.device.handle(r.vault.msg(ini.envelope))
        #expect(r.device.pruneTime(clock.value) != nil, "shown by the hs.init")
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: r.device.relayAddr.pk, now: clock.value)
        try await r.device.handle(r.vault.msg(res.fin))
        #expect(!holds(r.device, r.old), "destroyed at the rekey")
        #expect(!r.device.knowsVaultTime, "the settlement clock is unchanged")
    }

    /// A release counted from the latest of this phone's time, the vault's and the message's own: a clock 10 days behind
    /// does not shorten the released epoch's 16 days.
    @Test func aReleaseWithTheClockBehindKeepsItsSixteenDays() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        clock.value = clock.value.addingTimeInterval(-10 * Self.day)
        // A message under the new epoch confirms it and releases the old one; it is then dropped (in the future by this clock).
        try? await k.device.handle(k.vault.msg(try k.new.seal(note())))
        let open15 = k.device.mem.withLock { k.device.keyring.find(k.old.id, now: Date().addingTimeInterval(15 * Self.day)) != nil }
        #expect(open15, "kept 16 days from the vault's time, not 6")
    }

    /// The rekeys awaiting `hs.fin` are not dropped by age at a restart while the clock is ahead (the vault's time is not
    /// known then).
    @Test func aRestartWithTheClockAheadKeepsTheAwaitingRekey() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets, cfg: config(store, now: { clock.value }, uptime: { up.value }))
        try await d.handle(v.msg(try v.rekey(d).envelope))
        _ = try await relay.nextDeposit()
        d.stop()
        clock.value = clock.value.addingTimeInterval(17 * Self.day)
        let again = try #require(try VaultDevice.load(config(store, now: { clock.value }, uptime: { up.value }), secrets: secrets))
        #expect(again.mem.withLock { again.awaiting.count } == 1)
    }

    /// A clock jumped 20 days ahead aborts no responder awaiting its `hs.fin` (the `hs.fin` that arrives meanwhile, too old by the
    /// jumped clock, is dropped); once the clock is back the vault's `hs.fin` completes the rekey.
    @Test func aClockJumpAbortsNoAwaitingRekey() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store, cfg: config(store, now: { clock.value }, uptime: { up.value }))
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        clock.value = clock.value.addingTimeInterval(20 * Self.day)
        try? await d.handle(v.msg(res.fin))
        #expect(d.mem.withLock { d.awaiting.count } == 1, "not aborted by the clock")
        clock.value = Date()
        try await d.handle(v.msg(res.fin))
        v.keyring.activate(res.epoch, now: Date())
        try await expectConfirm(v, res.epoch)
    }

    /// A rekey's verified `hs.fin` shows the vault's time: the rekey comes a minute before the kept epoch's 48 days end, the
    /// phone restarts (the `hs.init`'s stamp is not kept), and its `hs.fin`, minutes later and past the 48 days, destroys the
    /// kept epoch at the activation.
    @Test func aRekeysFinShowsTheVaultsTime() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        clock.value = clock.value.addingTimeInterval(48 * Self.day - 60)
        up.value += 48 * Self.day - 60
        let at = clock.value
        let ini = try k.vault.rekey(k.device, under: k.new, at: at)
        try await k.device.handle(k.vault.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: k.device.relayAddr.pk, now: at)
        #expect(holds(k.device, k.old), "set-up: still kept before the 48 days end")
        clock.value = clock.value.addingTimeInterval(180)
        let r = try restarted(k, clock, up)
        try await r.device.handle(r.vault.msg(res.fin))
        #expect(!holds(r.device, r.old), "destroyed at the rekey's hs.fin")
    }

    /// A key's life counts from the vault's time at its activation: with the clock 10 days ahead at `hs.fin`, the kept
    /// confirmed epoch still goes once the vault's time passes its 48 days (not 58).
    @Test func theKeptEpochsLifeCountsFromTheVaultsTime() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store, cfg: config(store, now: { clock.value }, uptime: { up.value }))
        let old = try #require(v.keyring.current())
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        clock.value = clock.value.addingTimeInterval(10 * Self.day) // the wall clock only, before hs.fin
        try await d.handle(v.msg(res.fin))
        relay.dropDeposits()
        #expect(holds(d, old), "set-up: the confirmed epoch is kept")
        // 49 days really pass (the clock back in step), and the vault rekeys from the new epoch.
        clock.value = Date().addingTimeInterval(49 * Self.day)
        up.value += 49 * Self.day
        let k = Kept(device: d, vault: v, old: old, new: res.epoch, store: store, secrets: try DeviceSecrets.generate())
        try await rekeyAcross(k, under: res.epoch, at: clock.value, jump: 0, clock: clock)
        #expect(!holds(d, old), "gone at the vault's 48 days")
    }

    /// The keeping activation (the current epoch confirmed): the old epoch is released (16 days), 10 days really pass, the vault
    /// rekeys from the current epoch with the clocks in step, then the phone's clock jumps 8 days before `hs.fin`. The
    /// activation destroys nothing the vault's time still keeps.
    @Test func aKeepingActivationWithTheClockJumpedAheadDestroysNoReleasedEpoch() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        try await k.device.handle(k.vault.msg(try k.new.seal(note("confirms the new epoch"))))
        _ = try await k.device.awaitEvent("message.new", timeout: 2)
        clock.value = clock.value.addingTimeInterval(10 * Self.day)
        up.value += 10 * Self.day
        try await rekeyAcross(k, under: k.new, at: clock.value, jump: 8 * Self.day, clock: clock)
        #expect(holds(k.device, k.old), "the released epoch is not destroyed by a clock ahead")
    }

    /// A rekey whose `hs.fin` never comes ends at its 16 days by the vault's time: once 17 days really passed, the next handled
    /// message ends it.
    @Test func anAwaitingRekeyEndsByTheVaultsTime() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store, cfg: config(store, now: { clock.value }, uptime: { up.value }))
        try await d.handle(v.msg(try v.rekey(d).envelope))
        _ = try await relay.nextDeposit()
        #expect(d.mem.withLock { d.awaiting.count } == 1)
        clock.value = clock.value.addingTimeInterval(17 * Self.day)
        up.value += 17 * Self.day
        try await d.handle(try v.seal("message.new", #"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"x"}"#, ts: clock.value))
        #expect(d.mem.withLock { d.awaiting.isEmpty }, "ended by the vault's time")
        #expect(try savedState(store).vault?.awaiting.isEmpty == true)
    }

    /// After a restart with the clock 10 days behind, the first message (under the current epoch) releases the kept one before
    /// any vault time is known: its 16 days count from the message's own `ts`.
    @Test func aReleaseBeforeTheVaultsTimeIsKnownCountsFromTheMessage() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        clock.value = clock.value.addingTimeInterval(-10 * Self.day)
        let r = try restarted(k, clock, up)
        try? await r.device.handle(r.vault.msg(try r.new.seal(note("first", at: Date())))) // dropped after (in the future)
        let open15 = r.device.mem.withLock { r.device.keyring.find(r.old.id, now: Date().addingTimeInterval(15 * Self.day)) != nil }
        #expect(open15, "kept 16 days from the message's ts, not 6")
    }

    /// A stamp far in the future does not keep a released epoch to that date: counted from at most the durable window plus the
    /// allowed skew past the known time.
    @Test func aReleaseIsCappedAgainstAStampFarAhead() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let k = try await kept(clock, up)
        try? await k.device.handle(k.vault.msg(try k.new.seal(note("far", at: Date().addingTimeInterval(100 * Self.day)))))
        let held40 = k.device.mem.withLock { k.device.keyring.find(k.old.id, now: Date().addingTimeInterval(40 * Self.day)) != nil }
        #expect(!held40, "not kept to the stamp's date (+116 days)")
        let held30 = k.device.mem.withLock { k.device.keyring.find(k.old.id, now: Date().addingTimeInterval(30 * Self.day)) != nil }
        #expect(held30, "kept to the cap (+32 days)")
    }

    /// A clock jumped 17 days ahead does not stop the device's re-send of an `hs.resp` that may not have arrived: its age is
    /// judged by the vault's time.
    @Test func aClockAheadDoesNotStopAnHsRespResend() async throws {
        let clock = Box(Date())
        let up = Box<TimeInterval>(1000)
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), now: { clock.value }, uptime: { up.value }))
        let ini = try v.rekey(d)
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        clock.value = clock.value.addingTimeInterval(17 * Self.day) // the wall clock only
        await d.resendResps()
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
    }
}

// swiftlint:enable line_length
