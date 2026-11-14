import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// What the calls need of the app's vault; the app's wiring gives it from the vault manager. Mirrors vettid-android `CallVault`.
@MainActor
package protocol CallVault: AnyObject {
    /// The vault's call messages (the gateway over the open vault's client).
    var gateway: any CallGateway { get }

    /// Whether the vault is open on this phone: the current value first, then every change. A lock pending counts as locked.
    func unlockedChanges() -> AsyncStream<Bool>

    /// True while the release-update screen covers the app: no screen could answer a call, so none rings.
    var updateShowing: Bool { get }

    /// The fingerprint of [connectionId]'s pinned identity key, as the connection's details show it; nil if unknown.
    func fingerprint(_ connectionId: String) async -> String?

    /// The name the app shows for [connectionId]; nil if it has none.
    func name(_ connectionId: String) -> String?

    /// The connection's first name, for the texts that name it ("so Sam can hear you"); nil if none.
    func firstName(_ connectionId: String) -> String?

    /// Reads the app's connections again (an offer can be handled before the list has been read after an unlock).
    func refreshConnections() async

    /// Something changed that may make the vault answer where it refused before (the daily check was done, a vault operation
    /// succeeded): if it is not yet known whether the vault has calls, it is asked again.
    func rechecks() -> AsyncStream<Void>
}

extension CallVault {
    package var updateShowing: Bool { false }
}

/// What is known beyond one call, for the diagnostics view and the phone tests: counts only, nothing else.
public struct CallsDiagnostics: Equatable, Sendable {
    /// Offers and answers that failed their checks since the process started.
    public var refused = 0
    /// Of [refused], the ones where something failed (the vault client, the relay) rather than a check.
    public var errors = 0
    /// Calls left live in the vault by an earlier run of the app, ended at unlock.
    public var staleEnded = 0
    /// How often the listening to the vault's call events had to be started again (expected: 0).
    public var listenRestarts = 0
    /// The `call.list` entries the last read skipped (they did not read).
    public var listSkipped = 0
}

