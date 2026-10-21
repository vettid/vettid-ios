import Foundation
import VettIDVault

// The member's items (VAULT-MESSAGING §10.7) over this manager's session, with the rules of the other lists
// (``VaultManager+Features``): nothing goes to a vault whose lock is pending, a read nobody asked for never opens a
// session, and the list is dropped whenever the vault is not open, held or due, and at a wipe (``forgetOpenLists()``,
// ``activityHeld()``, ``clearLists()``). Mirrors vettid-android `VaultManager.items`.
extension VaultManager {
    /// The items over the member's calls. A critical item's operations pass the gate of every credential operation
    /// before anything is opened or sent (``decideFirst(carriesPin:)``: refused at once while a change of PIN or password
    /// is unresolved), as the rotation does, and again under the credential lock (``VaultApi/credentialGate``). Held or
    /// due (§3.6.3), nothing refills the list, as the feed.
    static func itemsManager(_ manager: VaultManager) -> ItemsManager {
        let ref = ManagerRef()
        ref.manager = manager
        let now = manager.config.now
        return ItemsManager(
            ops: { VaultItemOps(api: try await memberApi(ref)) },
            quietOps: { VaultItemOps(api: try quietApi(ref)) },
            notes: Self.failureNotes(ref),
            gated: { ref.manager?.ownerChecks.ownerCheck?.gated(now()) ?? false },
            gate: { try await ref.manager?.decideFirst() }
        )
    }
}
