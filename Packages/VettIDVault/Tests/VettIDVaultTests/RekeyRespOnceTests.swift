import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay

/// One `hs.resp` per `hs.init` (VAULT-MESSAGING §6.3; §6.5: an `hs.init` already answered is acked and dropped). A vault
/// that deposits its rekey `hs.init` again (a new msg_id) gets no second responder: the same bytes go again only while
/// they may not have reached the relay, and the device re-sends those by itself. Mirrors vettid-android
/// `VaultDeviceTest`'s `aRedeliveredRekeyInitMakesNoSecondResponder` and its siblings.
extension VaultDeviceTests {
    /// The relay stores the `hs.resp` and answers 503 (its answer lost): one request, never sent again by the client.
    private func lostFirstAnswer() {
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        relay.recordRefused = true
    }

    @Test func aRedeliveredRekeyInitMakesNoSecondResponder() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        let ini = try v.rekey(d)
        lostFirstAnswer()
        try await d.handle(v.msg(ini.envelope))
        let first = try await relay.nextDeposit().payload
        #expect(await relay.noDeposit(within: 0.2) && relay.refused == 1, "one request: the client does not send it again")
        relay.recordRefused = false
        #expect(try savedState(store).vault?.awaiting.first?.resp != nil, "kept while it may not have arrived")
        // After a restart, the vault deposits the hs.init again (a new msg_id): the same bytes, no second responder.
        d.stop()
        let again = try #require(try VaultDevice.load(config(store), secrets: secrets))
        try await again.handle(v.msg(ini.envelope))
        #expect(try await relay.nextDeposit().payload == first)
        #expect(try savedState(store).vault?.awaiting.count == 1)
        // Accepted now: a further one is dropped, also after another restart.
        try await again.handle(v.msg(ini.envelope))
        #expect(await relay.noDeposit(within: 0.2))
        #expect(try savedState(store).vault?.awaiting.first?.resp == nil)
        again.stop()
        let third = try #require(try VaultDevice.load(config(store), secrets: secrets))
        try await third.handle(v.msg(ini.envelope))
        #expect(await relay.noDeposit(within: 0.2))
        // The rekey completes; its hs.init once more makes no hs.resp (only, under the old epoch it came in, the confirmation
        // again: a session message).
        let res = try ini.handleResp(first, collectSender: third.relayAddr.pk, now: Date())
        v.keyring.activate(res.epoch, now: Date())
        try await third.handle(v.msg(res.fin))
        try await expectConfirm(v, res.epoch)
        try await third.handle(v.msg(ini.envelope))
        try await Task.sleep(nanoseconds: 200_000_000)
        while let p = try? await relay.nextDeposit(timeout: 0) { #expect(try res.epoch.open(try Envelope.parse(p.payload)).type == "hs.confirm") }
        #expect(try savedState(store).vault?.awaiting.isEmpty == true)
    }

    /// A first attempt refused for good never reached the vault: the responder and its mark end, and the `hs.init` deposited
    /// again is answered afresh (that is no second `hs.resp`).
    @Test func aRefusedRekeyRespIsAnsweredAfresh() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let ini = try v.rekey(d)
        relay.refuseDeposits = RelayError.tokenInvalid
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        for _ in 0..<200 where try savedState(store).vault?.awaiting.isEmpty != true { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(try savedState(store).vault?.awaiting.isEmpty == true)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        v.keyring.activate(res.epoch, now: Date())
        try await d.handle(v.msg(res.fin))
        try await expectConfirm(v, res.epoch)
    }

    /// A re-send refused for good: the first copy may be at the vault, so the responder and its mark stay and only the
    /// re-sending stops; no second, different `hs.resp` is made.
    @Test func aRefusedResendOfAnUnknownRespMakesNoSecondAnswer() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let ini = try v.rekey(d)
        lostFirstAnswer()
        try await d.handle(v.msg(ini.envelope))
        let first = try await relay.nextDeposit().payload
        relay.recordRefused = false
        relay.refuseStatus = 403
        relay.refuseDeposits = RelayError.tokenInvalid
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        #expect(relay.refused == 2)
        try await d.handle(v.msg(ini.envelope))
        #expect(await relay.noDeposit(within: 0.2) && relay.refused == 2, "the re-sending stopped")
        #expect(try savedState(store).vault?.awaiting.count == 1)
        // The vault had the first copy: its hs.fin still completes the rekey.
        let res = try ini.handleResp(first, collectSender: d.relayAddr.pk, now: Date())
        v.keyring.activate(res.epoch, now: Date())
        try await d.handle(v.msg(res.fin))
        try await expectConfirm(v, res.epoch)
    }

    /// The device re-sends an `hs.resp` that may not have arrived by itself, the same bytes: after the next handled message,
    /// and at a collection start after a restart.
    @Test func anUnsentRespIsDepositedAgainByTheDeviceItself() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        let ini = try v.rekey(d)
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        #expect(relay.refused == 1)
        try await d.handle(try v.seal("message.new", #"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"x"}"#))
        let resent = try await relay.nextDeposit().payload
        _ = try ini.handleResp(resent, collectSender: d.relayAddr.pk, now: Date()) // a valid answer to this hs.init
        #expect(await relay.noDeposit(within: 0.2), "accepted: not again")
        // Once more, unsent before a restart: the collection start sends it.
        let ini2 = try v.rekey(d)
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini2.envelope))
        d.stop()
        let again = try #require(try VaultDevice.load(config(store), secrets: secrets))
        relay.serveMailbox = true
        again.start()
        _ = try ini2.handleResp(try await relay.nextDeposit().payload, collectSender: again.relayAddr.pk, now: Date())
        again.stop()
    }

    /// An `hs.resp` is never deposited before a save holds its responder (§8.3): a re-send while the handling that made it
    /// has not saved yet sends nothing, and the handling's own deposit follows its save.
    @Test func aRespIsNotResentBeforeASaveHoldsItsResponder() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        d.beforeFinalSave = { [d] in await d.resendResps() }
        try await d.handle(v.msg(ini.envelope))
        d.beforeFinalSave = nil
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        #expect(await relay.noDeposit(within: 0.2), "one deposit, after the save")
    }

    /// `quota_exceeded` is no refusal of the `hs.resp`: the responder and its bytes stay, and the re-send waits a minute.
    @Test func aRespRefusedForAQuotaWaitsAndGoesAgain() async throws {
        let up = Box<TimeInterval>(1000)
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store, cfg: config(store, uptime: { up.value }))
        let ini = try v.rekey(d)
        relay.refuseStatus = 429
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseQuota = "mailbox"
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        #expect(relay.refused == 1)
        #expect(try savedState(store).vault?.awaiting.count == 1)
        await d.resendResps()
        #expect(await relay.noDeposit(within: 0.1) && relay.refused == 1, "held for its wait")
        up.value += 61
        await d.resendResps()
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
    }
}
