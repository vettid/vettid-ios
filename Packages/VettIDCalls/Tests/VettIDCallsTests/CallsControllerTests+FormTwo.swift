import Foundation
import Testing
import VettIDCrypto
@testable import VettIDCalls
@testable import VettIDVault

/// (C2) The vault's level from `call.list`, form 2 starts naming the connection's key, the keep-alives and the C2 stale sweep
/// (VAULT-MESSAGING §10.10 "Mixed releases", "Liveness"). Port of the C2 cases of vettid-android `CallsControllerTest`.
extension CallsControllerTests {
    /// The probe's answer of a C2 vault: `v: 2` with the vault's `now`.
    func c2(_ calls: [CallRecord] = []) -> () throws -> CallList {
        // The connection shown by its key's fingerprint, as one record gives both.
        vault.identities["conn-1"] = vault.keys["conn-1"].flatMap { try? IkFingerprint.format($0) }
        return { CallList(calls: calls, skipped: 0, version: 2, now: at(0)) }
    }

    var keepalives: [String] { vault.gatewayFake.keepalives }

    @Test func aCallToAC2VaultNamesTheConnectionsKeyAndToAnS10OneIsFormOne() async throws {
        vault.gatewayFake.listResult = c2()
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        c.call("conn-1")
        await settle()
        #expect(vault.gatewayFake.startPeerIks == [vault.keys["conn-1"]])

        // Locked, and the next unlock finds an S10 vault: nothing of the level was kept.
        c.hangUp()
        await settle()
        vault.setUnlocked(false)
        await settle()
        vault.gatewayFake.listResult = { CallList(calls: [], skipped: 0) }
        await unlock()
        c.call("conn-1")
        await settle()
        #expect(vault.gatewayFake.startPeerIks.count == 2 && vault.gatewayFake.startPeerIks[1] == nil, "form 1 only to an S10 vault")
    }

    /// Without the connection's key a C2 vault gets no call: form 1 alone would let a connection pass the call on unnoticed.
    @Test func aC2VaultWithoutTheConnectionsKeyGetsNoCall() async {
        vault.gatewayFake.listResult = c2()
        vault.keys = [:]
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        c.call("conn-1")
        await settle()
        #expect(!vault.gatewayFake.asked.contains { $0.hasPrefix("start(") }, "nothing was sent")
        if case .live = c.state { Issue.record("no call is placed") }
    }

    /// Keep-alives start once the answer is taken (never while the call only rings), go every 30 s, and stop with the call.
    @Test func keepAlivesGoEvery30SecondsWhileTheCallIsActive() async throws {
        vault.gatewayFake.listResult = c2()
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        c.call("conn-1")
        await clock.advance(by: 5000)
        #expect(keepalives.isEmpty, "not before the answer: the vault would answer call.end{unavailable}")
        c.hangUp()
        await settle()
        vault.gatewayFake.asked.removeAll()
        try await activeCall(c)
        await settle()
        #expect(keepalives == [callId], "the first as soon as the answer is taken")
        await clock.advance(by: 29_000)
        #expect(keepalives.count == 1)
        // (The test clock runs what is due at the new time with runCurrent.)
        await clock.advance(by: 1000)
        await clock.runCurrent()
        #expect(keepalives.count == 2)
        await clock.advance(by: 30_000)
        await clock.runCurrent()
        #expect(keepalives.count == 3)
        c.hangUp()
        await settle()
        await clock.advance(by: 90_000)
        #expect(keepalives.count == 3, "none after the end")
    }

