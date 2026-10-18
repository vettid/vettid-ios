import Foundation

/// How the member's lock runs, so that **a lock once asked for always completes**. Mirrors vettid-android
/// `LockSequence`:
///
/// - It runs in a task of its own, not the caller's: the screen that asked for the lock may go away, the lock goes on.
/// - What other parts of the app want to finish while the vault still collects (``addHook(_:)``: ending a call, so that
///   its hang-up reaches the vault) runs first, as a task of its own, and is waited for [hookBudget] at most, then
///   cancelled and left behind. A hook that never finishes or throws cannot hold the lock back longer. Without hooks
///   nothing is waited for.
/// - `after` runs whatever became of `lock`: the phone's own state ends locked also when the vault could not be told.
///
/// (vettid-android also bounds a hook that blocks its thread; a hook here runs on the main actor and must not block.)
@MainActor
final class LockSequence {
    /// What every hook together gets before the vault is locked.
    static let hookBudget: Duration = .seconds(2)

    private var hooks: [@MainActor () async throws -> Void] = []
    private let budget: Duration
    private let sleep: LockSleep

    init(hookBudget: Duration = LockSequence.hookBudget, sleep: @escaping LockSleep = realLockSleep) {
        budget = hookBudget
        self.sleep = sleep
    }

    /// Adds something to finish before every lock. A hook must be quick, must not call the lock itself, and shares the
    /// budget with every other hook: when the budget is over it is cancelled and the lock proceeds.
    func addHook(_ hook: @escaping @MainActor () async throws -> Void) {
        hooks.append(hook)
    }

    /// Runs the hooks (bounded), then [lock], then [after] in every outcome. Returns when all of it is done, or throws
    /// what [lock] threw.
    func run(lock: @escaping @MainActor () async throws -> Void, after: @escaping @MainActor () -> Void) async throws {
        let task = Task { @MainActor [self] in
            defer { after() }
            await runHooks()
            try await lock()
        }
        try await task.value
    }

    private func runHooks() async {
        guard !hooks.isEmpty else { return }
        let all = hooks
        let job = Task { @MainActor in
            for hook in all {
                if Task.isCancelled { return }
                // One hook's failure is not the next one's, and never the lock's.
                try? await hook()
            }
        }
        let done = KickableWait()
        let watcher = Task { @MainActor in
            await job.value
            done.kick()
        }
        await done.wait(budget, sleep: sleep)
        watcher.cancel()
        job.cancel()
    }
}
