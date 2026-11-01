import Foundation
import VettIDVault

// The member's votes (VAULT-MESSAGING 0.81.4 §10.19, IOS-PLAN §4.16) over this manager's session, with the rules of the
// feed (``VaultManager+Activity``): a read nobody asked for never opens a session, nothing is read while the vault is
// held or due, and what was read is dropped when the vault is no longer open. Mirrors the votes part of vettid-android
// `VaultManager`. The work with the public votes site runs while the vault is open and unlocked: started at the opening
// and at the end of a hold, paused while the app is away, stopped by a lock, a hold or a wipe (``VotesManager/clear()``).
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
            // The setting alone (one `settings.get`), not the whole credential status.
            unlockTtl: { await ref.manager?.unlockTtlSetting() },
            now: now,
            site: manager.config.votesSite,
            // A run nobody asked for never opens a session; the member's own (Check again, a vote's screen) may.
            siteOps: { quietly in quietly ? try quietApi(ref) : try await memberApi(ref) },
            sleep: manager.config.votesSleep,
            backgroundTasks: manager.config.backgroundTasks
        )
    }

    /// `credential.unlock_ttl_seconds` (VAULT-MESSAGING §10.8) over the session already open; nil when it can't be read.
    func unlockTtlSetting() async -> Int? {
        guard let s = session, let api = try? openApi(s), let values = try? await api.settingsGet().values else { return nil }
        return values[Self.keyUnlockTtl].flatMap { Int($0) }
    }
}
