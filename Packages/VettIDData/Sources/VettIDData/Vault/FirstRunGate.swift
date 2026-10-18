import Foundation
import VettIDKeys

/// The first-run cleanup (IOS-PLAN §6.1) as the app's gate before any key is touched: it runs at launch and, until it
/// has run, again before the vault manager reads a data file or a key (``VaultManagerConfig/prepare``). A launch before
/// the first unlock defers it (``FirstRunCleanup/Outcome/deferred``): nothing is deleted, the gate stays shut and
/// answers ``KeysError/unavailable(_:)`` ("Unlock your iPhone"), and the next attempt runs it again. Once it ran (or
/// found the app's data or its marker) it is not run again in this process.
public final class FirstRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private let cleanup: @Sendable () throws -> FirstRunCleanup.Outcome
    private var done = false

    public convenience init(_ cleanup: FirstRunCleanup) {
        self.init { try cleanup.run() }
    }

    init(run: @escaping @Sendable () throws -> FirstRunCleanup.Outcome) {
        cleanup = run
    }

    /// Whether the cleanup has run (or was not needed).
    public var isOpen: Bool { lock.withLock { done } }

    /// Runs the cleanup unless it has run; returns its outcome (nil when it had already run). Throws
    /// ``KeysError/unavailable(_:)`` while it is deferred, and the cleanup's own failure.
    @discardableResult
    public func ensure() throws -> FirstRunCleanup.Outcome? {
        try lock.withLock {
            guard !done else { return nil }
            let outcome = try cleanup()
            guard outcome != .deferred else { throw KeysError.unavailable("first run") }
            done = true
            return outcome
        }
    }
}
