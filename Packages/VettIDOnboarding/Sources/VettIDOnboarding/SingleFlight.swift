import Foundation

/// One run of an async job at a time, whoever asks. An ask while a run is under way waits for it, and the job runs once more
/// after it, once however many asked: the answer an asker was waiting for (a foreground or protected-data read) is not lost to
/// a read that began before it. The extra run happens only if the job is still needed when the run ends ([stillNeeded] of the
/// run that started it, checked again before each extra run) or a member asked for it ([forced]). The app's read of the phase is
/// one (the launch, "Try again", the foreground and protected data all ask for it), so that a hung first read is not joined by a
/// second beside it, and a "Try again" stays busy until the read it asked for has ended. Waiters return only when the whole run
/// ends, the extra reads included. A joiner's [stillNeeded] is ignored: the starter's is used.
@MainActor
public final class SingleFlight {
    private var current: Task<Void, Never>?
    private var again = false
    private var forcedAgain = false

    public init() {}

    /// A run is under way.
    public var running: Bool { current != nil }

    /// Runs [body] unless a run is under way, and returns true. With one under way it asks for one more run after it (the same
    /// job), waits for the whole run to end, and returns false. [stillNeeded]: whether an extra run is still wanted when the run
    /// ends (nil: always); [forced]: the ask is a member's, so the extra run is made whatever [stillNeeded] says. The runs are a
    /// task of their own, cleared by itself when they end, so a cancelled caller leaves nothing set.
    @discardableResult
    public func run(
        forced: Bool = false, stillNeeded: (@MainActor () -> Bool)? = nil, _ body: @escaping @MainActor () async -> Void
    ) async -> Bool {
        if let current {
            again = true
            forcedAgain = forcedAgain || forced
            await current.value
            return false
        }
        let task = Task { @MainActor [weak self] in
            await body()
            while let self, self.again {
                let wanted = self.forcedAgain || (stillNeeded?() ?? true)
                self.again = false
                self.forcedAgain = false
                if !wanted { break }
                await body()
            }
            self?.current = nil
        }
        current = task
        await task.value
        return true
    }
}
