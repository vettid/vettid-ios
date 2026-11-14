import Foundation
import Testing
@testable import VettIDCalls
@testable import VettIDVault

/// The app's vault with the hook of the member's lock, over ``FakeCallVault``.
@MainActor
final class FakeAppVault: CallsAppVault {
    let inner = FakeCallVault()
    private(set) var hooks: [@MainActor () async -> Void] = []

    var gateway: any CallGateway { inner.gateway }
    var updateShowing: Bool { inner.updateShowing }
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
