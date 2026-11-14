import Foundation
import Testing
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

/// The coordinator's transitions, and CallKit's actions on the machine.
extension CallKitCoordinatorTests {
    // MARK: CallKit to the machine

    @Test func answeringInCallKitAnswersTheMachine() async throws {
        let m = machine()
        let c = coordinator(m)
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        let uuid = try #require(kit.uuid)
        #expect(!c.performAnswer(uuid: UUID()), "another call")
        #expect(c.performAnswer(uuid: uuid))
        await clock.runCurrent()
        guard case .live(let l) = m.state else { throw WrongState(state: m.state) }
        #expect(l.phase == .connecting)
        await settle()
        #expect(kit.actions.isEmpty, "CallKit answered: it is not told again")
        c.stop()
    }

    @Test func endingInCallKitHangsUpOrDeclinesAndIsNotReportedBack() async throws {
        let m = machine()
        let c = coordinator(m)
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        let uuid = try #require(kit.uuid)
        #expect(c.performEnd(uuid: uuid))
        await clock.runCurrent()
        await settle()
        guard case .ended(let e) = m.state else { throw WrongState(state: m.state) }
        #expect(e.reason == .declinedHere)
        #expect(kit.events.allSatisfy { if case .ended = $0 { false } else { true } }, "CallKit ended it: nothing is reported back")
        #expect(kit.actions.isEmpty)
        #expect(c.performEnd(uuid: uuid), "again: nothing to do, and fulfilled")
        c.stop()
    }

    @Test func muteInCallKitMutesTheMachine() async throws {
        let m = machine()
        let c = coordinator(m)
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        let uuid = try #require(kit.uuid)
        #expect(c.performMute(uuid: uuid, muted: true))
        await clock.runCurrent()
        guard case .live(let l) = m.state else { throw WrongState(state: m.state) }
        #expect(l.muted)
        await settle()
        #expect(kit.actions.isEmpty, "CallKit's own mute is not asked of it again")
        c.stop()
    }

    @Test func aCallPlacedInTheAppIsStartedInCallKitThroughTheObservation() async throws {
        let m = machine()
        let c = coordinator(m)
        c.start()
        m.call("conn-1")
        await clock.runCurrent()
        await settle()
        let uuid = try #require(kit.uuid)
        #expect(kit.actions.first == .start(uuid, handle: "handle-conn-1"))
        c.stop()
    }

    @Test func aResetEndsTheCall() async throws {
        let m = machine()
        let c = coordinator(m)
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        c.audioDidActivate()
        c.providerDidReset()
        await clock.runCurrent()
        guard case .ended = m.state else { throw WrongState(state: m.state) }
        #expect(audio.log.suffix(1) == ["deactivate"])
        c.stop()
    }

    // MARK: every transition

    func incomingUuids() -> [UUID] { kit.events.compactMap { if case .incoming(let u, _) = $0 { u } else { nil } } }

