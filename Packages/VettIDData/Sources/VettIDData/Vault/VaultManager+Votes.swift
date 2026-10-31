import Foundation
import VettIDVault

// The member's votes (VAULT-MESSAGING 0.81.3 §10.19, IOS-PLAN §4.16) over this manager's session, with the rules of the
// feed (``VaultManager+Activity``): a read nobody asked for never opens a session, nothing is read while the vault is
// held or due, and what was read is dropped when the vault is no longer open. Mirrors the votes part of vettid-android
// `VaultManager` (the hourly work with the public site comes with that work).
extension VaultManager {
    static func votesManager(_ manager: VaultManager) -> VotesManager {
        let ref = ManagerRef()
        ref.manager = manager
        let now = manager.config.now
        return VotesManager(
            ops: { try await memberApi(ref) }, quietOps: { try quietApi(ref) },
            // §3.6.3: a held vault answers `owner_check_required`; nothing is read until the check.
            gated: { ref.manager?.ownerChecks.ownerCheck?.gated(now()) ?? false },
            windowUntil: { ref.manager?.unlockWindow },
            openWindow: { password in try await ref.manager?.openUnlockWindow(password: password) },
            closeWindow: { try await ref.manager?.closeUnlockWindow() },
            unlockTtl: { try? await ref.manager?.status().unlockTtlSeconds },
            now: now
        )
    }
}
