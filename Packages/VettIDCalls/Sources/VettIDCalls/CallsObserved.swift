import Foundation
import Observation
import os

// How the calls follow the app's observable state, as vettid-android's `CallVault` collects a `Flow`: the value now, then every
// distinct value after a change. Observation reports a change before it happens (`onChange` runs in `willSet`), so the stream
// reads the new value on its next turn of the main actor. The same as the other packages' `follow`.

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

/// [read]'s value now (unless [skippingCurrent]), then each distinct value after a change, until the stream is no longer
/// consumed.
@MainActor
func observed<Value: Equatable & Sendable>(
    skippingCurrent: Bool = false, _ read: @escaping @MainActor @Sendable () -> Value
) -> AsyncStream<Value> {
    let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
    let task = Task { @MainActor in
        var last: Value?
        var first = true
        while !Task.isCancelled {
            let signal = ChangeSignal()
            let value = withObservationTracking { read() } onChange: { signal.fire() }
            if value != last {
                last = value
                if !(first && skippingCurrent) { continuation.yield(value) }
            }
            first = false
            await signal.wait()
        }
        continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
}
