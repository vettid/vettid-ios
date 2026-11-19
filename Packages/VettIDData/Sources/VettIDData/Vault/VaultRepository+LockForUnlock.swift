import Foundation

/// Whether this phone can unlock at all (§6.7.1). Part of ``VaultRepository``.
@MainActor
public protocol UserGuidCheck {
    /// This phone holds a `user_guid` it can unlock with: without one, the unlock refuses (`no_user_guid`) before anything
    /// is sent, so a flow that locks first and unlocks after (``VaultRepository/lockForUnlock()``) never locks.
    var userGuidUsable: Bool { get }
}

// "Lock and unlock now" (VAULT-MESSAGING §11.14.9 step 3) only on a phone that can unlock again (§6.7.1).
public extension VaultRepository {
    /// "Lock and unlock now" (VAULT-MESSAGING §11.14.9 step 3): the vault is locked, and the unlock screen that follows asks
    /// for each PIN. False, with nothing locked or sent, when this phone could not unlock again (``userGuidUsable``): it
    /// would lock a vault it can never open.
    func lockForUnlock() async throws -> Bool {
        guard userGuidUsable else { return false }
        try await lock()
        return true
    }

    /// The decided change's "Lock and unlock now" (the open app's banner, §11.14.9 step 3): the decision is acknowledged,
    /// and the vault is locked for the unlock screen's two prompts. False, with nothing locked or sent, on a phone without a
    /// usable `user_guid` (``lockForUnlock()``): the caller says that this phone cannot open the vault.
    @MainActor
    func lockAndUnlockForChange() -> Bool {
        acknowledgeChangeCheck()
        guard userGuidUsable else { return false }
        Task { _ = try? await lockForUnlock() }
        return true
    }
}