    @Test func anS10VaultGetsNoKeepAlive() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        try await activeCall(c)
        await clock.advance(by: 90_000)
        #expect(keepalives.isEmpty)
        #expect(vault.gatewayFake.startPeerIks == [nil])
    }

    /// The callee: its answer says `keepalive` to a C2 vault, and the keep-alives go once the answer is with the vault.
    @Test func theCalleeOfAC2VaultAnswersWithKeepalive() async throws {
        vault.gatewayFake.listResult = c2()
        let c = try await ringing()
        c.answer()
        await clock.advance(by: 200)
        #expect(vault.gatewayFake.answerKeepalives == [true])
        #expect(keepalives == [callId])
    }

    /// A form 2 offer proves the vault C2 for its call, even where the probe found S10: the answer says `keepalive` and the
    /// keep-alives go.
    @Test func aFormTwoOfferBringsKeepAlivesWhateverTheProbeSaid() async throws {
        let parties = try CallWire.Parties(caller: filled(32, 1), callee: filled(32, 2))
        vault.gatewayFake.incomingResult = { _ in
            let c = try self.incoming()
            return IncomingCall(
                callId: c.callId, connectionId: c.connectionId, media: c.media, sdp: c.sdp, exp: c.exp, ringFor: c.ringFor,
                ice: c.ice, negotiated: c.negotiated, ek: c.ek, parties: parties
            )
        }
        vault.gatewayFake.answerKeys = CallKeys(suite: .aes128Gcm, send: filled(32, 5), receive: filled(32, 6))
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await clock.advance(by: 200)
        c.answer()
        await clock.advance(by: 200)
        #expect(vault.gatewayFake.answerKeepalives == [true])
        #expect(keepalives == [callId])
    }

    @Test func theCalleeOfAnS10VaultAnswersWithoutKeepalive() async throws {
        let c = try await ringing()
        c.answer()
        await clock.advance(by: 30_200)
        #expect(vault.gatewayFake.answerKeepalives == [false])
        #expect(keepalives.isEmpty)
    }

    /// Against a C2 vault the sweep ends only this device's own live calls, by `device_id`, `exp` and the vault's `now`.
    @Test func theC2SweepEndsOnlyThisDevicesOwnCallsByTheVaultsClock() async {
        vault.gatewayFake.listResult = c2([
            record("A", state: "active", startedAtMs: -60_000, device: "dev-me"),
            record("B", direction: "out", state: "ringing", startedAtMs: -50_000, expMs: -5000, device: "dev-me"),
            record("C", direction: "out", state: "ringing", startedAtMs: -10_000, expMs: 35_000, device: "dev-me"),
            record("D", direction: "in", state: "ringing", startedAtMs: -600_000, expMs: -555_000, device: "dev-me"),
            record("E", state: "active", startedAtMs: -3_600_000, device: "dev-other"),
            record("F", direction: "out", state: "ringing", startedAtMs: -600_000, expMs: -555_000),
            record("G", state: "ended", reason: "hangup", startedAtMs: -60_000, endedAtMs: -1000, device: "dev-me"),
        ])
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(vault.gatewayFake.ended == ["A failed", "B timeout"])
        #expect(c.diagnostics.staleEnded == 2)
    }

    @Test func theC2SweepWithoutThisDevicesIdEndsNothing() async {
        vault.me = nil
        vault.gatewayFake.listResult = c2([record("A", state: "active", startedAtMs: -60_000, device: "dev-me")])
        _ = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(vault.gatewayFake.ended.isEmpty)
    }

    /// A keep-alive that fails is not an end: the call goes on, and the next goes 30 s later.
    @Test func aFailedKeepAliveKeepsTheCallAndTheNextGoesOnTime() async throws {
        vault.gatewayFake.listResult = c2()
        vault.gatewayFake.keepaliveFails = true
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        try await activeCall(c)
        await settle()
        #expect(keepalives.count == 1)
        guard case .live(let l) = c.state, l.phase == .active else { throw WrongState(state: c.state) }
        await clock.advance(by: 30_000)
        await clock.runCurrent()
        #expect(keepalives.count == 2)
        guard case .live(let still) = c.state, still.phase == .active else { throw WrongState(state: c.state) }
    }

    /// `v: 2` without a readable `now`: no sweep at all, neither the C1 one by this phone's clock (it would end another
    /// device's call) nor the C2 one (no vault clock to judge by).
    @Test func aC2ListWithoutNowSweepsNothing() async {
        vault.gatewayFake.listResult = {
            CallList(calls: [
                record("A", state: "active", startedAtMs: -3_600_000, device: "dev-other"),
                record("B", direction: "out", state: "ringing", startedAtMs: -600_000, expMs: -555_000, device: "dev-me"),
            ], skipped: 0, version: 2, now: nil)
        }
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(vault.gatewayFake.ended.isEmpty)
        #expect(c.diagnostics.staleEnded == 0)
    }

    /// The C2 sweep judges by the vault's `now`, never this phone's clock: here the vault is 10 minutes behind the phone.
    @Test func theC2SweepUsesTheVaultsClockNotThePhones() async {
        vault.gatewayFake.listResult = c2([
            // Still ringing by the vault's clock (exp 10 s after its now), long past by the phone's.
            record("B", direction: "out", state: "ringing", startedAtMs: -620_000, expMs: -590_000, device: "dev-me"),
            // Past exp by the vault's clock.
            record("C", direction: "out", state: "ringing", startedAtMs: -650_000, expMs: -605_000, device: "dev-me"),
        ])
        let list = vault.gatewayFake.listResult
        vault.gatewayFake.listResult = {
            let l = try list()
            return CallList(calls: l.calls, skipped: 0, version: 2, now: at(-600_000))
        }
        _ = controller(FakeMicrophone(.granted))
        await unlock()
        #expect(vault.gatewayFake.ended == ["C timeout"])
    }

    /// A call that starts here while the C2 sweep is ending another stops the sweep: the calls after it are left alone.
    @Test func aCallStartedDuringTheC2SweepStopsIt() async throws {
        vault.gatewayFake.listResult = c2([
            record("A", state: "active", startedAtMs: -60_000, device: "dev-me"),
            record("B", state: "active", startedAtMs: -50_000, device: "dev-me"),
        ])
        let gate = Gate()
        vault.gatewayFake.endGate = gate
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        let c = controller(FakeMicrophone(.granted))
        vault.setUnlocked(true)
        #expect(await eventually { vault.gatewayFake.asked.contains("end(A, failed)") })
        c.call("conn-1")
        await settle()
        guard case .live = c.state else { throw WrongState(state: c.state) }
        vault.gatewayFake.endGate = nil
        gate.open()
        await settle()
        #expect(!vault.gatewayFake.asked.contains("end(B, failed)"), "B is left alone once a call is live")
    }
}
