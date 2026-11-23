import Foundation
import VettIDVault

// How an agent may use its items (VAULT-MESSAGING §10.11, ANDROID-PLAN 0.1.137 AA7) over this manager's session, with a
// widening's password through the app's own window path (``VaultManager/openUnlockWindow(password:)``). Memory only; cleared with
// the devices list (lock, hold, wipe, deletion). Mirrors the item-ways part of vettid-android `VaultManager`.
extension VaultManager {
    static func itemWaysManager(_ manager: VaultManager) -> ItemWaysManager {
        let ref = ManagerRef()
        ref.manager = manager
        return ItemWaysManager(
            ops: { VaultItemWaysOps(api: try await memberApi(ref)) },
            windowUntil: { ref.manager?.unlockWindow },
            openWindow: { password in try await ref.manager?.openUnlockWindow(password: password) },
            closeWindow: { try await ref.manager?.closeUnlockWindow() },
            // The setting alone (one `settings.get`), not the whole credential status.
            unlockTtl: { await ref.manager?.unlockTtlSetting() },
            now: manager.config.now,
            hasItemWays: { ReleasePath.itemWays(ref.manager?.record.value.capabilities ?? []) }
        )
    }
}
