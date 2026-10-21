import Foundation
import VettIDVault

// The member's items (VAULT-MESSAGING §10.7) over this manager's session, with the rules of the other lists
// (``VaultManager+Features``): nothing goes to a vault whose lock is pending, a read nobody asked for never opens a
// session, and the list is dropped whenever the vault is not open, held or due, and at a wipe (``forgetOpenLists()``,
// ``activityHeld()``, ``clearLists()``). Mirrors vettid-android `VaultManager.items`.
extension VaultManager {
    /// The items over the member's calls; a critical item's operations pass the gate of every credential operation
    /// first (``decideFirst(carriesPin:)``: refused at once while a change of PIN or password is unresolved), as the
    /// rotation does, and again under the credential lock (``VaultApi/credentialGate``).
    static func itemsManager(_ manager: VaultManager) -> ItemsManager {
        let ref = ManagerRef()
        ref.manager = manager
        let gate: @Sendable () async throws -> Void = { try await ref.manager?.decideFirst() }
        return ItemsManager(
            ops: { VaultItemOps(api: try await memberApi(ref), gate: gate) },
            quietOps: { VaultItemOps(api: try quietApi(ref), gate: gate) },
            notes: Self.failureNotes(ref)
        )
    }
}
