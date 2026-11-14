import Foundation
import Observation

/// Maps between the call machine and CallKit, with the app in the foreground (no PushKit yet; no call screens).
///
/// - The member's actions in CallKit's screen (answer, end, mute) go to the machine.
/// - The machine's states go to CallKit: an incoming call is reported (only while the app is in the foreground), an outgoing call
///   is started, and its connecting and connection are reported; an end is reported with its reason, or, when the member ended
///   the call here, asked of CallKit as a hang-up.
/// - The audio session is the app's only between CallKit's activation and deactivation; the coordinator never activates it.
/// - The ring-back tone plays (by the app: CallKit plays none) while the outgoing call rings, and only once CallKit has given the
///   audio session. CallKit plays the ringtone of an incoming call; the app plays it only when CallKit could not show the call.
///
/// An incoming call that arrives while the app is not in the foreground is not reported to CallKit (that needs PushKit, a later
/// change): the machine rings it as before and the coordinator does nothing for it.
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
        var connectionId: String
        var direction: CallDirection
        var callId: String?
        var party: CallParty
        /// CallKit knows this call (an incoming call reported while in front, or an outgoing call).
        var kit = true
        var answerTold = false
        var connectedTold = false
        var muted = false
        var over = false
        var endedInKit = false
        var ringing = false
    }

    @ObservationIgnored private var current: Tracked?
    @ObservationIgnored private var audioActive = false
    @ObservationIgnored private var observing = true
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

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

    /// Follows the machine's state. Call once.
    package func start() { observe() }

    package func stop() {
        observing = false
        for t in tasks { t.cancel() }
        tasks.removeAll()
        tones.ringBack(false)
        tones.ringtone(false)
    }

    /// The speaker, only when the member asks; false returns to the headset or the earpiece.
    package func setSpeaker(_ on: Bool) { audio.setSpeaker(on) }

    private func observe() {
        guard observing else { return }
        let s = withObservationTracking { machine.state } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(s)
    }

    // MARK: the machine's state to CallKit

    func apply(_ state: CallState) {
        switch state {
        case .idle: break
        case .live(let l): live(l)
        case .ended(let e): ended(e)
        }
    }

    private func live(_ l: CallState.Live) {
        // States may be merged by the observation: a different call id is a different call.
        if current == nil || current?.over == true || (current?.callId != nil && l.callId != nil && current?.callId != l.callId) {
            begin(l)
        }
        guard var c = current else { return }
        if c.callId == nil { c.callId = l.callId }
        current = c
        // Answered (anywhere): the app's own ringtone, if it plays, stops.
        if c.direction == .incoming, l.phase != .incoming { tones.ringtone(false) }
        guard c.kit else { return }
        phaseReports(l, c)
        current?.ringing = l.phase == .ringing
        if l.muted != c.muted {
            current?.muted = l.muted
            send(.mute(c.uuid, l.muted))
        }
        updateTones()
    }

    private func phaseReports(_ l: CallState.Live, _ c: Tracked) {
        switch l.phase {
        case .starting, .calling, .ringing, .incoming: break
        case .connecting: toldAnswered()
        case .active:
            toldAnswered()
            if c.direction == .outgoing, !c.connectedTold {
                current?.connectedTold = true
                provider.reportOutgoingCall(uuid: c.uuid, connectedAt: clock.now())
            }
        }
    }

    private func begin(_ l: CallState.Live) {
        var c = Tracked(connectionId: l.connectionId, direction: l.direction, callId: l.callId, party: party(l.connectionId))
        audio.prepare()
        switch l.direction {
        case .outgoing:
            send(.start(c.uuid, handle: c.party.handle))
        case .incoming:
            if isForeground() {
                report(c)
            } else {
                c.kit = false
            }
        }
        current = c
    }

    private func report(_ c: Tracked) {
        let update = CallKitUpdate(handle: c.party.handle, name: c.party.name)
        let uuid = c.uuid
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await provider.reportNewIncomingCall(uuid: uuid, update: update)
            guard current?.uuid == uuid, current?.over == false, result != .reported else { return }
            current?.kit = false
            // CallKit rang nothing: the app does, unless the member's own settings (Do Not Disturb, a block list) stopped the call.
            if result == .failed { tones.ringtone(true) }
        })
    }

    /// An incoming call answered in the app's own screen: CallKit is told, so that it starts the audio.
    private func toldAnswered() {
        guard let c = current, c.direction == .incoming, !c.answerTold else { return }
        current?.answerTold = true
        send(.answer(c.uuid))
    }

    private func ended(_ e: CallState.Ended) {
        guard var c = current, !c.over, c.connectionId == e.connectionId else { return }
        c.over = true
        current = c
        updateTones()
        tones.ringtone(false)
        guard c.kit, !c.endedInKit else { return }
        let uuid = c.uuid
        let report = { [clock, provider] in provider.reportCall(uuid: uuid, endedAt: clock.now(), reason: e.reason.callKitReason) }
        if e.reason.endedHere {
            tasks.append(Task { @MainActor [weak self] in
                // If CallKit refuses the hang-up (it no longer knows the call), the end is reported as it is.
                do { try await self?.control.request(.end(uuid)) } catch { report() }
            })
        } else {
            report()
        }
    }

    private func send(_ action: CallKitAction) {
        tasks.append(Task { @MainActor [weak self] in try? await self?.control.request(action) })
    }

    /// The ring-back plays while the outgoing call rings and the audio session is CallKit's; CallKit plays an incoming ringtone.
    private func updateTones() {
        let ringBack = audioActive && current?.ringing == true && current?.over == false && current?.direction == .outgoing
        tones.ringBack(ringBack)
    }

    // MARK: CallKit to the machine

    package func performStart(uuid: UUID) -> Bool {
        guard let c = current, c.uuid == uuid, c.direction == .outgoing, !c.over else { return false }
        provider.reportCall(uuid: uuid, updated: CallKitUpdate(handle: c.party.handle, name: c.party.name))
        provider.reportOutgoingCall(uuid: uuid, startedConnectingAt: clock.now())
        return true
    }

    package func performAnswer(uuid: UUID) -> Bool {
        guard let c = current, c.uuid == uuid, c.direction == .incoming, !c.over else { return false }
        current?.answerTold = true
        tones.ringtone(false)
        machine.answer()
        return true
    }

    package func performEnd(uuid: UUID) -> Bool {
        guard let c = current, c.uuid == uuid else { return false }
        if !c.over {
            current?.endedInKit = true
            // A ringing incoming call is declined, any other call hung up.
            machine.hangUp()
        }
        return true
    }

    package func performMute(uuid: UUID, muted: Bool) -> Bool {
        guard let c = current, c.uuid == uuid, !c.over else { return false }
        current?.muted = muted
        if case .live(let l) = machine.state, l.muted != muted { machine.setMuted(muted) }
        return true
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
        if current?.over == false {
            current?.endedInKit = true
            machine.hangUp()
        }
        audioDidDeactivate()
        tones.ringtone(false)
    }
}
