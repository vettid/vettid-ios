import Foundation
import Testing
import VettIDCrypto
@testable import VettIDCalls
@testable import VettIDVault

/// The app's vault with the hook of the member's lock, over ``FakeCallVault``.
@MainActor
final class FakeAppVault: CallsAppVault {
    let inner = FakeCallVault()
    private(set) var hooks: [@MainActor () async -> Void] = []

    var gateway: any CallGateway { inner.gateway }
    var updateShowing: Bool { inner.updateShowing }
    var isOpen: Bool { inner.unlocked }
    func unlockedChanges() -> AsyncStream<Bool> { inner.unlockedChanges() }
    func rechecks() -> AsyncStream<Void> { inner.rechecks() }
    func fingerprint(_ connectionId: String) async -> String? { await inner.fingerprint(connectionId) }
    func name(_ connectionId: String) -> String? { inner.name(connectionId) }
    func firstName(_ connectionId: String) -> String? { inner.firstName(connectionId) }
    func refreshConnections() async { await inner.refreshConnections() }
    func onBeforeLock(_ hook: @escaping @MainActor () async -> Void) { hooks.append(hook) }
    private(set) var holds: [@MainActor () -> Bool] = []
    private(set) var holdsEnded = 0
    func holdCollection(_ held: @escaping @MainActor () -> Bool) { holds.append(held) }
    func collectionHoldEnded() { holdsEnded += 1 }
}

/// The wiring of the calls in the app: the call logic starts when the vault opens and stops when it does not, the hook of the
/// lock is registered once, and the Call button follows what the vault's probe said.
@MainActor
@Suite(.serialized) final class CallsHostTests {
    let vault = FakeAppVault()
    let clock = TestClock()
    let engines = FakeEngines()
    let kit = FakeKit()
    let audio = FakeAudio()
    let tones = FakeTones()
    let mic = FakeMicrophone(.granted)
    var partsMade = 0
    var hosts: [CallsHost] = []

    deinit {
        MainActor.assumeIsolated { for h in hosts { h.runtime.map { $0.controller.stop() } } }
    }

    func host() -> CallsHost {
        let h = CallsHost(
            vault: vault,
            parts: { [self] in
                partsMade += 1
                return CallsParts(
                    engines: engines, audio: audio, kit: kit, attach: { [kit] in kit.delegate = $0 }, tones: tones, microphone: mic,
                    clock: clock
                )
            }
        )
        hosts.append(h)
        return h
    }

    func settle() async { await clock.runCurrent() }

    @Test func nothingRunsBeforeTheVaultOpens() async {
        let h = host()
        h.start()
        await settle()
        #expect(h.runtime == nil && h.started == 0 && partsMade == 0)
        #expect(h.availability == .unknown && !h.canCall && !h.screenShown)
    }

    @Test func theLockHookIsRegisteredOnceAtStart() async {
        let h = host()
        #expect(vault.hooks.isEmpty)
        h.start()
        h.start()
        #expect(vault.hooks.count == 1)
        // With no call (and no runtime) the hook returns at once.
        await vault.hooks[0]()
        vault.inner.setUnlocked(true)
        await settle()
        await vault.hooks[0]()
        #expect(h.runtime != nil)
    }

    @Test func startsWhenTheVaultOpensAndStopsWhenItLocks() async {
        let h = host()
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        let first = h.runtime
        #expect(first != nil && h.started == 1 && partsMade == 1)
        // The coordinator follows the machine: the audio session was prepared only for a call, none yet.
        vault.inner.setUnlocked(false)
        await settle()
        #expect(h.runtime == nil)
        // Stopped: the coordinator let go of the audio.
        #expect(audio.log.contains("callEnded"))
        vault.inner.setUnlocked(true)
        await settle()
        // A new opening builds the call logic again, over the same engine, CallKit and audio session.
        #expect(h.runtime != nil && h.runtime !== first && h.started == 2 && partsMade == 1)
    }

    @Test func aLockDropsTheCallLogicAfterACallWasTried() async throws {
        let h = host()
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        let gateway = vault.inner.gatewayFake
        gateway.startResult = { _, _ in throw CallMessageError("not placed") }
        h.call("conn-1")
        await settle()
        // The runtime goes on a lock, a live call or not; nothing stays open in CallKit.
        vault.inner.setUnlocked(false)
        await settle()
        #expect(h.runtime == nil)
        #expect(h.uiState.call == .idle)
    }

