import Foundation
import Observation
import VettIDData

/// What the app gives the calls that lives as long as the process: the media engine and its audio session, CallKit, the
/// ring-back and the microphone. Made once, when the vault is first opened (not at launch), and kept.
package struct CallsParts {
    package var engines: any MediaEngineFactory
    package var audio: any CallAudioSession
    package var kit: any CallKitProviding & CallKitControlling
    /// Gives CallKit's delegate its target: the coordinator of the call logic now running.
    package var attach: @MainActor (any CallKitEvents) -> Void
    package var tones: any CallTones
    package var microphone: any MicrophonePermission
    package var clock: any CallClock

    @MainActor package init(
        engines: any MediaEngineFactory, audio: any CallAudioSession, kit: any CallKitProviding & CallKitControlling,
        attach: @escaping @MainActor (any CallKitEvents) -> Void, tones: any CallTones, microphone: any MicrophonePermission,
        clock: (any CallClock)? = nil
    ) {
        self.engines = engines
        self.audio = audio
        self.kit = kit
        self.attach = attach
        self.tones = tones
        self.microphone = microphone
        self.clock = clock ?? SystemCallClock()
    }
}

/// The call logic of one opening of the vault: the controller and the CallKit coordinator on its machine.
@MainActor
package final class CallsRuntime {
    package let controller: CallsController
    package let coordinator: CallKitCoordinator
    private var tasks: [Task<Void, Never>] = []

    /// [vault]: what the controller asks of the app's vault. [isForeground]: whether an incoming call may be reported to CallKit.
    /// [notLive]: told whenever the call is not live any more (an ending, an idle machine).
    package init(
        vault: any CallVault, parts: CallsParts, isForeground: @escaping @MainActor () -> Bool,
        notLive: @escaping @MainActor () -> Void = {}
    ) {
        let slot = CoordinatorSlot()
        // Answering the ringing call goes through CallKit (which opens the audio), behind the microphone gate.
        let controller = CallsController(
            vault: vault, engines: parts.engines, microphone: parts.microphone, clock: parts.clock,
            answering: { slot.coordinator?.answer() }
        )
        let coordinator = CallKitCoordinator(
            machine: controller.machine, provider: parts.kit, control: parts.kit, audio: parts.audio, tones: parts.tones,
            clock: parts.clock, isForeground: isForeground,
            // CallKit's own Accept goes through the microphone gate: refused, the call keeps ringing and the controller asks.
            mayAnswer: { controller.answerFromCallKit(seq: $0) }
        )
        slot.coordinator = coordinator
        self.controller = controller
        self.coordinator = coordinator
        parts.attach(coordinator)
        coordinator.start()
        // An ending that only reports goes straight back: the conversation's call line says how it ended (owner decision
        // 2026-10-27). One that says what to do, or that something was wrong, keeps its screen until it is closed.
        let transitions = controller.machine.transitions()
        tasks.append(Task { @MainActor [weak controller] in
            for await t in transitions {
                if case .live = t.state { continue }
                // The hang-up of this call is with the relay first (bounded, as before a lock): the collection stops with the call.
                // (It only waits: the end of this call may ring the connection's held offer in the same turn, which a lock's end would hang up.)
                await controller?.waitForPendingEnds()
                // The vault's collection no longer needs to run on in the background (``VaultManager/holdCollection(_:)``).
                notLive()
                guard case .ended(let e) = t.state, !CallTexts.staysOpen(e.reason) else { continue }
                controller?.dismiss()
            }
        })
    }

    @MainActor private final class CoordinatorSlot {
        weak var coordinator: CallKitCoordinator?
    }

    /// Ends a live call and waits (at most ``CallsController/lockWait``) until its hang-up is with the relay, then stops it all: the
    /// machine, the controller, the coordinator (CallKit is told nothing stays "in call"; the audio is let go).
    package func close() async {
        await controller.endCallBeforeLock()
        for t in tasks { t.cancel() }
        tasks.removeAll()
        controller.stop()
        coordinator.stop()
    }
}

/// Calls in the app, over the open vault (vettid-android `CallsModule`): the call logic is built when the vault opens and stopped
/// when it is not open any more (a lock, a sign-out, anything that leaves the open app), so that nothing of a call outlives the
/// vault; and a lock waits, a moment at most, for a live call's hang-up to reach the vault (``VaultManager/onBeforeLock(_:)``).
@MainActor
@Observable
public final class CallsHost {
    /// The call logic of the vault open now; nil while none is open.
    package private(set) var runtime: CallsRuntime?

    @ObservationIgnored private let vault: any CallsAppVault
    @ObservationIgnored private let makeParts: @MainActor () -> CallsParts
    @ObservationIgnored private var parts: CallsParts?
    @ObservationIgnored private let isForeground: @MainActor () -> Bool
    @ObservationIgnored private var following: Task<Void, Never>?
    /// Runtimes built, for the tests of the wiring.
    @ObservationIgnored package private(set) var started = 0

    /// [makeParts]: the engine, CallKit and the rest, made when the vault is first opened.
    package init(
        vault: any CallsAppVault, parts makeParts: @escaping @MainActor () -> CallsParts,
        isForeground: @escaping @MainActor () -> Bool = { true }
    ) {
        self.vault = vault
        self.makeParts = makeParts
        self.isForeground = isForeground
    }

