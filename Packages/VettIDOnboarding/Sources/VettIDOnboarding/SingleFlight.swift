import Foundation

/// One run of an async job at a time, whoever asks. An ask while a run is under way waits for it, and the job runs once more
/// after it, once however many asked: the answer an asker was waiting for (a foreground or protected-data read) is not lost to
/// a read that began before it. The app's read of the phase is one (the launch, "Try again", the foreground and protected data
/// all ask for it), so that a hung first read is not joined by a second beside it, and a "Try again" stays busy until the read
/// it asked for has ended.
@MainActor
public final class SingleFlight {
    private var current: Task<Void, Never>?
    private var again = false

    public init() {}

    /// A run is under way.
    public var running: Bool { current != nil }

    /// Runs [body] unless a run is under way, and returns true. With one under way it asks for one more run after it (the
    /// same job), waits for that to end, and returns false. The runs are a task of their own, cleared by itself when they end,
    /// so a cancelled caller leaves nothing set.
    @discardableResult
    public func run(_ body: @escaping @MainActor () async -> Void) async -> Bool {
        if let current {
            again = true
            await current.value
            return false
        }
        let task = Task { @MainActor [weak self] in
            await body()
            while self?.again == true {
                self?.again = false
                await body()
            }
            self?.current = nil
        }
        current = task
        await task.value
        return true
    }
}
