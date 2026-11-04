import Foundation

/// One run of an async job at a time, whoever asks: an ask while one is running waits for it to end and does not run again.
/// The app's read of the phase is one (the launch, "Try again", the foreground and protected data all ask for it), so that a
/// hung first read is not joined by a second beside it, and a "Try again" stays busy for as long as the read it joined.
@MainActor
public final class SingleFlight {
    private var current: Task<Void, Never>?

    public init() {}

    /// A run is under way.
    public var running: Bool { current != nil }

    /// Runs [body] unless a run is under way, and returns true; with one under way it waits for that run to end and returns
    /// false. The run is a task of its own, cleared by itself when it ends, so a cancelled caller leaves nothing set.
    @discardableResult
    public func run(_ body: @escaping @MainActor () async -> Void) async -> Bool {
        if let current {
            await current.value
            return false
        }
        let task = Task { @MainActor [weak self] in
            await body()
            self?.current = nil
        }
        current = task
        await task.value
        return true
    }
}
