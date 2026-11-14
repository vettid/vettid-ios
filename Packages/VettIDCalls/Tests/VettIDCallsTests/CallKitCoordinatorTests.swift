#if os(iOS)
import CallKit
#endif
import Foundation
import Testing
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

/// What the coordinator told CallKit, in order.
enum KitEvent: Equatable {
    case incoming(UUID, CallKitUpdate)
    case updated(UUID, CallKitUpdate)
    case connecting(UUID)
    case connected(UUID)
    case ended(UUID, CallKitEndReason)
}

@MainActor
final class FakeKit: CallKitProviding, CallKitControlling {
    var events: [KitEvent] = []
    var actions: [CallKitAction] = []
    var incomingResult: CallKitReport = .reported
    var refuseActions = false
    /// The coordinator, as CallKit's delegate: a requested action is performed, and refused when the coordinator refuses it.
    weak var delegate: (any CallKitEvents)?

    func reportNewIncomingCall(uuid: UUID, update: CallKitUpdate) async -> CallKitReport {
        events.append(.incoming(uuid, update))
        return incomingResult
    }

    func reportCall(uuid: UUID, updated: CallKitUpdate) { events.append(.updated(uuid, updated)) }

    func reportOutgoingCall(uuid: UUID, startedConnectingAt: Date) { events.append(.connecting(uuid)) }

    func reportOutgoingCall(uuid: UUID, connectedAt: Date) { events.append(.connected(uuid)) }

    func reportCall(uuid: UUID, endedAt: Date, reason: CallKitEndReason) { events.append(.ended(uuid, reason)) }

    func request(_ action: CallKitAction) async throws {
        actions.append(action)
        if refuseActions { throw StartFailure() }
        guard let events = delegate else { return }
        let done: Bool
        switch action {
        case .start(let uuid, _): done = events.performStart(uuid: uuid)
        case .answer(let uuid): done = events.performAnswer(uuid: uuid)
        case .end(let uuid): done = events.performEnd(uuid: uuid)
        case .mute(let uuid, let muted): done = events.performMute(uuid: uuid, muted: muted)
        }
        if !done { throw StartFailure() }
    }

    var uuid: UUID? {
        for case .incoming(let u, _) in events { return u }
        for action in actions { if case .start(let u, _) = action { return u } }
        return nil
    }
}

@MainActor
final class FakeAudio: CallAudioSession {
    var state = AudioState()
    var onStateChange: (@MainActor (AudioState) -> Void)?
    var log: [String] = []

    func prepare() { log.append("prepare") }
    func didActivate() { log.append("activate") }
    func didDeactivate() { log.append("deactivate") }
    func setSpeaker(_ on: Bool) { log.append("speaker(\(on))") }
    func callEnded() { log.append("callEnded") }
}

@MainActor
final class FakeTones: CallTones {
    var ringBackLog: [Bool] = []
    func ringBack(_ on: Bool) { ringBackLog.append(on) }
    var ringBackNow: Bool { ringBackLog.last ?? false }
}

private final class Player {}

/// The coordinator between the machine and CallKit, with fakes in place of CallKit, the audio session and the tones.
@MainActor
@Suite(.serialized) struct CallKitCoordinatorTests {
    let signalling = FakeSignalling()
    let engines = FakeEngines()
    let clock = TestClock()
    let kit = FakeKit()
    let audio = FakeAudio()
    let tones = FakeTones()

    func machine() -> CallMachine { CallMachine(signalling: signalling, engines: engines, clock: clock) }

    func coordinator(_ m: CallMachine, foreground: Bool = true) -> CallKitCoordinator {
        let c = CallKitCoordinator(
            machine: m, provider: kit, control: kit, audio: audio, tones: tones, clock: clock, isForeground: { foreground }
        )
        kit.delegate = c
        return c
    }

    func settle() async { await clock.settle() }

    func state(_ phase: CallPhase, _ direction: CallDirection, muted: Bool = false) -> CallState {
        .live(CallState.Live(
            connectionId: "conn-1", direction: direction, phase: phase, callId: phase == .starting ? nil : callId, muted: muted
        ))
    }

    func ended(_ reason: CallEnd, _ direction: CallDirection = .outgoing) -> CallState {
        .ended(CallState.Ended(connectionId: "conn-1", direction: direction, reason: reason, callId: callId))
    }

    func offer() -> SignalEvent {
        .offer(CallOffer(
            callId: callId, connectionId: "conn-1", sdp: "v=0\r\ns=offer\r\n", exp: at(45_000), ringFor: .seconds(45), servers: [],
            suite: .aes128Gcm, formTwo: false
        ))
    }

