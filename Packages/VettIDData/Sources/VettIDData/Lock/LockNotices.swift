import Foundation
import VettIDAltChan
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
///
/// (VAULT-MESSAGING 0.56.4 §10.2 "Locks", release L) A notice that names the unlock it ends (`unlock_id`) is judged by that
/// name instead, when this phone holds the vault's current one (``current``): another name is an older opening's notice,
/// and is dropped; the same name is this opening's. A notice without the name (a release before L), or one that arrives
/// while this phone holds no current name (a new process before its first status read), is judged by the time as above.
@MainActor
final class LockNotices {
    static let type = "vault.locking"

    /// The vault's current `unlock_id` as this phone knows it, nil when it holds none.
    var current: () -> String? = { nil }

    /// (Release L) The opening the last lock was bound to when the vault said it was over (``LockKeeper/deadUnlockID``); a
    /// notice that names it is the dead opening's, however late it says it is.
    var dead: () -> String? = { nil }

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

    /// Whether a message of [type] sent at [ts] is a `vault.locking` from before the vault last opened here. Without a name.
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

    /// Whether [m] is a `vault.locking` from before the vault last opened here (or, by its name, of another opening).
    func stale(_ m: VaultMessage) -> Bool {
        guard m.type == Self.type else { return false }
        if let named = named(m), let dead = dead(), named == dead { return true }
        if let named = named(m), let mine = current() { return named != mine }
        return stale(type: m.type, ts: m.ts)
    }

    /// Whether [m] is evidence for the pending lock: a `vault.locking` naming the unlock that lock is bound to ([bound],
    /// release L), or, when either has no name, one from after the vault last opened here (``sinceLastOpened(_:)``).
    func confirms(_ m: VaultMessage, bound: String?) -> Bool {
        guard m.type == Self.type else { return false }
        if let named = named(m), let bound { return named == bound }
        return sinceLastOpened(m)
    }

    func sinceLastOpened(_ m: VaultMessage) -> Bool { sinceLastOpened(type: m.type, ts: m.ts) }

    private func named(_ m: VaultMessage) -> String? { UnlockIds.of(VaultJSON.string(m.object, "unlock_id")) }
}
