import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// One call at a time, from the tap to the hang-up (CALLS-PLAN 0.1.1 §2, phase C1: voice, app open, the vault of staging
/// release 10 as it is). It speaks to the vault through ``CallSignalling`` and to the media stack through ``MediaEngine``; it
/// holds no key (keys go from one to the other and are wiped there) and logs nothing. Mirrors vettid-android `CallMachine`.
///
/// Every input (the member's taps, the vault's events, the engine's events, timers) goes through one queue and is handled in
/// order by one loop on the main actor, which alone changes ``state``. What takes time (the engine, the vault) runs in the
/// call's own tasks and reports back through the queue, each report with the call's sequence number: a report for a call that
/// is over is dropped.
///
/// What the vault does not do at S10 and this does for it:
/// - the **caller** sends `call.end{timeout}` when the offer expires; the **callee** only stops ringing (if it sent the timeout
///   itself, its vault would end the call first and never record the missed call);
/// - an address that cannot be gathered, a path that is not found and frames that do not decrypt each end the call with their
///   own reason instead of leaving it waiting.
@MainActor
@Observable
package final class CallMachine {
    package internal(set) var state: CallState = .idle
    /// Measurements of the current (or last) call.
    package internal(set) var diagnostics = CallDiagnostics()
    /// Each call that connected, counted once when it ends, by the last path the stack reported for it.
    package internal(set) var paths = CallPaths()
    /// How often the listening to the vault's call events had to be started again (expected: 0).
    package internal(set) var listenRestarts = 0
    /// `call.end` messages handed to the vault client and not yet with the relay.
    package internal(set) var pendingEnds = 0

    @ObservationIgnored let signalling: any CallSignalling
    @ObservationIgnored let engines: any MediaEngineFactory
    @ObservationIgnored let clock: any CallClock
    @ObservationIgnored let timings: CallTimings
    /// Asked when a call's engine is made.
    @ObservationIgnored let config: @MainActor () -> MediaConfig
    @ObservationIgnored let inbox: AsyncStream<CallMessage>.Continuation
    @ObservationIgnored var session: CallSession?
    @ObservationIgnored var nextSeq = 0
    /// Outgoing calls the member hung up before the vault had answered `call.start`: ended as soon as it does.
    @ObservationIgnored var abandoned: [Int] = []
    /// Glare winners that ended while this device's lost call waited for them: an offer for one of them that still arrives
    /// (late, or delivered again) is not rung or answered. A few ids, memory only.
    @ObservationIgnored var endedWinners: [String] = []
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var watchers: [Int: AsyncStream<CallTransition>.Continuation] = [:]
    @ObservationIgnored private var nextWatcher = 0

    static let maxPendingCandidates = 256
    static let maxAbandoned = 8
    static let maxEarly = 64
    static let maxEndedWinners = 8

    package init(
        signalling: any CallSignalling, engines: any MediaEngineFactory, clock: any CallClock = SystemCallClock(),
        timings: CallTimings = CallTimings(), config: @escaping @MainActor () -> MediaConfig = { MediaConfig() }
    ) {
        self.signalling = signalling
        self.engines = engines
        self.clock = clock
        self.timings = timings
        self.config = config
        let (stream, continuation) = AsyncStream.makeStream(of: CallMessage.self)
        inbox = continuation
        loops.append(Task { [weak self] in
            for await m in stream {
                guard let self else { return }
                handle(m)
            }
        })
        loops.append(Task { [weak self] in await self?.listen() })
    }

    /// Stops the machine: a live call is let go (its engine closed, its keys wiped) and nothing is sent. A `call.start` still on
    /// its way is not ended either (a C2 vault ends unanswered calls itself; at S10 the callee's ring timer bounds it). The listening loop holds the machine until this is called.
    package func stop() {
        inbox.finish()
        for w in watchers.values { w.finish() }
        watchers.removeAll()
        for t in loops { t.cancel() }
        loops.removeAll()
        if let s = session { release(s) }
    }

    /// The vault's events are listened to for as long as the process lives: whatever ends the collection (it should be
    /// nothing: the signalling refuses and counts what goes wrong), it starts again.
    private func listen() async {
        while !Task.isCancelled {
            do {
                for try await e in signalling.events() { post(.signal(e)) }
            } catch is CancellationError {
                return
            } catch {
                listenRestarts += 1
            }
            do { try await clock.sleep(for: timings.relisten) } catch { return }
        }
    }

    // MARK: transitions

    /// Every state the machine publishes, in order, none merged (``state`` itself may skip one: `ended` and the next call's
    /// `live` can be published in one turn). A live call at the time of the call is the first element.
    package func transitions() -> AsyncStream<CallTransition> {
        let (stream, continuation) = AsyncStream.makeStream(of: CallTransition.self)
        let id = nextWatcher
        nextWatcher += 1
        watchers[id] = continuation
        if let s = session, case .live = state { continuation.yield(CallTransition(seq: s.seq, state: state)) }
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.watchers[id] = nil } }
        return stream
    }

    /// Sets ``state`` and tells every watcher.
    func setState(_ s: CallState, seq: Int, memberEnded: Bool = false) {
        state = s
        for w in watchers.values { w.yield(CallTransition(seq: seq, state: s, memberEnded: memberEnded)) }
    }

    // MARK: the member

    /// Calls [connectionId]. Ignored while a call is live.
    package func call(_ connectionId: String) { post(.call(connectionId: connectionId)) }

    /// Answers the ringing call.
    package func answer() { post(.answer) }

    /// Declines the ringing call.
    package func decline() { post(.decline) }

    /// Ends the call in any phase (a ringing incoming call is declined).
    package func hangUp() { post(.hangUp(.hungUp)) }

    /// Ends the call in any phase with [reason] (CallKit refused it, for one).
    package func end(_ reason: CallEnd) { post(.hangUp(reason)) }

    /// The vault is being locked: a live call ends.
    package func vaultLocking() { post(.hangUp(.locked)) }

    package func setMuted(_ muted: Bool) { post(.mute(muted)) }

    /// Clears an ended call.
    package func dismiss() { post(.dismiss) }

    func post(_ m: CallMessage) { inbox.yield(m) }

    // MARK: the loop

    // swiftlint:disable:next cyclomatic_complexity
    private func handle(_ m: CallMessage) {
        let s = session
        switch m {
        case .call(let connectionId): if s == nil { startOutgoing(connectionId) }
        case .answer: if let s, s.phase == .incoming { answerIncoming(s) }
        case .decline:
            if let s, s.phase == .incoming {
                s.memberEnded = true
                finish(s, .declinedHere, CallReason.decline)
            }
        case .hangUp(let reason): if let s { hangUp(s, reason) }
        case .mute(let muted):
            if let s {
                s.muted = muted
                s.engine?.setMuted(muted)
                publish(s)
            }
        case .dismiss: if s == nil { setState(.idle, seq: -1) }
        case .signal(let e): if !heldEarly(s, e) { onSignal(s, e) }
        case .placed(let seq, let call, let atMs): onPlaced(s, seq: seq, call: call, atMs: atMs)
        // A call that lost a glare has let its media go: what its engine still reports is of no use.
        case .media(let seq, let e): if let s, s.seq == seq, s.supersededBy == nil { onMedia(s, e) }
        case .answered(let seq): if let s, s.seq == seq { onAnswered(s) }
        case .remoteApplied(let seq): if let s, s.seq == seq { s.remoteApplied = true }
        case .gathering(let seq): if let s, s.seq == seq, s.gathered == 0 { timer(s, .gather, timings.gather) }
        case .failed(let seq, let reason): if let s, s.seq == seq, s.supersededBy == nil { finish(s, reason, CallReason.failed) }
        case .timer(let seq, let kind): if let s, s.seq == seq { onTimer(s, kind) }
        case .path(let seq, let relayed): if let s, s.seq == seq { s.relayed = relayed }
        }
    }

    /// Keeps [e] for a call that has no id yet (see ``CallSession/early``); true if it was kept.
    private func heldEarly(_ s: CallSession?, _ e: SignalEvent) -> Bool {
        guard let s, s.callId == nil, s.early.count < Self.maxEarly else { return false }
        if case .offer = e { return false }
        s.early.append(e)
        return true
    }

    func newSession(_ connectionId: String, _ direction: CallDirection) -> CallSession {
        let s = CallSession(seq: nextSeq, connectionId: connectionId, direction: direction, tappedAtMs: clock.elapsedMs())
        nextSeq += 1
        session = s
        diagnostics = CallDiagnostics()
        s.launch { [weak self, weak s] in
            guard let s else { return }
            for await work in s.lane {
                guard s.laneIsOpen else { continue }
                do {
                    try await work()
                } catch is CancellationError {
                    return
                } catch is CallSecurityError {
                    self?.post(.failed(seq: s.seq, .notEncrypted))
                } catch is MediaLoggingError {
                    self?.post(.failed(seq: s.seq, .notEncrypted))
                } catch is MediaNotEncryptedError {
                    self?.post(.failed(seq: s.seq, .notEncrypted))
                } catch {
                    // The engine or the relay failed; what failed is in the diagnostics of the engine, never in a log.
                    self?.post(.failed(seq: s.seq, .failed))
                }
            }
        }
        return s
    }

    /// Creates the call's engine and listens to it. False (and the call ended) if the media stack cannot be used.
    func openEngine(_ s: CallSession) -> Bool {
        var failure: CallEnd?
        var made: (any MediaEngine)?
        do {
            let e = try engines.create(config: config())
            made = e
            if e.suites.isEmpty { failure = .notEncrypted }
        } catch is MediaLoggingError {
            failure = .notEncrypted
        } catch {
            failure = .failed
        }
        s.engine = made
        guard let engine = made, failure == nil else {
            finish(s, failure ?? .failed, nil)
            return false
        }
        let events = engine.events
        s.launch { [weak self] in
            for await e in events { self?.post(.media(seq: s.seq, e)) }
        }
        return true
    }

    /// Runs [body] to its end even if the calling task is cancelled meanwhile (once `call.start` may have left, its answer is
    /// needed to end the call; between the answer's return and the keys' hand-over a hang-up must not leave the keys with
    /// nobody to wipe them).
    func uncancellable<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await Task { try await body() }.value
    }
}