    // MARK: machine to CallKit

    @Test func anIncomingCallInTheForegroundIsReportedWithOnlyWhatTheAppPassesIn() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        let uuid = try #require(kit.uuid)
        let expected = CallKitUpdate(handle: c.trackedHandle ?? "", name: CallKitName.generic)
        #expect(kit.events == [.incoming(uuid, expected)])
        #expect(!expected.hasVideo && !expected.supportsHolding && !expected.supportsGrouping && !expected.supportsUngrouping)
        #expect(!expected.supportsDTMF)
        #expect(kit.actions.isEmpty)
        // The same state again is not a second call.
        c.apply(state(.incoming, .incoming))
        await settle()
        #expect(kit.events.count == 1)
    }

    @Test func anIncomingCallInTheBackgroundIsNotReported() async {
        let c = coordinator(machine(), foreground: false)
        c.apply(state(.incoming, .incoming))
        c.apply(state(.connecting, .incoming))
        c.apply(ended(.peerHungUp, .incoming))
        await settle()
        #expect(kit.events.isEmpty && kit.actions.isEmpty)
    }

    /// A call CallKit does not carry (refused: Do Not Disturb, a block list, an error; or offered in the background) never has
    /// audio: answering it does nothing (no decline is sent), and it rings out as missed.
    @Test func anAnswerOfACallCallKitDoesNotCarryIsRefusedAndTheCallIsMissed() async throws {
        for result in [CallKitReport.failed, .filtered] {
            let kit = FakeKit()
            kit.incomingResult = result
            let signalling = FakeSignalling()
            let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
            let c = CallKitCoordinator(
                machine: m, provider: kit, control: kit, audio: audio, tones: tones, clock: clock, isForeground: { true }
            )
            kit.delegate = c
            c.start()
            signalling.deliver(offer())
            await clock.runCurrent()
            await settle()
            #expect(kit.events.count == 1)
            c.answer()
            await clock.runCurrent()
            guard case .live(let l) = m.state else { throw WrongState(state: m.state) }
            #expect(l.phase == .incoming, "\(result)")
            #expect(signalling.sent == ["ringing(\(callId))"], "no decline")
            await clock.advance(by: 48_001)
            guard case .ended(let e) = m.state else { throw WrongState(state: m.state) }
            #expect(e.reason == .missed)
            #expect(signalling.sent == ["ringing(\(callId))"], "and no call.end for the missed call")
            #expect(engines.created.isEmpty, "no engine, no audio")
            #expect(kit.actions.isEmpty && !audio.log.contains("activate"))
            c.stop()
        }
    }

    @Test func aBackgroundOfferIsNeverAnsweredAndAMachineAnsweredAnywayIsEndedAsFailed() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = CallKitCoordinator(
            machine: m, provider: kit, control: kit, audio: audio, tones: tones, clock: clock, isForeground: { false }
        )
        kit.delegate = c
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        #expect(kit.events.isEmpty)
        // The app's screen calls the machine directly: the answer goes through, then the coordinator ends the call as failed.
        m.answer()
        await clock.runCurrent()
        await settle()
        await clock.runCurrent()
        guard case .ended = m.state else { throw WrongState(state: m.state) }
        #expect(signalling.sent.suffix(2) == ["answer(\(callId))", "end(\(callId), failed)"], "answered, then failed: not a decline")
        #expect(!audio.log.contains("activate"))
        c.stop()
    }

    /// The member tapped Answer and CallKit refused it, before the machine had answered: nothing is sent (no decline: the caller
    /// is not told "declined" for a local failure), and the call rings out as missed.
    @Test func aRefusedAnswerSendsNothingAndTheCallRingsOutAsMissed() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = coordinator(m)
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        kit.refuseActions = true
        c.answer()
        await settle()
        await clock.runCurrent()
        guard case .live(let l) = m.state else { throw WrongState(state: m.state) }
        #expect(l.phase == .incoming)
        #expect(signalling.sent == ["ringing(\(callId))"], "no decline")
        #expect(engines.created.isEmpty, "no audio ever opened")
        await clock.advance(by: 48_001)
        guard case .ended(let e) = m.state else { throw WrongState(state: m.state) }
        #expect(e.reason == .missed)
        #expect(signalling.sent == ["ringing(\(callId))"])
        c.stop()
    }

    @Test func aRefusedStartEndsTheCallAsFailed() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = coordinator(m)
        c.start()
        kit.refuseActions = true
        m.call("conn-1")
        await clock.runCurrent()
        await settle()
        await clock.runCurrent()
        guard case .ended(let e) = m.state else { throw WrongState(state: m.state) }
        #expect(e.reason == .failed)
        #expect(kit.events.isEmpty, "CallKit does not know the call: nothing is reported")
        c.stop()
    }

    @Test func everyPhaseOfAnOutgoingCallGoesToCallKit() async throws {
        let c = coordinator(machine())
        c.apply(state(.starting, .outgoing))
        await settle()
        let uuid = try #require(kit.uuid)
        #expect(kit.actions == [.start(uuid, handle: c.trackedHandle ?? "")])
        #expect(audio.log == ["prepare"])

        // CallKit performed the start (the fake performs what is requested): the name and the connecting.
        let update = CallKitUpdate(handle: c.trackedHandle ?? "", name: CallKitName.generic)
        #expect(kit.events == [.updated(uuid, update), .connecting(uuid)])

        c.apply(state(.calling, .outgoing))
        c.apply(state(.ringing, .outgoing))
        #expect(!tones.ringBackNow, "no ring-back before CallKit has given the audio session")
        c.audioDidActivate()
        #expect(tones.ringBackNow)
        c.apply(state(.ringing, .outgoing))
        c.apply(state(.connecting, .outgoing))
        #expect(!tones.ringBackNow)
        #expect(kit.events.count == 2)
        c.apply(state(.active, .outgoing))
        c.apply(state(.active, .outgoing))
        await settle()
        #expect(kit.events.suffix(1) == [.connected(uuid)])
        #expect(kit.events.count == 3, "connected once")
        #expect(kit.actions.count == 1, "an outgoing call is not answered")

        c.apply(ended(.peerHungUp))
        #expect(kit.events.last == .ended(uuid, .remoteEnded))
    }

    @Test func theRingBackStopsWhenTheCallEndsOrTheSessionIsTaken() async throws {
        let c = coordinator(machine())
        c.apply(state(.starting, .outgoing))
        c.audioDidActivate()
        c.apply(state(.ringing, .outgoing))
        #expect(tones.ringBackNow)
        c.audioDidDeactivate()
        #expect(!tones.ringBackNow)
        c.audioDidActivate()
        #expect(tones.ringBackNow)
        c.apply(ended(.noAnswer))
        #expect(!tones.ringBackNow)
    }

    @Test func everyPhaseOfAnIncomingCallGoesToCallKit() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        let uuid = try #require(kit.uuid)
        c.apply(state(.connecting, .incoming))
        c.apply(state(.active, .incoming))
        await settle()
        #expect(kit.actions == [.answer(uuid)], "answered in the app's own screen: CallKit is told once")
        #expect(kit.events.count == 1, "no outgoing reports for an incoming call")
        c.apply(ended(.peerHungUp, .incoming))
        #expect(kit.events.last == .ended(uuid, .remoteEnded))
    }

    @Test func theMachinesMuteGoesToCallKitOnce() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        let uuid = try #require(kit.uuid)
        c.apply(state(.active, .incoming, muted: true))
        c.apply(state(.active, .incoming, muted: true))
        await settle()
        #expect(kit.actions.filter { $0 == .mute(uuid, true) }.count == 1)
        c.apply(state(.active, .incoming, muted: false))
        await settle()
        #expect(kit.actions.last == .mute(uuid, false))
    }

    /// The reasons CallKit is told.
    struct Row { let end: CallEnd, reason: CallKitEndReason }

    static let reasons: [Row] = [
        Row(end: .hungUp, reason: .remoteEnded),
        Row(end: .peerHungUp, reason: .remoteEnded),
        Row(end: .declined, reason: .remoteEnded),
        Row(end: .declinedHere, reason: .declinedElsewhere),
        Row(end: .busy, reason: .remoteEnded),
        Row(end: .noAnswer, reason: .unanswered),
        Row(end: .missed, reason: .unanswered),
        Row(end: .answeredElsewhere, reason: .answeredElsewhere),
        Row(end: .unavailable, reason: .failed),
        Row(end: .ownVaultBusy, reason: .failed),
        Row(end: .callsOff, reason: .failed),
        Row(end: .ownerCheckRequired, reason: .failed),
        Row(end: .notSupported, reason: .failed),
        Row(end: .noAddress, reason: .failed),
        Row(end: .couldNotConnect, reason: .failed),
        Row(end: .connectionLost, reason: .failed),
        Row(end: .notEncrypted, reason: .failed),
        Row(end: .locked, reason: .failed),
        Row(end: .failed, reason: .failed),
    ]

    @Test func everyEndReasonIsMapped() {
        #expect(Self.reasons.count == CallEnd.allCases.count)
        for row in Self.reasons { #expect(row.end.callKitReason == row.reason, "\(row.end)") }
    }

    /// Whatever the reason, the member's own end here is asked of CallKit as a hang-up, and any other end is reported.
    @Test func everyEndReasonReachesCallKit() async throws {
        for row in Self.reasons {
            for memberEnded in [false, true] {
                let kit = FakeKit()
                let c = CallKitCoordinator(
                    machine: machine(), provider: kit, control: kit, audio: audio, tones: tones, clock: clock, isForeground: { true }
                )
                kit.delegate = c
                c.apply(state(.active, .incoming))
                await settle()
                let uuid = try #require(kit.uuid)
                c.apply(ended(row.end, .incoming), memberEnded: memberEnded)
                await settle()
                if memberEnded {
                    #expect(kit.actions.last == .end(uuid), "\(row.end): asked of CallKit as a hang-up")
                    #expect(kit.events.allSatisfy { if case .ended = $0 { false } else { true } })
                } else {
                    #expect(kit.events.last == .ended(uuid, row.reason), "\(row.end)")
                }
            }
        }
    }

    /// The vault's `decline` (the member's other device declined) is not the member's decline here.
    @Test func aDeclineElsewhereIsReportedAndADeclineHereIsAHangUp() async throws {
        let signalling = FakeSignalling()
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock)
        let c = coordinator(m)
        c.start()
        signalling.deliver(offer())
        await clock.runCurrent()
        await settle()
        let uuid = try #require(kit.uuid)
        signalling.deliver(.end(callId: callId, reason: "decline"))
        await clock.runCurrent()
        await settle()
        #expect(kit.events.last == .ended(uuid, .declinedElsewhere))
        #expect(kit.actions.isEmpty)
        c.stop()

        let kit2 = FakeKit()
        let signalling2 = FakeSignalling()
        let m2 = CallMachine(signalling: signalling2, engines: engines, clock: clock)
        let c2 = CallKitCoordinator(
            machine: m2, provider: kit2, control: kit2, audio: audio, tones: tones, clock: clock, isForeground: { true }
        )
        kit2.delegate = c2
        c2.start()
        signalling2.deliver(offer())
        await clock.runCurrent()
        await settle()
        let uuid2 = try #require(kit2.uuid)
        m2.decline()
        await clock.runCurrent()
        await settle()
        #expect(kit2.actions == [.end(uuid2)])
        c2.stop()
    }

    @Test func aHangUpCallKitRefusesIsReportedAsItIs() async throws {
        kit.refuseActions = true
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        let uuid = try #require(kit.uuid)
        c.apply(ended(.hungUp, .incoming))
        await settle()
        #expect(kit.events.last == .ended(uuid, .remoteEnded))
    }

    @Test func anEndedCallIsReportedOnceAndANewCallIsANewUuid() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        let first = try #require(kit.uuid)
        c.apply(ended(.missed, .incoming))
        c.apply(ended(.missed, .incoming))
        #expect(kit.events.filter { if case .ended = $0 { true } else { false } }.count == 1)
        c.apply(state(.incoming, .incoming))
        await settle()
        let second = kit.events.compactMap { e -> UUID? in if case .incoming(let u, _) = e { u } else { nil } }.last
        #expect(second != nil && second != first)
    }

    // MARK: the audio session

    @Test func theAudioSessionIsActivatedOnlyWhenCallKitSaysSo() async throws {
        let c = coordinator(machine())
        c.apply(state(.starting, .outgoing))
        c.apply(state(.calling, .outgoing))
        c.apply(state(.ringing, .outgoing))
        c.apply(state(.connecting, .outgoing))
        c.apply(state(.active, .outgoing))
        await settle()
        #expect(audio.log == ["prepare"], "configured, never activated by the app")
        c.audioDidActivate()
        #expect(audio.log == ["prepare", "activate"])
        c.apply(ended(.hungUp))
        #expect(audio.log == ["prepare", "activate", "callEnded"], "an ended call does not deactivate: CallKit does")
        c.audioDidDeactivate()
        #expect(audio.log == ["prepare", "activate", "callEnded", "deactivate"])
    }

    @Test func theSpeakerIsOnlyWhatTheMemberAsks() {
        let c = coordinator(machine())
        c.apply(state(.active, .outgoing))
        #expect(!audio.log.contains { $0.hasPrefix("speaker") })
        c.setSpeaker(true)
        c.setSpeaker(false)
        #expect(audio.log.suffix(2) == ["speaker(true)", "speaker(false)"])
    }

    @Test func theAudioStateReachesTheCoordinator() {
        let c = coordinator(machine())
        let s = AudioState(route: .bluetooth, available: [.earpiece, .speaker, .bluetooth])
        audio.onStateChange?(s)
        #expect(c.audioState == s)
    }

    // MARK: tones and settings

    @Test func aToneThatPlaysIsNeverRestarted() {
        var begun = 0
        var ended = 0
        let slot = ToneSlot<Player>(begin: { begun += 1; return Player() }, end: { _ in ended += 1 })
        slot.set(false)
        slot.set(true)
        slot.set(true)
        slot.set(true)
        #expect(begun == 1 && slot.isPlaying)
        slot.set(false)
        slot.set(false)
        #expect(ended == 1 && !slot.isPlaying)
        slot.set(true)
        #expect(begun == 2)
    }

    @Test func aToneThatCouldNotStartIsTriedAgain() {
        var attempts = 0
        let slot = ToneSlot<Player>(begin: { attempts += 1; return attempts < 2 ? nil : Player() }, end: { _ in })
        slot.set(true)
        #expect(!slot.isPlaying)
        slot.set(true)
        #expect(slot.isPlaying && attempts == 2)
    }

    @Test func theRingBackIsTwoSecondsOfTwoTonesAndFourOfSilence() throws {
        let wav = RingBackTone.wav()
        #expect(wav.count == 44 + RingBackTone.sampleRate * RingBackTone.cycleSeconds * 2)
        #expect(Array(wav.prefix(4)) == Array("RIFF".utf8))
        func sample(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(wav[44 + 2 * i]) | UInt16(wav[45 + 2 * i]) << 8) }
        let loud = (0..<RingBackTone.sampleRate * RingBackTone.onSeconds).map { abs(Int(sample($0))) }.max() ?? 0
        let silent = (RingBackTone.sampleRate * RingBackTone.onSeconds..<RingBackTone.sampleRate * RingBackTone.cycleSeconds)
            .map { abs(Int(sample($0))) }.max() ?? 0
        #expect(loud > 10_000 && silent == 0)
    }

    @Test func theSettingsKeepCallsOutOfRecentsAndAreAudioOnly() {
        let s = CallKitSettings.standard
        #expect(!s.includesCallsInRecents)
        #expect(s.maximumCallGroups == 1 && s.maximumCallsPerCallGroup == 1)
        #expect(!s.supportsVideo && s.supportsGenericHandles)
        #expect(s.ringtoneSound == "vettid_ringtone.caf")
    }

    #if os(iOS)
    @Test func theProviderConfigurationHasTheSettings() throws {
        let c = CallKitSettings.standard.configuration()
        #expect(!c.includesCallsInRecents)
        #expect(c.maximumCallGroups == 1 && c.maximumCallsPerCallGroup == 1)
        #expect(!c.supportsVideo)
        #expect(c.supportedHandleTypes == [.generic])
        // `ringtoneSound` reads back nil while the sound is not in the test bundle: only the settings' value is asserted (above).
        #expect(c.iconTemplateImageData == nil)
        #expect(c.localizedName == "VettID")
        let uuid = UUID()
        let handle = CXHandle(type: .generic, value: "h")
        let timeouts: [CXAction] = [
            CXStartCallAction(call: uuid, handle: handle), CXAnswerCallAction(call: uuid), CXEndCallAction(call: uuid),
        ]
        #expect(timeouts.allSatisfy { SystemCallKit.endsCallOnTimeout($0) })
        #expect(!SystemCallKit.endsCallOnTimeout(CXSetMutedCallAction(call: uuid, muted: true)))
        #expect(!SystemCallKit.endsCallOnTimeout(CXPlayDTMFCallAction(call: uuid, digits: "1", type: .singleTone)))
        #expect(CallEnd.allCases.allSatisfy { $0.callKitReason.system.rawValue >= 0 })
        #expect(CallKitEndReason.remoteEnded.system == .remoteEnded && CallKitEndReason.unanswered.system == .unanswered)
        #expect(CallKitEndReason.declinedElsewhere.system == .declinedElsewhere)
        #expect(CallKitEndReason.answeredElsewhere.system == .answeredElsewhere && CallKitEndReason.failed.system == .failed)
    }
    #endif
}
