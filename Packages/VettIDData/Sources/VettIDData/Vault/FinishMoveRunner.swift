import Foundation
import Observation

/// "Finish the move" (release R, VAULT-MESSAGING §11.14.10 step 4): `vault.lock`, then `vault.unlock` with this phone's own
/// secret. **Once asked for, it completes**, as the member's lock does (``LockSequence``): the run is a task of its own, so a
/// screen that goes away (the hold's bound sends the root to the unlock screen and clears the screen that asked) does not
/// stop it; the unlock goes on, opens the vault and publishes its phase, or its failure lands in ``failure`` for the unlock
/// screen. (A caller that is cancelled still waits for the run's answer in this port: Swift cannot stop an `await` on a
/// task; the run is bounded by the unlock's own timeouts.)
///
/// ``finishing`` holds the screen that asked for at most `hold`. `onOutcome` hears every answer of the unlock; `onOpened`
/// only a success that nothing overtook: `generation` (bumped by every lock and every wipe) unchanged since the run's own
/// lock, and not `signedOut`. It gets that generation, to check it again as one step with its write. A wipe that lands
/// during the unlock leaves its success standing, but nothing of the vault it erased is written into the fresh record.
///
/// One run at a time: a ``run(pin:taken:)`` while one is on its way starts nothing and waits for that one's answer. Mirrors
/// vettid-android `FinishMoveRunner`.
@MainActor
@Observable
public final class FinishMoveRunner {
    public private(set) var finishing = false

    /// Why the last run did not open the vault; nil after a success, ``clearFailure()`` or before any run.
    public private(set) var failure: FailureKind?

    @ObservationIgnored private let hold: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let lock: @MainActor () async throws -> Void
    @ObservationIgnored private let unlock: @MainActor (_ pin: String, _ taken: Int?) async throws -> UnlockAttempt
    @ObservationIgnored private let generation: @MainActor () -> Int
    @ObservationIgnored private let signedOut: @MainActor () -> Bool
    @ObservationIgnored private let onOutcome: @MainActor (UnlockAttempt) async -> Void
    @ObservationIgnored private let onOpened: @MainActor (_ generation: Int) async -> Void
    @ObservationIgnored private var current: Task<UnlockAttempt, any Error>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var bound: Task<Void, Never>?
    /// The run that is current: a run ``release()`` let go of (a wipe, a deletion) no longer sets anything, and is not joined.
    @ObservationIgnored private var runID = 0

    /// - Parameters:
    ///   - hold: how long ``finishing`` lasts at most (90 s in the app, as Android's `holdMs`).
    ///   - lock: `vault.lock`.
    ///   - unlock: the unlock with the PIN and the ``PhoneSecrets/pinGeneration`` it was taken at.
    public init(
        hold: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        lock: @escaping @MainActor () async throws -> Void,
        unlock: @escaping @MainActor (_ pin: String, _ taken: Int?) async throws -> UnlockAttempt,
        generation: @escaping @MainActor () -> Int,
        signedOut: @escaping @MainActor () -> Bool,
        onOutcome: @escaping @MainActor (UnlockAttempt) async -> Void = { _ in },
        onOpened: @escaping @MainActor (_ generation: Int) async -> Void = { _ in }
    ) {
        self.hold = hold
        self.sleep = sleep
        self.lock = lock
        self.unlock = unlock
        self.generation = generation
        self.signedOut = signedOut
        self.onOutcome = onOutcome
        self.onOpened = onOpened
    }

    public func clearFailure() { failure = nil }

    /// Runs the move and waits for it. While a run is on its way, another caller joins it (its [pin] is not used), as the
    /// screen ignores a second tap while busy: two runs never overlap, so one run's end never releases another's hold or
    /// overwrites its ``failure``. [taken]: the ``PhoneSecrets/pinGeneration`` the PIN was taken at (nil: not checked).
    public func run(pin: String, taken: Int? = nil) async throws -> UnlockAttempt {
        if let current, running { return try await current.value }
        running = true
        // Before the task is made, in the same synchronous step as the call: the screen that asked is held from here, so
        // that the run's own lock (which makes the phase ``AppPhase/locked``) never shows the unlock screen mid-finish.
        failure = nil
        finishing = true
        runID += 1
        let id = runID
        let task = Task { @MainActor [self] in try await body(pin: pin, taken: taken, id: id) }
        current = task
        return try await task.value
    }

    /// The hold ends now (a wipe, a deletion): ``finishing`` is false whatever the run still does. The run itself goes on to
    /// its own end, which finds it already clear.
    public func release() {
        runID += 1
        bound?.cancel()
        bound = nil
        finishing = false
        running = false
        current = nil
    }

    private func body(pin: String, taken: Int?, id: Int) async throws -> UnlockAttempt {
        let hold = hold
        let sleep = sleep
        bound = Task { @MainActor [weak self] in
            try? await sleep(hold)
            if !Task.isCancelled { self?.finishing = false }
        }
        defer {
            if id == runID {
                bound?.cancel()
                bound = nil
                finishing = false
                running = false
                current = nil
            }
        }
        do {
            try await lock()
            // Read after the run's own lock, which bumps it: a later change is a lock or a wipe during the unlock.
            let gen = generation()
            let r = try await unlock(pin, taken)
            if id == runID { failure = FinishSetupGate.failure(of: r) }
            await onOutcome(r)
            if r == .success, gen == generation(), !signedOut() { await onOpened(gen) }
            return r
        } catch {
            // Recorded for the unlock screen, then rethrown. A cancellation comes only from the process ending: nothing is
            // left to tell then.
            if id != runID {
                // Let go of by release(): nothing of it is told.
            } else if let e = error as? VaultFailure {
                failure = e.kind
            } else if !(error is CancellationError) {
                failure = .other
            }
            throw error
        }
    }
}
