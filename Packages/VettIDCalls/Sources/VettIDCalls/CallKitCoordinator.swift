import Foundation
import Observation
import VettIDData

/// Maps between the call machine and CallKit, with the app in the foreground (no PushKit yet; no call screens).
///
/// **The rule (C1, foreground only): a call that CallKit does not carry never has audio.** It is never placed and never answered:
/// - a refused `CXStartCallAction` ends the call as ``CallEnd/failed``;
/// - a refused `CXAnswerCallAction`, and an answer of a call CallKit did not take (an offer that came while the app was not in
///   front, or one CallKit refused: Do Not Disturb, a block list) is refused: ``answer()`` does nothing, no decline is sent, and
///   the call rings out as missed in VettID's history. A machine answered anyway is ended here at once as failed (`call.end{failed}`).
///   The app plays no ringtone of its own for such a call.
///
/// - The member's actions in CallKit's screen (answer, end, mute) go to the machine.
/// - Every state the machine publishes (``CallMachine/transitions()``, none merged) goes to CallKit: an incoming call is reported
///   (only while the app is in the foreground), an outgoing call is started and reported connecting, and connected when media
///   flows (`active`, not the answer); an end is reported with its reason, or, when it is the member's own act here, asked of
///   CallKit as a hang-up.
/// - The audio session is the app's only between CallKit's activation and deactivation; the coordinator never activates it. An
///   interruption (a cellular call, Siri) arrives as `didDeactivate`, or as an end action.
/// - The ring-back plays (by the app: CallKit plays none) while the outgoing call rings and the session is CallKit's.
/// - When the machine stops (the stream of transitions ends) or ``stop()`` is called, an open CallKit call is reported ended
///   (`failed`) and the audio is let go: nothing stays "in call".
///
/// **Backgrounding is not handled here.** The wiring (part 2, PR 5) owns it: either the `audio` / `voip` `UIBackgroundModes`, or
/// ending the call when the app leaves the foreground. Until then a call does not survive the app being sent to the background.
@MainActor
@Observable
package final class CallKitCoordinator: CallKitEvents {
    /// The route in use and the routes there are, for the call screen.
    package private(set) var audioState = AudioState()

    @ObservationIgnored private let machine: CallMachine
    @ObservationIgnored private let provider: any CallKitProviding
    @ObservationIgnored private let control: any CallKitControlling
    @ObservationIgnored private let audio: any CallAudioSession
    @ObservationIgnored private let tones: any CallTones
    @ObservationIgnored private let party: @MainActor (String) -> CallParty
    @ObservationIgnored private let isForeground: @MainActor () -> Bool
    @ObservationIgnored private let clock: any CallClock

    /// The call CallKit knows, from its first state until the next call.
    private struct Tracked {
        var uuid = UUID()
        /// What CallKit gets as the call's handle: random, of this call only, never the connection's id.
        var handle = UUID().uuidString
        var seq: Int
        var connectionId: String
        var direction: CallDirection
        var party: CallParty
        /// CallKit carries this call: only then does it have audio.
        var kit = true
        var answerTold = false
        var connectedTold = false
        /// The last mute the machine published, and the one CallKit has.
        var machineMuted = false
        var kitMuted = false
        var over = false
        var endedInKit = false
        var ringing = false
        var refused = false
    }

    @ObservationIgnored private var current: Tracked?
    @ObservationIgnored private var audioActive = false
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextTask = 0

    package init(
        machine: CallMachine, provider: any CallKitProviding, control: any CallKitControlling, audio: any CallAudioSession,
        tones: any CallTones, clock: any CallClock = SystemCallClock(), party: @escaping @MainActor (String) -> CallParty,
        isForeground: @escaping @MainActor () -> Bool
    ) {
        self.machine = machine
        self.provider = provider
        self.control = control
        self.audio = audio
        self.tones = tones
        self.clock = clock
        self.party = party
        self.isForeground = isForeground
        audio.onStateChange = { [weak self] s in self?.audioState = s }
    }

    /// Follows the machine: every state it publishes from now on (and a live call, if there is one). Call once.
    package func start() {
        guard consumer == nil else { return }
        let stream = machine.transitions()
        consumer = Task { @MainActor [weak self] in
            for await t in stream {
                guard let self else { return }
                apply(t)
            }
            // The machine was stopped (a lock, a sign-out): nothing may stay open in CallKit.
            if !Task.isCancelled { self?.letGo() }
        }
    }

    package func stop() {
        consumer?.cancel()
        consumer = nil
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
        letGo()
    }

    /// Reports an open CallKit call ended (CallKit then deactivates the session) and resets the audio: the tone, the audio unit
    /// and the session's state, at once, without waiting for CallKit.
    private func letGo() {
        if let c = current, !c.over {
            current?.over = true
            if c.kit, !c.endedInKit { provider.reportCall(uuid: c.uuid, endedAt: clock.now(), reason: .failed) }
        }
        audioActive = false
        tones.ringBack(false)
        audio.didDeactivate()
        audio.callEnded()
    }

    /// The speaker, only when the member asks; false returns to the headset or the earpiece.
    package func setSpeaker(_ on: Bool) { audio.setSpeaker(on) }

    /// The member answers the ringing call in the app's own screen. A call CallKit carries is answered through CallKit (which
    /// opens the audio); any other is declined.
    package func answer() {
        guard let c = current, !c.over, c.direction == .incoming else { return }
        if c.kit {
            current?.answerTold = true
            send(.answer(c.uuid)) { [weak self] in self?.machine.end(.failed, seq: c.seq) }
        }
        // A call CallKit does not carry cannot be answered: nothing else happens, and it rings out as missed.
    }

    // MARK: the machine's states to CallKit

    func apply(_ state: CallState, seq: Int = 0, memberEnded: Bool = false) {
        apply(CallTransition(seq: seq, state: state, memberEnded: memberEnded))
    }

    func apply(_ t: CallTransition) {
        switch t.state {
        case .idle: break
        case .live(let l): live(l, seq: t.seq)
        case .ended(let e): ended(e, seq: t.seq, memberEnded: t.memberEnded)
        }
    }

    private func live(_ l: CallState.Live, seq: Int) {
        if let c = current, !c.over, c.seq != seq { replaced(c) }
        if current == nil || current?.over == true { begin(l, seq: seq) }
        guard let c = current, c.seq == seq else { return }
        if c.direction == .incoming, l.phase != .incoming, l.phase != .starting, !c.kit {
            refuse()
        } else if c.kit {
            phaseReports(l, c)
            current?.ringing = l.phase == .ringing
            muteReports(l, c)
        }
        current?.machineMuted = l.muted
        updateTones()
    }

    /// A machine answered anyway (no screen should) for a call CallKit does not carry has no audio: it is ended here, once, with
    /// `call.end{failed}` (the answer is out, so the caller is told at once, not after its connect timer).
    private func refuse() {
        guard current?.refused == false else { return }
        current?.refused = true
        machine.end(.failed, seq: current?.seq ?? -1)
    }

    /// The tracked call was replaced by another before its end was seen: it is let go in CallKit first.
    private func replaced(_ c: Tracked) {
        current?.over = true
        updateTones()
        if c.kit, !c.endedInKit { provider.reportCall(uuid: c.uuid, endedAt: clock.now(), reason: .failed) }
    }

    private func begin(_ l: CallState.Live, seq: Int) {
        var c = Tracked(seq: seq, connectionId: l.connectionId, direction: l.direction, party: party(l.connectionId))
        audio.prepare()
        switch l.direction {
        case .outgoing:
            let uuid = c.uuid
            send(.start(uuid, handle: c.handle)) { [weak self] in
                // CallKit refused the call: it has no audio, so it is not placed.
                guard self?.current?.uuid == uuid else { return }
                self?.current?.kit = false
                self?.machine.end(.failed, seq: seq)
            }
        case .incoming:
            if isForeground() { report(c) } else { c.kit = false }
        }
        current = c
    }

    private func report(_ c: Tracked) {
        let update = update(c)
        let uuid = c.uuid
        launch { [weak self] in
            guard let self else { return }
            let result = await provider.reportNewIncomingCall(uuid: uuid, update: update)
            // Refused (Do Not Disturb, a block list, an error): respected. The call carries no audio and rings out as missed.
            if result != .reported, current?.uuid == uuid, current?.over == false { current?.kit = false }
        }
    }

    /// The call as CallKit is told: the member's name bidi-isolated, the call's own opaque handle.
    private func update(_ c: Tracked) -> CallKitUpdate { CallKitUpdate(handle: c.handle, name: AccountNames.isolate(c.party.name)) }

    private func phaseReports(_ l: CallState.Live, _ c: Tracked) {
        switch l.phase {
        case .starting, .calling, .ringing, .incoming: break
        case .connecting: toldAnswered()
        case .active:
            toldAnswered()
            // Connected is reported when media flows (`active`), not at the answer.
            if c.direction == .outgoing, !c.connectedTold {
                current?.connectedTold = true
                provider.reportOutgoingCall(uuid: c.uuid, connectedAt: clock.now())
            }
        }
    }

    /// The mute the machine published, when it differs from the last one and from what CallKit has.
    private func muteReports(_ l: CallState.Live, _ c: Tracked) {
        guard l.muted != c.machineMuted, l.muted != c.kitMuted else { return }
        let before = c.kitMuted
        let uuid = c.uuid
        current?.kitMuted = l.muted
        // A refused mute leaves CallKit with what it had.
        send(.mute(uuid, l.muted)) { [weak self] in if self?.current?.uuid == uuid { self?.current?.kitMuted = before } }
    }

    /// An incoming call answered in the app's own screen without ``answer()``: CallKit is told, so that it opens the audio.
    private func toldAnswered() {
        guard let c = current, c.direction == .incoming, !c.answerTold else { return }
        current?.answerTold = true
        send(.answer(c.uuid)) { [weak self] in self?.machine.end(.failed, seq: c.seq) }
    }

    private func ended(_ e: CallState.Ended, seq: Int, memberEnded: Bool) {
        guard var c = current, c.seq == seq, !c.over else { return }
        c.over = true
        current = c
        updateTones()
        audio.callEnded()
        guard c.kit, !c.endedInKit else { return }
        let uuid = c.uuid
        let reason = e.reason.callKitReason
        let report: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            provider.reportCall(uuid: uuid, endedAt: clock.now(), reason: reason)
        }
        if memberEnded {
            // The member's own act here: asked of CallKit as a hang-up (reported as it is if CallKit refuses).
            send(.end(uuid), onRefused: report)
        } else {
            report()
        }
    }

    /// Asks CallKit for [action]; [onRefused] runs if it refuses.
    private func send(_ action: CallKitAction, onRefused: @escaping @MainActor () -> Void) {
        launch { [weak self] in
            do { try await self?.control.request(action) } catch { onRefused() }
        }
    }

    /// The handle CallKit has for the tracked call (for the tests).
    var trackedHandle: String? { current?.handle }

    /// Tasks still running (for the tests).
    var pendingTasks: Int { tasks.count }

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        let id = nextTask
        nextTask += 1
        tasks[id] = Task { @MainActor [weak self] in
            await body()
            self?.tasks[id] = nil
        }
    }

    /// The ring-back plays while the outgoing call rings and the audio session is CallKit's.
    private func updateTones() {
        tones.ringBack(audioActive && current?.ringing == true && current?.over == false && current?.direction == .outgoing)
    }

    // MARK: CallKit to the machine

    package func performStart(uuid: UUID) -> Bool {
        guard let c = current, c.uuid == uuid, c.direction == .outgoing, !c.over else { return false }
        provider.reportCall(uuid: uuid, updated: update(c))
        provider.reportOutgoingCall(uuid: uuid, startedConnectingAt: clock.now())
        return true
    }

    package func performAnswer(uuid: UUID) -> Bool {
        guard let c = current, c.uuid == uuid, c.direction == .incoming, !c.over, c.kit else { return false }
        current?.answerTold = true
        machine.answer()
        return true
    }

    /// Fulfilled for any call, tracked or not: ending a call CallKit holds that the app has let go (a replaced call) is harmless.
    package func performEnd(uuid: UUID) -> Bool {
        if let c = current, c.uuid == uuid, !c.over {
            current?.endedInKit = true
            // A ringing incoming call is declined, any other call hung up (the call CallKit names, not a newer one).
            machine.hangUp(seq: c.seq)
        }
        return true
    }

    package func performMute(uuid: UUID, muted: Bool) -> Bool {
        guard let c = current, c.uuid == uuid, !c.over else { return false }
        current?.kitMuted = muted
        if case .live(let l) = machine.state, l.muted != muted { machine.setMuted(muted) }
        return true
    }

    /// An action for [uuid] timed out: the tracked call, if it is that one, ends as failed. CallKit is told of the end by the
    /// transition, as for any end (a report for a call it has already ended is harmless). A call still ringing here is not ended by
    /// a failure: it rings out as missed.
    package func actionTimedOut(uuid: UUID) {
        guard let c = current, c.uuid == uuid, !c.over else { return }
        machine.end(.failed, seq: c.seq)
    }

    // MARK: the audio session

    package func audioDidActivate() {
        audioActive = true
        audio.didActivate()
        updateTones()
    }

    package func audioDidDeactivate() {
        audioActive = false
        updateTones()
        audio.didDeactivate()
    }

    package func providerDidReset() {
        if let c = current, c.kit, !c.over {
            current?.endedInKit = true
            machine.hangUp(seq: c.seq)
        }
        audioDidDeactivate()
    }
}
