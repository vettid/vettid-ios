import Foundation
import Observation
import os

// How a view model follows an observable repository's state, as a vettid-android view model collects a `StateFlow`:
// the current value at once, then every distinct value after a change. Observation reports a change before it happens
// (`onChange` runs in `willSet`), so the follower reads the new value on its next turn of the main actor.

/// A one-shot wake-up from `onChange` (any thread) or from cancellation, whichever comes first.
final class ChangeSignal: Sendable {
    private struct State {
        var fired = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func fire() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.fired = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.fired { return true }
                    s.waiter = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            fire()
        }
    }
}

/// The tasks a view model owns, cancelled when it goes.
final class TaskBag: Sendable {
    private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])

    func add(_ task: Task<Void, Never>) { tasks.withLock { $0.append(task) } }

    func cancelAll() {
        let all = tasks.withLock { t -> [Task<Void, Never>] in
            defer { t.removeAll() }
            return t
        }
        for t in all { t.cancel() }
    }
}

/// Calls [apply] with [read]'s value now, then with each distinct value after a change, until [owner] goes or the
/// returned task is cancelled. [owner] is held weakly between changes.
@MainActor
func follow<Owner: AnyObject & Sendable, Value: Equatable & Sendable>(
    _ owner: Owner,
    read: @escaping @MainActor @Sendable (Owner) -> Value,
    apply: @escaping @MainActor @Sendable (Owner, Value) -> Void
) -> Task<Void, Never> {
    let initial = read(owner)
    apply(owner, initial)
    return Task { @MainActor [weak owner] in
        var last = initial
        while !Task.isCancelled {
            let signal = ChangeSignal()
            guard let value = track(owner, read: read, signal: signal) else { return }
            if value != last {
                last = value
                guard deliver(owner, value, apply: apply) else { return }
            }
            await signal.wait()
        }
    }
}

/// [read]'s value, with [signal] fired at its next change; nil when [owner] is gone.
@MainActor
private func track<Owner: AnyObject, Value>(
    _ owner: Owner?, read: @MainActor (Owner) -> Value, signal: ChangeSignal
) -> Value? {
    guard let owner else { return nil }
    return withObservationTracking { read(owner) } onChange: { signal.fire() }
}

/// Applies [value]; false when [owner] is gone.
@MainActor
private func deliver<Owner: AnyObject, Value>(_ owner: Owner?, _ value: Value, apply: @MainActor (Owner, Value) -> Void) -> Bool {
    guard let owner else { return false }
    apply(owner, value)
    return true
}
