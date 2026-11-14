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
        #expect(kit.actions.first == .start(uuid, handle: c.trackedHandle ?? ""))
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
        #expect(audio.log.contains("deactivate"))
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

    // MARK: letting go

    /// A late `didActivate` (after a stop, or with no call) opens nothing.
    @Test func aLateActivationOpensNoAudio() async throws {
        let c = coordinator(machine())
        c.audioDidActivate()
        #expect(!audio.log.contains("activate"), "no call")
        c.apply(state(.incoming, .incoming))
        await settle()
        c.stop()
        c.audioDidActivate()
        #expect(!audio.log.contains("activate"), "after the stop")
        let other = FakeKit()
        other.incomingResult = .filtered
        let c2 = CallKitCoordinator(
            machine: machine(), provider: other, control: other, audio: audio, tones: tones, clock: clock, isForeground: { true }
        )
        c2.apply(state(.incoming, .incoming))
        await settle()
        c2.audioDidActivate()
        #expect(!audio.log.contains("activate"), "a call CallKit does not carry")
    }

    /// The machine is stopped mid-call (a lock, a sign-out): the stream ends and nothing stays open in CallKit.
    @Test func aMachineStoppedMidCallClosesTheCallInCallKitAndResetsTheAudio() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = coordinator(m)
        c.start()
        m.call("conn-1")
        await clock.runCurrent()
        await settle()
        let uuid = try #require(kit.uuid)
        c.audioDidActivate()
        c.apply(state(.ringing, .outgoing))
        #expect(tones.ringBackNow)
        m.stop()
        await settle()
        #expect(kit.events.last == .ended(uuid, .failed))
        #expect(audio.log.suffix(2) == ["deactivate", "callEnded"])
        #expect(!tones.ringBackNow)
        c.stop()
        #expect(kit.events.filter { if case .ended = $0 { true } else { false } }.count == 1, "reported once")
    }

    @Test func stoppingTheCoordinatorMidCallClosesTheCallInCallKitToo() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        let uuid = try #require(kit.uuid)
        c.audioDidActivate()
        c.stop()
        #expect(kit.events.last == .ended(uuid, .failed))
        #expect(audio.log.suffix(2) == ["deactivate", "callEnded"])
    }

    @Test func theHandleIsOpaqueAndPerCallAndTheNameIsGeneric() async throws {
        let c = coordinator(machine())
        c.apply(state(.starting, .outgoing))
        await settle()
        let first = try #require(c.trackedHandle)
        #expect(UUID(uuidString: first) != nil && !first.contains("conn-1"))
        c.apply(ended(.noAnswer))
        c.apply(state(.starting, .outgoing), seq: 1)
        #expect(c.trackedHandle != first)
        // Owner decision: CallKit (and so the lock screen) never shows with whom.
        let names = kit.events.compactMap { e -> String? in
            switch e {
            case .incoming(_, let u), .updated(_, let u): u.name
            default: nil
            }
        }
        #expect(!names.isEmpty && names.allSatisfy { $0 == CallKitName.generic })
        #expect(CallKitName.generic == "VettID call")
    }

    @Test func aTimedOutActionOfAnotherCallIsIgnored() async throws {
        let c = coordinator(machine())
        c.apply(state(.active, .incoming))
        await settle()
        c.actionTimedOut(uuid: UUID())
        await settle()
        #expect(kit.events.allSatisfy { if case .ended = $0 { false } else { true } })
    }

    /// A failure is not the member's own end: the call held meanwhile still rings.
    @Test func aFailureOfAnOutgoingCallStillRingsTheHeldOffer() async throws {
        let signalling = FakeSignalling()
        signalling.holdStart()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        m.call("conn-1")
        await clock.runCurrent()
        signalling.deliver(offer(glareId))
        await clock.runCurrent()
        m.end(.failed, seq: 0)
        await clock.runCurrent()
        guard case .live(let l) = m.state else { throw WrongState(state: m.state) }
        #expect(l.callId == glareId && l.phase == .incoming)
    }

    @Test func aRefusedMuteLeavesCallKitWithWhatItHad() async throws {
        let c = coordinator(machine())
        c.apply(state(.active, .incoming))
        await settle()
        kit.refuseActions = true
        c.apply(state(.active, .incoming, muted: true))
        await settle()
        kit.refuseActions = false
        let asked = kit.actions.count
        // The machine unmutes again: CallKit never had the mute, so it is not asked to unmute.
        c.apply(state(.active, .incoming, muted: false))
        await settle()
        #expect(kit.actions.count == asked)
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
        c.actionTimedOut(uuid: try #require(kit.uuid))
        await clock.runCurrent()
        guard case .live = m.state else { throw WrongState(state: m.state) }
        #expect(signalling.sent == ["ringing(\(callId))"], "a ringing call is not declined for a local failure")
        // It rings out as missed, and CallKit is told: the timeout did not end it there.
        await clock.advance(by: 120_000)
        await settle()
        guard case .ended(let missed) = m.state else { throw WrongState(state: m.state) }
        #expect(missed.reason == .missed)
        #expect(kit.events.contains { if case .ended(_, .unanswered) = $0 { true } else { false } })
        c.stop()

        let m2 = CallMachine(signalling: FakeSignalling(), engines: engines, clock: clock)
        let kit2 = FakeKit()
        let c2 = CallKitCoordinator(
            machine: m2, provider: kit2, control: kit2, audio: audio, tones: tones, clock: clock, isForeground: { true }
        )
        kit2.delegate = c2
        c2.start()
        m2.call("conn-1")
        await clock.runCurrent()
        await settle()
        c2.actionTimedOut(uuid: try #require(kit2.uuid))
        await clock.runCurrent()
        guard case .ended(let e) = m2.state else { throw WrongState(state: m2.state) }
        #expect(e.reason == .failed)
        await settle()
        // Not silent: the end is reported (for a call CallKit has already ended that is a harmless no-op).
        #expect(kit2.events.last == .ended(try #require(kit2.uuid), .failed))
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
            machine: m, provider: kit, control: kit, audio: audio, tones: tones, clock: clock, isForeground: { false }
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
