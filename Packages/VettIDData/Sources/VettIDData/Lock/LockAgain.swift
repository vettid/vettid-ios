import Foundation
import VettIDAltChan

/// (Release L, "Lock it now") Which opening the fresh lock is bound to. Mirrors vettid-android `LockAgain`.
@MainActor
enum LockAgain {
    /// The `unlock_id` the vault's status names now ([read]); nil when it names none, one not of the form, or cannot be read:
    /// the lock is then unconditional (VAULT-LOCK Q3), never bound to a value that may be stale. Whatever stopped the
    /// read (a timeout, no network), the lock goes out unconditional.
    static func unlockID(_ read: () async throws -> String?) async -> String? {
        do {
            let id = try await read()
            return UnlockIds.of(id)
        } catch {
            return nil
        }
    }
}