    /// An end and the next call's ring published in one turn of the machine: the observation of `state` would see only the ring.
    @Test func anEndAndTheNextRingInOneTurnAreBothSeen() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = coordinator(m)
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        let first = try #require(kit.uuid)
        signalling.deliver(.end(callId: callId, reason: "hangup"))
        signalling.deliver(offer(glareId))
        await clock.runCurrent()
        await settle()
        #expect(kit.events.contains(.ended(first, .unanswered)), "the first call's end reached CallKit")
        let uuids = incomingUuids()
        #expect(uuids.count == 2 && uuids[0] == first && uuids[1] != first, "the second ring is a new call")
        c.stop()
    }

    func offer(_ id: String) -> SignalEvent {
        .offer(CallOffer(
            callId: id, connectionId: "conn-1", sdp: "v=0\r\ns=offer\r\n", exp: at(45_000), ringFor: .seconds(45), servers: [],
            suite: .aes128Gcm, formTwo: false
        ))
    }

    /// An outgoing call refused `busy` before it had a call id, and the offer held meanwhile rings in the same turn.
    @Test func anOutgoingCallRefusedBusyThenTheHeldOfferRingsAsANewCall() async throws {
        let signalling = FakeSignalling()
        signalling.holdStart()
        signalling.startResult = { throw CallRefusedError(code: "busy") }
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = coordinator(m)
        c.start()
        m.call("conn-1")
        await clock.runCurrent()
        await settle()
        let outgoing = try #require(kit.uuid)
        signalling.deliver(offer(glareId))
        await clock.runCurrent()
        signalling.releaseStart()
        await clock.runCurrent()
        await settle()
        #expect(kit.events.contains(.ended(outgoing, .failed)), "the refused call is ended in CallKit first")
        let uuids = incomingUuids()
        #expect(uuids.count == 1 && uuids[0] != outgoing, "and the held offer is reported as a new incoming call")
        let order = kit.events.firstIndex(of: .ended(outgoing, .failed)) ?? .max
        #expect(order < (kit.events.firstIndex { if case .incoming = $0 { true } else { false } } ?? 0))
        c.stop()
    }

    /// A different session replaces the tracked call before its end was seen: the old one is ended first, then the new begins.
    @Test func aDifferentSessionEndsTheTrackedCallBeforeItBeginsTheNew() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming), seq: 0)
        await settle()
        let first = try #require(kit.uuid)
        c.apply(state(.incoming, .incoming), seq: 1)
        await settle()
        #expect(kit.events.count == 3)
        #expect(kit.events[1] == .ended(first, .failed))
        guard case .incoming(let second, _) = kit.events[2] else { throw WrongState(state: .idle) }
        #expect(second != first)
    }

    // MARK: CallKit's actions

    /// An end action for a call the coordinator no longer tracks (a replaced call), or never did, is fulfilled.
    @Test func anEndActionIsFulfilledForAnyCall() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming), seq: 0)
        await settle()
        let first = try #require(kit.uuid)
        c.apply(state(.incoming, .incoming), seq: 1)
        await settle()
        #expect(c.performEnd(uuid: first), "the replaced call")
        #expect(c.performEnd(uuid: UUID()), "an unknown call")
        try await kit.request(.end(first))
    }

    @Test func aTimedOutActionEndsAPlacedCallAndLeavesARingingOneToRingOut() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = coordinator(m)
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        c.actionTimedOut()
        await clock.runCurrent()
        guard case .live = m.state else { throw WrongState(state: m.state) }
        #expect(signalling.sent == ["ringing(\(callId))"], "a ringing call is not declined for a local failure")
        c.stop()

        let m2 = CallMachine(signalling: FakeSignalling(), engines: engines, clock: clock)
        let kit2 = FakeKit()
        let c2 = CallKitCoordinator(
            machine: m2, provider: kit2, control: kit2, audio: audio, tones: tones, clock: clock,
            party: { CallParty(handle: $0, name: $0) }, isForeground: { true }
        )
        kit2.delegate = c2
        c2.start()
        m2.call("conn-1")
        await clock.runCurrent()
        await settle()
        c2.actionTimedOut()
        await clock.runCurrent()
        guard case .ended(let e) = m2.state else { throw WrongState(state: m2.state) }
        #expect(e.reason == .failed)
        await settle()
        #expect(kit2.events.allSatisfy { if case .ended = $0 { false } else { true } }, "CallKit timed out: it is not told again")
        c2.stop()
    }

    /// CallKit's end of one call is not the end of a newer one: an action for the call `seq` does nothing once another is current.
    @Test func aHangUpForAnOldCallLeavesTheNewerOneAlone() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        signalling.deliver(offer())
        await clock.runCurrent()
        signalling.deliver(.end(callId: callId, reason: "hangup"))
        signalling.deliver(offer(glareId))
        await clock.runCurrent()
        guard case .live(let l) = m.state else { throw WrongState(state: m.state) }
        #expect(l.callId == glareId)
        m.hangUp(seq: 0)
        m.end(.failed, seq: 0)
        await clock.runCurrent()
        guard case .live = m.state else { throw WrongState(state: m.state) }
        m.hangUp(seq: 1)
        await clock.runCurrent()
        guard case .ended(let e) = m.state else { throw WrongState(state: m.state) }
        #expect(e.reason == .declinedHere)
    }

    /// Mute is compared with the last value the machine published, and CallKit's own mute is not asked of it again.
    @Test func aMuteRepeatedByTheMachineIsAskedOnceAndCallKitsOwnIsNotEchoed() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        let uuid = try #require(kit.uuid)
        c.apply(state(.active, .incoming, muted: true))
        c.apply(state(.active, .incoming, muted: true))
        c.apply(state(.active, .incoming, muted: true))
        await settle()
        #expect(kit.actions.filter { $0 == .mute(uuid, true) }.count == 1)
        // CallKit unmutes (its screen); the machine then publishes unmuted: not asked of CallKit.
        #expect(c.performMute(uuid: uuid, muted: false))
        c.apply(state(.active, .incoming, muted: false))
        await settle()
        #expect(kit.actions.filter { if case .mute = $0 { true } else { false } }.count == 1)
    }

    @Test func aResetEndsOnlyACallCallKitCarries() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = CallKitCoordinator(
            machine: m, provider: kit, control: kit, audio: audio, tones: tones, clock: clock,
            party: { CallParty(handle: $0, name: $0) }, isForeground: { false }
        )
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        c.providerDidReset()
        await clock.runCurrent()
        guard case .live = m.state else { throw WrongState(state: m.state) }
        c.stop()
    }

    @Test func finishedTasksAreForgotten() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        c.apply(state(.active, .incoming))
        await settle()
        #expect(c.pendingTasks == 0)
    }
}
