import Foundation
import VettIDVault

/// Drops `vault.locking` notices from before the vault last opened (VAULT-MESSAGING §11.4 "Unlock of a running vault").
/// Mirrors vettid-android `LockNotices`.
///
/// The notice is relayed and can arrive after the unlock that followed it: an unlock of a vault that is already running
/// locks it first, then opens it in the same request. Taken as current, such a notice would send the open app back to
/// the unlock screen. The comparison is on the enclave's clock: ``opened(at:)`` records the inner `ts` of the successful
/// unlock result, which the enclave sets after any lock that unlock made, and a notice whose own `ts` is not later than
/// it is stale. A later notice (the vault locked after this unlock) is kept, as is every notice before the first unlock
/// known to this phone.
@MainActor
final class LockNotices {
    static let type = "vault.locking"

    /// The last unlock's time; the one kept on the phone at a process start, so that a restart forgets nothing.
    private(set) var openedAt: Date?

    init(opened: Date? = nil) {
        openedAt = opened
    }

    /// A successful unlock answered at [at] (the result's inner `ts`; nil: unknown, nothing changes).
    func opened(at: Date?) {
        guard let at else { return }
        if let prev = openedAt, at <= prev { return }
        openedAt = at
    }

    /// Whether a message of [type] sent at [ts] is a `vault.locking` from before the vault last opened here.
    func stale(type: String, ts: Date) -> Bool {
        guard type == Self.type, let at = openedAt else { return false }
        return ts <= at
    }

    /// Whether it is a `vault.locking` from **after** the vault last opened here, with that time known: only such a notice
    /// is evidence for a lock asked for since (an older one, left uncollected, says nothing about it).
    func sinceLastOpened(type: String, ts: Date) -> Bool {
        guard type == Self.type, let at = openedAt else { return false }
        return ts > at
    }

    func stale(_ m: VaultMessage) -> Bool { stale(type: m.type, ts: m.ts) }

    func sinceLastOpened(_ m: VaultMessage) -> Bool { sinceLastOpened(type: m.type, ts: m.ts) }
}
