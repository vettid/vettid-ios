import Foundation

/// One run of an async job at a time, whoever asks: a second ask while one is running does nothing and returns at once. The
/// app's read of the phase is one (the launch, "Try again", the foreground and protected data all ask for it), so that a hung
/// first read is not joined by a second beside it.
@MainActor
public final class SingleFlight {
    public private(set) var running = false

    public init() {}

    /// Runs [body] unless a run is under way; true when it ran.
    @discardableResult
    public func run(_ body: () async -> Void) async -> Bool {
        guard !running else { return false }
        running = true
        await body()
        running = false
        return true
    }
}