    /// Follows the vault: the calls start when it opens and stop when it does not. Registers the hook of the member's lock. Call
    /// once, at launch.
    public func start() {
        guard following == nil else { return }
        // The lock's own wait, bounded by the data layer's budget as ``CallsController/lockWait`` is.
        vault.onBeforeLock { [weak self] in await self?.runtime?.controller.endCallBeforeLock() }
        // A live call keeps the vault's messages coming while the app is in the background (the `audio` background mode keeps the
        // process): the peer's `call.end` and ICE come through the collection, and the hang-up goes out through the session.
        vault.holdCollection { [weak self] in self?.callIsLive ?? false }
        let opens = vault.unlockedChanges()
        following = Task { @MainActor [weak self] in
            // One change at a time: the call logic of a closed vault is stopped (its hang-up waited for) before another is built.
            for await isOpen in opens {
                guard let self else { return }
                if isOpen { open() } else { await closeRuntime() }
            }
        }
    }

    private func open() {
        guard runtime == nil else { return }
        let p = parts ?? makeParts()
        parts = p
        runtime = CallsRuntime(
            vault: vault, parts: p, isForeground: isForeground, notLive: { [weak vault] in vault?.collectionHoldEnded() }
        )
        started += 1
    }

    private func closeRuntime() async {
        guard let r = runtime else { return }
        // Still the current one while its hang-up is waited for: the lock's own hook asks the same controller.
        await r.close()
        if runtime === r { runtime = nil }
        // No call is live any more: a background that waited for it finishes (a lock in the background, say).
        vault.collectionHoldEnded()
    }

    /// Whether a call is live: the vault's collection goes on in the background meanwhile. A ringing, unanswered incoming call counts
    /// too (it holds the collection with no audio until it is answered or ends: iOS suspends the app soon anyway, and the hold ends with
    /// the ring).
    package var callIsLive: Bool {
        if case .live(_)? = runtime?.controller.state { return true }
        return false
    }

    // MARK: for the screens

    /// Whether the vault's release has calls, and whether a call is going on (nil: no calls, no vault open).
    public var availability: CallAvailability { runtime?.controller.availability ?? .unknown }

    /// Whether a conversation shows a Call button: only when the vault's probe has said it has calls and no call is going on
    /// (owner decision: hidden otherwise).
    public var canCall: Bool { availability == .ready }

    /// A tap on a Call button: the microphone gate first (its screen, ``microphoneScreen``), then the call.
    public func call(_ connectionId: String) { runtime?.controller.call(connectionId) }

    /// The calls with a connection as its conversation shows them (newest first, and whether some could not be shown); empty when
    /// no vault is open or the vault has no calls.
    public func history(_ connectionId: String) async -> CallHistory {
        guard let controller = runtime?.controller else { return CallHistory() }
        return await controller.history(connectionId)
    }

    /// The state the call screen shows.
    package var uiState: CallUiState {
        guard let r = runtime else { return CallUiState() }
        let call = r.controller.state
        let id: String?
        switch call {
        case .idle: id = nil
        case .live(let l): id = l.connectionId
        case .ended(let e): id = e.connectionId
        }
        let audio = r.coordinator.audioState
        return CallUiState(
            call: call,
            // The name as it is known for the screen: never hidden here by the notification setting.
            name: id.flatMap { r.controller.screenName($0) }, firstName: id.flatMap { r.controller.screenFirstName($0) },
            speaker: audio.route == .speaker, canSpeaker: audio.available.contains(.speaker)
        )
    }

    /// The microphone gate's screen with its texts, or nil.
    package var microphoneScreen: MicrophoneScreen? { runtime?.controller.microphoneScreen }

    /// Whether anything of calls is on the screen: a call (or an ending that stays) or the microphone gate.
    public var screenShown: Bool { vault.isOpen && (uiState.showsScreen || microphoneScreen != nil) }

    package func answer() { runtime?.controller.answer() }
    package func decline() { runtime?.controller.decline() }
    package func hangUp() { runtime?.controller.hangUp() }
    package func dismiss() { runtime?.controller.dismiss() }
    package func allowMicrophone() { runtime?.controller.allowMicrophone() }
    package func closeMicrophonePrompt() { runtime?.controller.closeMicrophonePrompt() }

    package func toggleMute() {
        guard let r = runtime, case .live(let l) = r.controller.state else { return }
        r.controller.setMuted(!l.muted)
    }

    package func toggleSpeaker() {
        guard let r = runtime else { return }
        let s = uiState
        if s.canSpeaker { r.coordinator.setSpeaker(!s.speaker) }
    }
}

#if os(iOS)
import UIKit

extension CallsHost {
    /// The calls on the vault manager, with the system's CallKit, ring-back tone and microphone permission. [audio] and [engines]
    /// are the media stack's (`VettIDCallsWebRTC`), made when the vault is first opened.
    public convenience init(
        vault: VaultManager, audio: @escaping @MainActor () -> any CallAudioSession,
        engines: @escaping @MainActor (any CallAudioSession) -> any MediaEngineFactory
    ) {
        self.init(
            vault: ManagerVault(vault),
            parts: {
                let session = audio()
                let kit = SystemCallKit()
                return CallsParts(
                    engines: engines(session), audio: session, kit: kit, attach: { kit.attach($0) }, tones: SystemCallTones(),
                    microphone: SystemMicrophonePermission()
                )
            },
            // An incoming call is reported to CallKit while the app is in front, or only inactive (Control Center, a prompt): not
            // from the background (no PushKit yet).
            isForeground: { UIApplication.shared.applicationState != .background }
        )
    }
}
#endif