    /// A live call keeps the vault's collection going in the background (`VaultManager.holdCollection`): the hold says so only while a
    /// call is live, and tells the vault when it is not any more (an ending, a lock).
    @Test func theCollectionHoldIsLiveOnlyDuringACall() async {
        let h = host()
        h.start()
        #expect(vault.holds.count == 1 && vault.holdsEnded == 0)
        #expect(vault.holds[0]() == false, "no vault open, no call")
        vault.inner.gatewayFake.startGate = Gate()
        vault.inner.setUnlocked(true)
        await settle()
        #expect(vault.holds[0]() == false, "open, no call")
        h.call("conn-1")
        await settle()
        guard case .live = h.uiState.call else {
            Issue.record("no live call: \(h.uiState.call)")
            return
        }
        #expect(vault.holds[0]() == true, "a call is live")
        let ended = vault.holdsEnded
        vault.inner.gatewayFake.startGate?.open()
        await settle()
        #expect(vault.holds[0]() == false, "the call ended (it could not be placed)")
        #expect(vault.holdsEnded > ended, "the vault is told: a background that waited for the call may finish")
    }

    /// An active outgoing call placed through the host, until media flows.
    func activeCall(_ h: CallsHost) async throws {
        let gateway = vault.inner.gatewayFake
        gateway.startResult = { _, _ in
            OutgoingCall(
                callId: callId, connectionId: "conn-1", media: "audio", exp: at(45_000),
                ice: CallWire.IceConfig(callId: callId, exp: at(600_000), servers: []), offered: [1], pinnedFingerprint: "",
                offerKey: try CallWire.newOfferKey()
            )
        }
        gateway.acceptResult = { _ in
            let keys = CallKeys(suite: .aes128Gcm, send: filled(32, 5), receive: filled(32, 6))
            return AcceptedCall(callId: callId, sdp: "v=0\r\ns=answer\r\n", keys: keys)
        }
        h.call("conn-1")
        await settle()
        gateway.send(.answer(VaultMessage(inner: Inner(
            id: "01JB2Z6V9K3M4N5P6Q7R8S9T61", type: "call.answer", ts: t0, body: Array(#"{"call_id":"\#(callId)"}"#.utf8)
        ))))
        await settle()
        let engine = engines.last
        engine.emit(.connection(.connected))
        engine.emit(.cryptor(.send, .ok))
        engine.emit(.cryptor(.receive, .ok))
        await settle()
        guard case .live(let l) = h.uiState.call, l.phase == .active else { throw WrongState(state: h.uiState.call) }
    }

    /// At a lock the call screen goes with the first line (the vault counts as locked at once), before the unlock screen comes: it
    /// does not wait for the call logic to see the lock or for the hang-up.
    @Test func theCallScreenGoesAtTheFirstLineOfALock() async throws {
        let h = host()
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        try await activeCall(h)
        #expect(h.screenShown)
        vault.inner.setUnlocked(false)
        #expect(!h.screenShown, "gone at once, though the call logic has not run yet")
    }

    /// The lock's hook waits for a real pending hang-up: the call's end is handed to the vault and not yet with the relay.
    @Test func theLockHookWaitsForTheHangUpOfALiveCall() async throws {
        let h = host()
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        try await activeCall(h)
        let gate = Gate()
        vault.inner.gatewayFake.endGate = gate
        var done = false
        let waiter = Task {
            await vault.hooks[0]()
            done = true
        }
        await clock.advance(by: 1500)
        #expect(vault.inner.gatewayFake.asked.contains("end(\(callId), hangup)"), "the hang-up was handed to the vault")
        #expect(!done, "the end is not with the relay yet: the lock waits")
        gate.open()
        await settle()
        #expect(done)
        await waiter.value
    }

    /// Your own hang-up in the background: the vault's collection is let go only once the hang-up is with the relay (bounded), not as
    /// soon as the call is over on this phone.
    @Test func theCollectionIsLetGoOnlyAfterTheHangUpIsWithTheRelay() async throws {
        let h = host()
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        try await activeCall(h)
        let gate = Gate()
        vault.inner.gatewayFake.endGate = gate
        let before = vault.holdsEnded
        h.hangUp()
        await clock.advance(by: 500)
        #expect(vault.holdsEnded == before, "the hang-up is not with the relay yet")
        gate.open()
        await settle()
        #expect(vault.holdsEnded > before, "let go once it is")
    }

    /// A call that ends and rings the connection's held offer in the same turn (a glare): the offer keeps ringing; the end of the first
    /// is not taken for a lock's.
    @Test func theEndOfACallDoesNotHangUpTheGlareOfferThatRingsNext() async throws {
        let h = host()
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        let gateway = vault.inner.gatewayFake
        gateway.startResult = { _, _ in
            OutgoingCall(
                callId: callId, connectionId: "conn-1", media: "audio", exp: at(45_000),
                ice: CallWire.IceConfig(callId: callId, exp: at(600_000), servers: []), offered: [1], pinnedFingerprint: "",
                offerKey: try CallWire.newOfferKey()
            )
        }
        gateway.incomingResult = { _ in
            IncomingCall(
                callId: glareId, connectionId: "conn-1", media: "audio", sdp: "v=0\r\n", exp: at(45_000), ringFor: 45,
                ice: CallWire.IceConfig(callId: glareId, exp: at(600_000), servers: []),
                negotiated: try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1]), ek: [UInt8](repeating: 0, count: 1216)
            )
        }
        h.call("conn-1")
        await settle()
        let body = #"{"connection_id":"conn-1","call_id":"\#(glareId)"}"#
        let offer = Inner(id: "01JB2Z6V9K3M4N5P6Q7R8S9T62", type: "call.offer", ts: t0, body: Array(body.utf8))
        gateway.send(.offer(VaultMessage(inner: offer)))
        await settle()
        gateway.send(.ended(CallEnded(callId: callId, reason: CallReason.decline)))
        await settle()
        guard case .live(let l) = h.uiState.call else { throw WrongState(state: h.uiState.call) }
        #expect(l.phase == .incoming && l.callId == glareId, "the offer rings on")
        #expect(!gateway.asked.contains { $0.hasPrefix("end(\(glareId)") }, "and is not ended as a lock's")
    }

    @Test func aLockTellsTheVaultNoCallHoldsTheCollection() async {
        let h = host()
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        let ended = vault.holdsEnded
        vault.inner.setUnlocked(false)
        await settle()
        #expect(h.runtime == nil && vault.holdsEnded > ended)
    }

    @Test func theCallButtonFollowsTheProbe() async {
        let h = host()
        h.start()
        #expect(!h.canCall)
        vault.inner.gatewayFake.listGate = Gate()
        vault.inner.setUnlocked(true)
        await settle()
        // Asked, not answered yet: no button.
        #expect(h.availability == .unknown && !h.canCall)
        vault.inner.gatewayFake.listGate?.open()
        await settle()
        #expect(h.availability == .ready && h.canCall)
        vault.inner.setUnlocked(false)
        await settle()
        #expect(!h.canCall)
    }

    /// A conversation's history through the host: empty with no vault open, the connection's calls once it is (the skipped count
    /// with them, in every conversation), and empty again for a vault without calls.
    @Test func theHistoryOfAConversationComesThroughTheHost() async {
        let h = host()
        vault.inner.gatewayFake.listResult = {
            CallList(calls: [record(state: "ended", reason: "decline")], skipped: 1)
        }
        h.start()
        #expect(await h.history("conn-1") == CallHistory())
        vault.inner.setUnlocked(true)
        await settle()
        let mine = await h.history("conn-1")
        #expect(mine.entries.map(\.outcome) == [.declined] && mine.someNotShown)
        let other = await h.history("conn-2")
        #expect(other.entries.isEmpty && other.someNotShown)
        vault.inner.setUnlocked(false)
        await settle()
        #expect(await h.history("conn-1") == CallHistory())
    }

    @Test func noCallButtonForAVaultWithoutCalls() async {
        let h = host()
        vault.inner.gatewayFake.listResult = { throw VaultOpError(type: "error", code: "unsupported_type", detail: "", body: nil) }
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        #expect(h.availability == .notInVault && !h.canCall)
    }

    @Test func noCallButtonWhenTheProbeIsRefusedOtherwise() async {
        let h = host()
        vault.inner.gatewayFake.listResult = { throw VaultOpError(type: "error", code: "owner_check_required", detail: "", body: nil) }
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        #expect(h.availability == .unknown && !h.canCall)
    }

    @Test func theMicrophoneGateShowsOurScreenBeforeTheCall() async {
        let h = host()
        h.start()
        vault.inner.setUnlocked(true)
        await settle()
        mic.status = .undetermined
        h.call("conn-1")
        #expect(h.microphoneScreen?.prompt == .explain(.call(connectionId: "conn-1")))
        #expect(h.screenShown)
        h.closeMicrophonePrompt()
        #expect(h.microphoneScreen == nil && !h.screenShown)
        mic.status = .denied
        h.call("conn-1")
        #expect(h.microphoneScreen?.prompt == .blocked(.call(connectionId: "conn-1")))
    }
}
