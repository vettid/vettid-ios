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
}

@MainActor
final class FakeTones: CallTones {
    var ringBackLog: [Bool] = []
    var ringtoneLog: [Bool] = []
    func ringBack(_ on: Bool) { ringBackLog.append(on) }
    func ringtone(_ on: Bool) { ringtoneLog.append(on) }
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
        CallKitCoordinator(
            machine: m, provider: kit, control: kit, audio: audio, tones: tones, clock: clock,
            party: { CallParty(handle: "handle-\($0)", name: "Name of \($0)") }, isForeground: { foreground }
        )
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
        let expected = CallKitUpdate(handle: "handle-conn-1", name: "Name of conn-1")
        #expect(kit.events == [.incoming(uuid, expected)])
        #expect(!expected.hasVideo && !expected.supportsHolding && !expected.supportsGrouping && !expected.supportsUngrouping)
        #expect(!expected.supportsDTMF)
        #expect(kit.actions.isEmpty)
        // The same state again is not a second call.
        c.apply(state(.incoming, .incoming))
        await settle()
        #expect(kit.events.count == 1)
        #expect(tones.ringtoneLog.isEmpty, "CallKit plays the ringtone")
    }

    @Test func anIncomingCallInTheBackgroundIsNotReported() async {
        let c = coordinator(machine(), foreground: false)
        c.apply(state(.incoming, .incoming))
        c.apply(state(.connecting, .incoming))
        c.apply(ended(.peerHungUp, .incoming))
        await settle()
        #expect(kit.events.isEmpty && kit.actions.isEmpty)
    }

    @Test func anIncomingCallCallKitCouldNotShowRingsInTheAppUnlessTheMemberFilteredIt() async {
        kit.incomingResult = .failed
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        #expect(tones.ringtoneLog == [true])
        c.apply(state(.connecting, .incoming))
        #expect(tones.ringtoneLog == [true, false], "answered: the app's ringtone stops")
        #expect(kit.actions.isEmpty, "and CallKit, which does not know the call, is not told")

        let other = FakeKit()
        other.incomingResult = .filtered
        let tones2 = FakeTones()
        let c2 = CallKitCoordinator(
            machine: machine(), provider: other, control: other, audio: audio, tones: tones2, clock: clock,
            party: { CallParty(handle: $0, name: $0) }, isForeground: { true }
        )
        c2.apply(state(.incoming, .incoming))
        await settle()
        #expect(tones2.ringtoneLog.isEmpty)
    }

    @Test func everyPhaseOfAnOutgoingCallGoesToCallKit() async throws {
        let c = coordinator(machine())
        c.apply(state(.starting, .outgoing))
        await settle()
        let uuid = try #require(kit.uuid)
        #expect(kit.actions == [.start(uuid, handle: "handle-conn-1")])
        #expect(audio.log == ["prepare"])

        // CallKit performs the start: the name and the connecting.
        #expect(c.performStart(uuid: uuid))
        #expect(kit.events == [.updated(uuid, CallKitUpdate(handle: "handle-conn-1", name: "Name of conn-1")), .connecting(uuid)])

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

    /// The reasons CallKit is told, and for which the member's own end is asked of CallKit as a hang-up.
    struct Row { let end: CallEnd, reason: CallKitEndReason, here: Bool }

    static let reasons: [Row] = [
        Row(end: .hungUp, reason: .remoteEnded, here: true),
        Row(end: .peerHungUp, reason: .remoteEnded, here: false),
        Row(end: .declined, reason: .remoteEnded, here: false),
        Row(end: .declinedHere, reason: .declinedElsewhere, here: true),
        Row(end: .busy, reason: .remoteEnded, here: false),
        Row(end: .noAnswer, reason: .unanswered, here: false),
        Row(end: .missed, reason: .unanswered, here: false),
        Row(end: .answeredElsewhere, reason: .answeredElsewhere, here: false),
        Row(end: .unavailable, reason: .failed, here: false),
        Row(end: .ownVaultBusy, reason: .failed, here: false),
        Row(end: .callsOff, reason: .failed, here: false),
        Row(end: .ownerCheckRequired, reason: .failed, here: false),
        Row(end: .notSupported, reason: .failed, here: false),
        Row(end: .noAddress, reason: .failed, here: false),
        Row(end: .couldNotConnect, reason: .failed, here: false),
        Row(end: .connectionLost, reason: .failed, here: false),
        Row(end: .notEncrypted, reason: .failed, here: false),
        Row(end: .locked, reason: .failed, here: true),
        Row(end: .failed, reason: .failed, here: false),
    ]
    @Test func everyEndReasonIsMapped() {
        #expect(Self.reasons.count == CallEnd.allCases.count)
        for row in Self.reasons {
            let (end, reason, here) = (row.end, row.reason, row.here)
            #expect(end.callKitReason == reason, "\(end)")
            #expect(end.endedHere == here, "\(end)")
        }
    }

    @Test func everyEndReasonReachesCallKit() async throws {
        for row in Self.reasons {
            let (end, reason, here) = (row.end, row.reason, row.here)
            let kit = FakeKit()
            let c = CallKitCoordinator(
                machine: machine(), provider: kit, control: kit, audio: audio, tones: tones, clock: clock,
                party: { CallParty(handle: $0, name: $0) }, isForeground: { true }
            )
            c.apply(state(.active, .incoming))
            await settle()
            let uuid = try #require(kit.uuid)
            c.apply(ended(end, .incoming))
            await settle()
            if here {
                #expect(kit.actions.last == .end(uuid), "\(end): asked of CallKit as a hang-up")
                #expect(kit.events.allSatisfy { if case .ended = $0 { false } else { true } })
            } else {
                #expect(kit.events.last == .ended(uuid, reason), "\(end)")
            }
        }
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
        #expect(audio.log == ["prepare", "activate"], "an ended call does not deactivate: CallKit does")
        c.audioDidDeactivate()
        #expect(audio.log == ["prepare", "activate", "deactivate"])
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
        #expect(CallEnd.allCases.allSatisfy { $0.callKitReason.system.rawValue >= 0 })
        #expect(CallKitEndReason.remoteEnded.system == .remoteEnded && CallKitEndReason.unanswered.system == .unanswered)
        #expect(CallKitEndReason.declinedElsewhere.system == .declinedElsewhere)
        #expect(CallKitEndReason.answeredElsewhere.system == .answeredElsewhere && CallKitEndReason.failed.system == .failed)
    }
    #endif
}
