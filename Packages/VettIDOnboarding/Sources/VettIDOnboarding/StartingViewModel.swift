import Foundation
import Observation

/// "Opening VettID" while the phase is read: after [stuckAfter] of the app being in the foreground the read may be stuck (a
/// network that answers nothing), and "Try again" is offered (chosen; not in the spec, where vettid-android has the spinner
/// only). The read itself goes on; the screen leaves by itself when it ends.
@MainActor
@Observable
public final class StartingViewModel {
    public private(set) var stuck = false
    /// "Try again" is on its way: it is not pressed twice.
    public private(set) var retrying = false

    @ObservationIgnored private let stuckAfter: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let reread: @MainActor () async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    /// [reread] reads the phase again and returns when it is done (and does nothing while a read is running).
    public init(
        stuckAfter: Duration = .seconds(20),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        reread: @escaping @MainActor () async -> Void
    ) {
        self.stuckAfter = stuckAfter
        self.sleep = sleep
        self.reread = reread
    }

    /// The wait for the stuck state, run while the app is in the foreground (the caller's task is cancelled when it leaves, and
    /// started again when it returns, so that the time spent in the background does not count).
    public func watch() async {
        do { try await sleep(stuckAfter) } catch { return }
        stuck = true
    }

    /// "Try again": one read at a time.
    public func retry() {
        guard !retrying else { return }
        retrying = true
        task = Task { [weak self, reread] in
            await reread()
            self?.retrying = false
        }
    }

    /// TEST ONLY: returns once "Try again" has run.
    func settle() async { await task?.value }
}