/// Calls in the app: the one ``CallMachine`` of the process and what goes on around a call (CALLS-PLAN 0.1.1 C1). Mirrors
/// vettid-android `CallsController`, C1 form 1 only (so no keep-alives, no permissions, no form 2 sweep: see the notes).
///
/// - **Whether there are calls.** After every unlock the vault is asked for its call list: an answer means calls
///   (``CallAvailability/ready``), `unsupported_type` means none (``CallAvailability/notInVault``).
/// - **Stale calls.** The vault of S10 has no timer and no liveness check: a call whose app died stays live there (and the vault
///   busy) for up to 12 hours. With that same list, every call the vault still holds live while this app has none is ended.
/// - **The microphone.** No call is placed or answered without the permission (``microphonePrompt``).
/// - **Around a call.** The end of a call when the vault locks (``endCallBeforeLock()``) and after 12 hours.
///
/// The audio session, the ring-back and the ringtone are the ``CallKitCoordinator``'s on iOS, built on ``machine``.
@MainActor
@Observable
package final class CallsController {
    /// The one machine, for the CallKit coordinator and the call screens.
    @ObservationIgnored package let machine: CallMachine
    /// The call, for the call screens.
    package var state: CallState { machine.state }

    /// Whether the vault's release has calls; nil until it has been asked since the last unlock.
    private var supported: Bool?
    /// The gate's state: our own screen first, or Settings (nil when no screen is asked for).
    package private(set) var microphonePrompt: MicrophonePrompt?
    /// Calls ended at unlock because the vault still held them live.
    package private(set) var staleEnded = 0
    /// The `call.list` entries the last read skipped.
    package private(set) var listSkipped = 0

    @ObservationIgnored private let vault: any CallVault
    @ObservationIgnored private let signalling: VaultCallSignalling
    @ObservationIgnored private let microphone: any MicrophonePermission
    @ObservationIgnored private let clock: any CallClock
    @ObservationIgnored private let performAnswer: @MainActor () -> Void
    @ObservationIgnored private let openFlag: OpenFlag
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var probeGeneration = 0
    @ObservationIgnored private var longCall: Task<Void, Never>?
    @ObservationIgnored private var microphoneAsk: Task<Void, Never>?

    /// How many call-list entries one read asks for (the vault keeps the latest 200).
    package static let historyLimit = CallLimits.maxListLimit
    /// The longest a call lasts: the vault stops counting a call as live 12 hours after its answer, and the frame cipher's nonce
    /// must not wrap either (CALL-MEDIA.md §6).
    package static let maxCall: Duration = .seconds(12 * 3600)
    /// How long an offer waits for an unlock that is just completing before it is dropped.
    package static let unlockWait: Duration = .seconds(10)
    /// The longest ``endCallBeforeLock()`` waits for the hang-up to go (the lock hook's budget in the data layer is the same).
    package static let lockWait: Duration = .seconds(2)
    private static let probeAttempts = 3
    private static let probeRetry: Duration = .seconds(2)
    private static let pollEvery: Duration = .milliseconds(50)
    private static let unsupported = "unsupported_type"

    /// [answering]: what answering the ringing call does (the CallKit coordinator's `answer()` in the app); the machine's own
    /// answer when nil.
    package init(
        vault: any CallVault, engines: any MediaEngineFactory, microphone: any MicrophonePermission,
        clock: any CallClock = SystemCallClock(), timings: CallTimings = CallTimings(),
        config: @escaping @MainActor () -> MediaConfig = { MediaConfig() }, answering: (@MainActor () -> Void)? = nil
    ) {
        self.vault = vault
        self.microphone = microphone
        self.clock = clock
        let flag = OpenFlag()
        openFlag = flag
        signalling = VaultCallSignalling(
            gateway: vault.gateway, pinned: { await vault.fingerprint($0) }, suites: engines.suites,
            refreshConnections: { await vault.refreshConnections() },
            // An offer waits a moment for an unlock that is completing; none comes: it does not ring.
            mayRing: { [vault, clock] in
                guard !vault.updateShowing else { return false }
                if flag.isOpen { return true }
                return await Self.waitForUnlock(flag, clock)
            },
            clock: clock
        )
        let m = CallMachine(signalling: signalling, engines: engines, clock: clock, timings: timings, config: config)
        machine = m
        performAnswer = answering ?? { m.answer() }
        let transitions = m.transitions()
        tasks.append(Task { [weak self] in
            for await t in transitions { self?.around(t) }
        })
        let unlocked = vault.unlockedChanges()
        tasks.append(Task { [weak self] in
            for await isOpen in unlocked {
                guard let self else { return }
                unlockChanged(isOpen)
            }
        })
        let rechecks = vault.rechecks()
        tasks.append(Task { [weak self] in
            for await _ in rechecks {
                guard let self else { return }
                if openFlag.isOpen, supported == nil, !probing { startProbe() }
            }
        })
    }

    /// Stops everything: the machine too. The tasks hold the controller until this is called.
    package func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        probeTask?.cancel()
        longCall?.cancel()
        microphoneAsk?.cancel()
        machine.stop()
    }

    /// Whether the conversation can show a call button, and why not.
    package var availability: CallAvailability {
        switch supported {
        case nil: .unknown
        case false?: .notInVault
        case true?: isLive ? .inCall : .ready
        }
    }

    private var isLive: Bool {
        if case .live = machine.state { return true }
        return false
    }

    /// What is known beyond one call (counts only).
    package var diagnostics: CallsDiagnostics {
        CallsDiagnostics(
            refused: signalling.refused, errors: signalling.errors, staleEnded: staleEnded, listenRestarts: machine.listenRestarts,
            listSkipped: listSkipped
        )
    }

    // MARK: the member

    /// Calls [connectionId]. Nothing happens unless ``availability`` is ``CallAvailability/ready``; without the microphone the
    /// gate asks for the screen instead (``microphonePrompt``).
    package func call(_ connectionId: String) {
        guard availability == .ready else { return }
        gate(.call(connectionId: connectionId))
    }

    /// Answers the ringing call, behind the same gate.
    package func answer() {
        guard case .live(let l) = machine.state, l.phase == .incoming else { return }
        gate(.answer)
    }

    package func decline() { machine.decline() }

    package func hangUp() { machine.hangUp() }

    package func setMuted(_ muted: Bool) { machine.setMuted(muted) }

    package func dismiss() { machine.dismiss() }

    /// The connection's name for the call screens.
    package func screenName(_ connectionId: String) -> String? { vault.name(connectionId) }

    /// The connection's first name for the call screens' lines that use it.
    package func screenFirstName(_ connectionId: String) -> String? { vault.firstName(connectionId) }

    // MARK: the microphone

    /// The gate's screen with its texts, or nil.
    package var microphoneScreen: MicrophoneScreen? {
        guard let p = microphonePrompt else { return nil }
        return MicrophoneScreen(p, firstName: connection(of: p).flatMap { vault.firstName($0) })
    }

    private func connection(of p: MicrophonePrompt) -> String? {
        switch p {
        case .explain(let a), .blocked(let a):
            switch a {
            case .call(let id): return id
            case .answer: if case .live(let l) = machine.state { return l.connectionId } else { return nil }
            }
        }
    }

    private func gate(_ action: MicrophoneAction) {
        switch microphone.status {
        case .granted: perform(action)
        case .undetermined: microphonePrompt = .explain(action)
        case .denied: microphonePrompt = .blocked(action)
        }
    }

    private func perform(_ action: MicrophoneAction) {
        switch action {
        case .call(let id): if availability == .ready { machine.call(id) }
        case .answer: performAnswer()
        }
    }

    /// "Allow" on our own screen: the system's prompt, and what was held back goes on when the member allows it. A member who
    /// refuses there sees nothing more now; the next call or answer finds the microphone denied and shows the blocked screen
    /// (chosen; not in the spec).
    package func allowMicrophone() {
        guard case .explain(let action)? = microphonePrompt else { return }
        microphonePrompt = nil
        microphoneAsk?.cancel()
        microphoneAsk = Task { [weak self] in
            guard let self else { return }
            let allowed = await microphone.request()
            guard allowed, !Task.isCancelled, openFlag.isOpen else { return }
            perform(action)
        }
    }

    /// "Not now" and "Close": the screen goes, the call is not placed; a ringing call goes on ringing.
    package func closeMicrophonePrompt() { microphonePrompt = nil }

    // MARK: the vault

    private func unlockChanged(_ isOpen: Bool) {
        openFlag.isOpen = isOpen
        probeTask?.cancel()
        probeTask = nil
        probing = false
        if isOpen { startProbe() } else { locked() }
    }

    private func locked() {
        supported = nil
        listSkipped = 0
        microphonePrompt = nil
        microphoneAsk?.cancel()
        machine.vaultLocking()
        // Nothing of a call is kept for the next unlock: an ended call's line ("... your vault was locked") would show then,
        // long after.
        machine.dismiss()
    }

    /// Ends a live call and waits until its `call.end` is with the relay, before the vault is locked: a locked vault collects
    /// nothing, so a hang-up sent after the lock would wait in its mailbox while the other member listens to silence. At most
    /// ``lockWait``; the lock happens whatever becomes of this (the data layer's lock sequence bounds its hooks the same way).
    /// The hang-up itself is allowed while a lock is pending (``LockTimeUse``'s call end).
    package func endCallBeforeLock() async {
        let live = isLive
        // Nothing to end and no hang-up on its way: no wait. A hang-up still being sent is waited for also when the call itself
        // is already over on this phone (the member hung up and locked at once).
        if !live && machine.pendingEnds == 0 { return }
        if live { machine.vaultLocking() }
        let deadline = clock.elapsedMs() + Self.lockWait.wholeMilliseconds
        while isLive || machine.pendingEnds > 0 {
            if clock.elapsedMs() >= deadline { return }
            do { try await clock.sleep(for: Self.pollEvery) } catch { return }
        }
    }

    private func startProbe() {
        probeGeneration += 1
        let generation = probeGeneration
        probing = true
        probeTask = Task { [weak self] in
            await self?.probe(generation)
            if let self, probeGeneration == generation { probing = false }
        }
    }

    /// `call.list`: an answer means calls; `unsupported_type`, none; any other refusal (the daily check is due, ...) leaves it
    /// not known, and a failure is tried again twice.
    private func probe(_ generation: Int) async {
        supported = nil
        for attempt in 0..<Self.probeAttempts {
            do {
                let list = try await vault.gateway.list(limit: Self.historyLimit)
                guard !Task.isCancelled, generation == probeGeneration, openFlag.isOpen else { return }
                supported = true
                listSkipped = list.skipped
                await endStale(list.calls)
                return
            } catch is CancellationError {
                return
            } catch let e as VaultOpError {
                guard !Task.isCancelled, generation == probeGeneration else { return }
                if e.code == Self.unsupported { supported = false }
                return
            } catch {
                if attempt + 1 == Self.probeAttempts { return }
                do { try await clock.sleep(for: Self.probeRetry * (attempt + 1)) } catch { return }
            }
        }
    }

    /// Calls the vault still holds live while this app has none: left by a run of the app that ended during a call. Ended there,
    /// or the vault answers every call `busy` for up to 12 hours (CALLS-PLAN §6.1 V3). A ringing call is left alone while it
    /// could still be ringing (``CallHistoryRows/ringStale``). At S10 `call.list` gives neither the call's device nor its `exp`,
    /// so "stale" is judged by this phone's clock against `started_at`, and a live record is taken to be this device's (right
    /// while one app is the member's only call device; Android has the same limit).
    private func endStale(_ records: [CallRecord]) async {
        if isLive { return }
        let t = clock.now()
        for r in records {
            let ringing = r.state == "ringing"
            let stale: Bool
            switch r.state {
            case "active": stale = true
            case "ringing":
                let age = CallHistoryRows.time(r.startedAt).map { t.timeIntervalSince($0) }
                stale = age.map { $0 > CallHistoryRows.ringStaleSeconds } ?? true
            default: stale = false
            }
            guard stale else { continue }
            let reason = ringing && r.direction == "out" ? CallReason.timeout : CallReason.failed
            do {
                try await vault.gateway.end(r.callId, reason: reason)
                staleEnded += 1
            } catch {
                // Not ended: the next unlock tries again.
            }
            if Task.isCancelled || !openFlag.isOpen { return }
        }
    }

    // MARK: around a call

    private func around(_ t: CallTransition) {
        guard case .live(let l) = t.state, l.phase == .active else {
            longCall?.cancel()
            longCall = nil
            return
        }
        guard longCall == nil else { return }
        let seq = t.seq
        longCall = Task { [weak self] in
            guard let self else { return }
            do { try await clock.sleep(for: Self.maxCall) } catch { return }
            machine.hangUp(seq: seq)
        }
    }

    // MARK: the history

    /// The calls with [connectionId], newest first; empty when there are none or they cannot be read.
    package func history(_ connectionId: String) async -> CallHistory {
        var list: CallList?
        if supported == true {
            list = try? await vault.gateway.list(limit: Self.historyLimit)
        }
        if let list { listSkipped = list.skipped }
        return CallHistoryRows.history(list, connectionId: connectionId, now: clock.now())
    }

    // MARK: the unlock

    /// Whether the vault is open (a box the signalling's closure can hold before the controller is made).
    @MainActor
    private final class OpenFlag {
        var isOpen = false
    }

    /// Waits up to ``unlockWait`` for the vault to open (the clock's, so virtual in the tests).
    private static func waitForUnlock(_ flag: OpenFlag, _ clock: any CallClock) async -> Bool {
        let deadline = clock.elapsedMs() + unlockWait.wholeMilliseconds
        while !flag.isOpen {
            if clock.elapsedMs() >= deadline { return false }
            do { try await clock.sleep(for: pollEvery) } catch { return false }
        }
        return true
    }
}
