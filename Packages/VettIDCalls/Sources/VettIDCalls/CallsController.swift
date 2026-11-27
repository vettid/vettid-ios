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

    /// True while the daily owner check is due or held, or its screen covers the app (owner decision 2026-11-18): no call
    /// rings on this phone; another device may still answer it.
    var ownerCheckShowing: Bool { get }

    /// The fingerprint of [connectionId]'s pinned identity key, as the connection's details show it; nil if unknown.
    func fingerprint(_ connectionId: String) async -> String?

    /// (C2) [connectionId]'s pinned identity key itself (32 bytes), the key ``fingerprint(_:)`` is of; nil if unknown. A form 2
    /// call names it (VAULT-MESSAGING 0.88.16 §10.10).
    func identityKey(_ connectionId: String) async -> [UInt8]?

    /// (C2) This device's id in the vault (its own `device.list` entry): the stale sweep's own calls.
    func deviceId() async -> String?

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
    package var ownerCheckShowing: Bool { false }
    package func identityKey(_ connectionId: String) async -> [UInt8]? { nil }
    package func deviceId() async -> String? { nil }
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

/// Calls in the app: the one ``CallMachine`` of the process and what goes on around a call (CALLS-PLAN C1, C2). Mirrors
/// vettid-android `CallsController` (the call permissions are not here yet).
///
/// - **Whether there are calls.** After every unlock the vault is asked for its call list: an answer means calls
///   (``CallAvailability/ready``), `unsupported_type` means none (``CallAvailability/notInVault``). (C2) The same answer says
///   whether the vault is C2 (`v: 2` with `now`, VAULT-MESSAGING §10.10 "Mixed releases"): form 2 and keep-alives then.
/// - **Keep-alives** (C2, "Liveness"): `call.keepalive` once the call is active on this device, then every 30 s.
/// - **Stale calls.** The vault of S10 has no timer and no liveness check: a call whose app died stays live there (and the vault
///   busy) for up to 12 hours. With that same list, every call the vault still holds live while this app has none is ended;
///   against a C2 vault only this device's own, by `device_id`, `exp` and the vault's `now`.
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
    private var supported: Bool? { didSet { openFlag.supported = supported } }
    /// (C2) Whether the vault is C2 (`call.list` `v: 2`), read again after each unlock: nothing is cached across one.
    private var vaultC2: Bool { get { openFlag.vaultC2 } set { openFlag.vaultC2 = newValue } }
    /// (C2) The keep-alives of the active call: one loop per call id.
    @ObservationIgnored private var keepalive: (callId: String, task: Task<Void, Never>)?
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
    @ObservationIgnored private var recheckPending = false
    @ObservationIgnored private var microphoneAsking: MicrophoneAction?
    @ObservationIgnored private var probeGeneration = 0
    @ObservationIgnored private var longCall: Task<Void, Never>?
    /// Watches a call ringing here for the owner check coming due or the update screen (``ringWatchEvery``).
    @ObservationIgnored private var ringWatch: Task<Void, Never>?
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
    /// How long the probe waits before each try again after a failed read (two, so three reads in all). Short: an offer that
    /// came with the unlock waits for the probe's answer to ring, within ``unlockWait``, and a slow vault takes part of that
    /// already for each read.
    private static let probeRetries: [Duration] = [.milliseconds(500), .milliseconds(1500)]
    private static let pollEvery: Duration = .milliseconds(50)
    /// How often a call ringing here looks whether the owner check came due (or the update screen came up) meanwhile. A look
    /// each time rather than a timer to the deadline: it holds across the phone's sleep and a change of its clock.
    package static let ringWatchEvery: Duration = .milliseconds(500)
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
                guard !vault.updateShowing, !vault.ownerCheckShowing else { return false }
                // Rings only for a vault the probe has said has calls (as Android's `mayRing`): wait, bounded, for the unlock and then
                // for the probe's answer; "not in vault", a refusal or a failed probe: no ring, no CallKit report, no `call.ringing`.
                guard await Self.waitForCalls(flag, clock) else { return false }
                // Again after the wait: an unlock that completed meanwhile may have shown the update or the daily check.
                return !vault.updateShowing && !vault.ownerCheckShowing
            },
            peerKey: { await vault.identityKey($0) }, vaultIsC2: { flag.vaultC2 },
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
                guard openFlag.isOpen, supported == nil else { continue }
                // One probe at a time: a recheck that comes during one is held and asked again when it ends, if still not known.
                if probing { recheckPending = true } else { startProbe() }
            }
        })
    }

    /// Stops everything: the machine too. The tasks hold the controller until this is called.
    package func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        probeTask?.cancel()
        longCall?.cancel()
        ringWatch?.cancel()
        microphoneAsk?.cancel()
        keepalive?.task.cancel()
        keepalive = nil
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
        guard let seq = machine.session?.seq else { return }
        gate(.answer(seq: seq))
    }

    /// CallKit's Accept on the system's own screen (``CallKitCoordinator``'s `mayAnswer`): true when the microphone is allowed.
    /// Otherwise the answer is refused, the call keeps ringing, and our screen asks (``microphonePrompt``): "Allow" then answers
    /// this call (``allowMicrophone()``).
    package func answerFromCallKit(seq: Int) -> Bool {
        guard machine.session?.seq == seq, case .live(let l) = machine.state, l.phase == .incoming else { return false }
        switch microphone.status {
        case .granted: return true
        case .undetermined: microphonePrompt = .explain(.answer(seq: seq))
        case .denied: microphonePrompt = .blocked(.answer(seq: seq))
        }
        return false
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
        case .answer(let seq):
            guard let s = machine.session, s.seq == seq, case .live(let l) = machine.state, l.phase == .incoming else { return }
            performAnswer()
        }
    }

    /// "Allow" on our own screen: the system's prompt, and what was held back goes on when the member allows it. A member who
    /// refuses there sees nothing more now; the next call or answer finds the microphone denied and shows the blocked screen
    /// (chosen; not in the spec).
    package func allowMicrophone() {
        guard case .explain(let action)? = microphonePrompt else { return }
        microphonePrompt = nil
        microphoneAsk?.cancel()
        microphoneAsking = action
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
        recheckPending = false
        if isOpen { startProbe() } else { locked() }
    }

    private func locked() {
        supported = nil
        vaultC2 = false
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
        // is already over on this phone (the member hung up and locked at once), and so is a `call.start` still on its way: the
        // call it places is ended when its answer comes, and that end must go before the lock too.
        if !live && machine.pendingEnds == 0 && machine.startsInFlight == 0 { return }
        if live { machine.vaultLocking() }
        let deadline = clock.elapsedMs() + Self.lockWait.wholeMilliseconds
        while isLive || machine.pendingEnds > 0 || machine.startsInFlight > 0 {
            if clock.elapsedMs() >= deadline { return }
            do { try await clock.sleep(for: Self.pollEvery) } catch { return }
        }
    }

    /// Waits (at most ``lockWait``) until the hang-ups handed to the vault are with the relay. Only waits: a call that rings or goes on
    /// is left alone (the end of one call may ring the connection's held offer in the same turn).
    package func waitForPendingEnds() async {
        let deadline = clock.elapsedMs() + Self.lockWait.wholeMilliseconds
        while machine.pendingEnds > 0 {
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
            guard let self, probeGeneration == generation else { return }
            probing = false
            if supported == nil, openFlag.isOpen, recheckPending {
                recheckPending = false
                startProbe()
            }
        }
    }

    /// `call.list`: an answer means calls; `unsupported_type`, none; any other refusal (the daily check is due, ...) leaves it
    /// not known, and a failure is tried again twice.
    private func probe(_ generation: Int) async {
        supported = nil
        for attempt in 0...Self.probeRetries.count {
            do {
                let list = try await vault.gateway.list(limit: Self.historyLimit)
                guard !Task.isCancelled, generation == probeGeneration, openFlag.isOpen else { return }
                // The level first: an offer that waited for `supported` is answered with keep-alives at once.
                vaultC2 = list.formTwo
                supported = true
                listSkipped = list.skipped
                if list.formTwo { await endStaleC2(list) } else { await endStale(list.calls) }
                return
            } catch is CancellationError {
                return
            } catch let e as VaultOpError {
                guard !Task.isCancelled, generation == probeGeneration, openFlag.isOpen else { return }
                if e.code == Self.unsupported { supported = false }
                return
            } catch {
                guard attempt < Self.probeRetries.count else { return }
                do { try await clock.sleep(for: Self.probeRetries[attempt]) } catch { return }
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

    /// (C2, VAULT-MESSAGING §10.10 "Liveness") The calls of this device a C2 vault still holds live while this app has none,
    /// by `device_id`, `exp` and the vault's `now`, never this phone's clock; other devices' calls are left alone. A live
    /// active call of this device ends `failed`; its own outgoing call still ringing past `exp` ends `timeout`.
    private func endStaleC2(_ list: CallList) async {
        if isLive { return }
        guard let me = await vault.deviceId(), let vaultNow = list.now else { return }
        for r in list.calls {
            // A call that started here meanwhile is left alone, as by the C1 sweep's first look.
            if isLive { return }
            guard let reason = Self.staleReasonC2(r, me: me, vaultNow: vaultNow) else { continue }
            do {
                try await vault.gateway.end(r.callId, reason: reason)
                staleEnded += 1
            } catch {
                // Not ended: the next unlock tries again.
            }
            if Task.isCancelled || !openFlag.isOpen { return }
        }
    }

    /// The end of [r] by the C2 rule, or nil when it is not this device's or not stale by the vault's [vaultNow].
    package static func staleReasonC2(_ r: CallRecord, me: String, vaultNow: Date) -> String? {
        guard r.deviceId == me else { return nil }
        if r.state == "active" { return CallReason.failed }
        let pastExp = r.exp.flatMap(CallHistoryRows.time).map { vaultNow >= $0 } ?? false
        return r.state == "ringing" && r.direction == "out" && pastExp ? CallReason.timeout : nil
    }

    /// (C2, VAULT-MESSAGING §10.10 "Liveness") The call's device sends `call.keepalive` to its own vault as soon as the call is
    /// active on it (``CallState/Live/answerThrough``: the callee once its `call.answer` is with its vault, the caller once it
    /// took the answer; one sent before is answered `call.end{unavailable}`), then every 30 s until it ends. Only to a C2 vault
    /// (an S10 vault answers an unknown type): one the probe found C2, or a call in form 2, which proves it for that call even
    /// before the probe has answered.
    private func keepAlive(_ live: CallState.Live?) {
        let id = live.flatMap { l in (vaultC2 || l.formTwo) && l.answerThrough ? l.callId : nil }
        if id == keepalive?.callId { return }
        keepalive?.task.cancel()
        keepalive = id.map { callId in
            (callId, Task { [weak self, clock] in
                while !Task.isCancelled {
                    // One lost keep-alive is not an end: the next goes in 30 s, within the vault's 90 s.
                    guard let signalling = self?.signalling else { return }
                    try? await signalling.keepalive(callId: callId)
                    do { try await clock.sleep(for: .seconds(CallLimits.keepaliveEvery)) } catch { return }
                }
            })
        }
    }

    // MARK: around a call

    /// The screen for an answer goes with its call: when the caller gives up (or another call rings), nothing is left to answer.
    private func dropStaleAnswerPrompt(_ t: CallTransition) {
        var held: MicrophoneAction?
        switch microphonePrompt {
        case .explain(let a)?, .blocked(let a)?: held = a
        case nil: break
        }
        guard case .answer(let seq)? = held ?? microphoneAsking else { return }
        if case .live(let l) = t.state, l.phase == .incoming, t.seq == seq { return }
        if held != nil { microphonePrompt = nil }
        if case .answer = microphoneAsking {
            microphoneAsk?.cancel()
            microphoneAsking = nil
        }
    }

    private func around(_ t: CallTransition) {
        dropStaleAnswerPrompt(t)
        watchRing(t)
        if case .live(let l) = t.state { keepAlive(l) } else { keepAlive(nil) }
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

    /// A call ringing here (never one answered) stops ringing when the owner check comes due or is held, or the update screen
    /// comes up (owner decision 2026-11-18): as a ring that ran out, so nothing is sent and another device may still answer.
    private func watchRing(_ t: CallTransition) {
        guard case .live(let l) = t.state, l.phase == .incoming else {
            ringWatch?.cancel()
            ringWatch = nil
            return
        }
        guard ringWatch == nil else { return }
        let seq = t.seq
        ringWatch = Task { [weak self] in
            while let self, !Task.isCancelled {
                if vault.ownerCheckShowing || vault.updateShowing {
                    machine.ringStopped(seq: seq)
                    return
                }
                do { try await clock.sleep(for: Self.ringWatchEvery) } catch { return }
            }
        }
    }

    // MARK: the history

    /// The calls with [connectionId], newest first; empty when there are none or the vault has no calls, nil when the read
    /// failed (the conversation then keeps the lines it shows: no silent emptying).
    package func history(_ connectionId: String) async -> CallHistory? {
        guard supported == true else { return CallHistory() }
        let list: CallList
        do { list = try await vault.gateway.list(limit: Self.historyLimit) } catch { return nil }
        if openFlag.isOpen { listSkipped = list.skipped }
        return CallHistoryRows.history(list, connectionId: connectionId, now: clock.now())
    }

    // MARK: the unlock

    /// Whether the vault is open (a box the signalling's closure can hold before the controller is made).
    @MainActor
    private final class OpenFlag {
        var isOpen = false
        /// Mirror of the controller's: whether the vault has calls (nil: not known).
        var supported: Bool?
        /// (C2) Whether the vault is C2, as the last probe found it; false at a lock.
        var vaultC2 = false
    }

    /// Whether the vault has calls, waiting up to ``unlockWait`` (the clock's, so virtual in the tests) for the vault to open and
    /// then for the probe to answer: also a recheck probe that answers inside the window (after the daily check) lets it ring.
    private static func waitForCalls(_ flag: OpenFlag, _ clock: any CallClock) async -> Bool {
        let deadline = clock.elapsedMs() + unlockWait.wholeMilliseconds
        while !flag.isOpen || flag.supported == nil {
            if clock.elapsedMs() >= deadline { return false }
            do { try await clock.sleep(for: pollEvery) } catch { return false }
        }
        return flag.supported == true
    }
}
