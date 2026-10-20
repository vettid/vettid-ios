import Foundation
import VettIDVault

// The feed (VAULT-MESSAGING §10.9), the approvals (§10.4, §10.12, §10.13, §6.8) and History with its export (§10.9) over
// this manager's session, with the rules of the connections and messages (``VaultManager+Features``): nothing goes to a
// vault whose lock is pending, a read nobody asked for never opens a session, and what was read from the open vault is
// dropped when it is no longer open.
extension VaultManager {
    /// The calls of what the member does: over the session, opened when needed; refused while a lock is pending.
    static func memberApi(_ ref: ManagerRef) async throws -> VaultApi {
        guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
        guard m.lockGuard.admits() else { throw VaultFailure(.other, code: Self.codeLockPending) }
        return try m.openApi(try await m.openSession())
    }

    /// The calls of a read nobody asked for: only over the session open now, while the vault is open and collecting.
    static func quietApi(_ ref: ManagerRef) throws -> VaultApi {
        guard let m = ref.manager, m.phase == .unlocked, !m.backgrounded, let s = m.session else {
            throw VaultFailure(.other, code: "session_dropped")
        }
        return try m.openApi(s)
    }

    /// The feed and History in memory only; the approvals that arrive only as events in their encrypted file. Deciding an
    /// ask marks its feed item read.
    static func activityManagers(
        _ config: VaultManagerConfig, _ ref: ManagerRef, _ rec: AccountRecord, _ connections: ConnectionsManager
    ) -> (FeedManager, ApprovalsManager, HistoryManager, HistoryExportManager) { // swiftlint:disable:this large_tuple
        let feed = FeedManager(
            ops: { try await memberApi(ref) }, quietOps: { try quietApi(ref) },
            // §3.6.3: nothing of the feed is shown while the vault is held or due.
            gated: { [now = config.now] in ref.manager?.ownerChecks.ownerCheck?.gated(now()) ?? false },
            now: config.now
        )
        let file = config.file(VaultFiles.approvals)
        let approvals = ApprovalsManager(
            connections: connections, ops: { try await memberApi(ref) }, quietOps: { try quietApi(ref) },
            openUnlockWindow: { password in try await ref.manager?.openUnlockWindow(password: password) },
            load: { try file.load() },
            // Nothing is written while a wipe runs or after one that did not finish.
            persist: { b in
                guard !rec.closed else { return }
                if b.isEmpty { try file.clear() } else { try file.save(b) }
            },
            now: config.now
        )
        approvals.onDecided = { [weak feed] kinds, ref in feed?.markReadWhere(kinds: kinds, ref: ref) }
        return (feed, approvals, HistoryManager { try await memberApi(ref) }, HistoryExportManager { try await memberApi(ref) })
    }

    /// One vault event for the feed and the approvals (only while the vault takes events, ``onEvent(_:)``).
    func activityEvent(_ m: VaultMessage) {
        feed.onEvent(m)
        approvals.onEvent(m)
    }

    /// Entering the hold (§3.6.3): the feed is not shown.
    func activityHeld() { feed.clear() }

    /// The vault is no longer open: the feed, the approvals' lists and History are dropped (the approvals kept by design
    /// stay).
    func forgetActivity() {
        feed.clear()
        approvals.forgetOpenVault()
        history.clear()
    }

    /// The vault opened, or an owner check passed: the feed and the approvals' lists are read again (the connection
    /// requests are read with the connections).
    func refreshActivityQuietly() async {
        await feed.openNow()
        try? await approvals.refreshApprovals(quietly: true, requests: false)
    }

    /// A wipe, or a deleted vault: every list, and what the phone keeps of them.
    func clearLists() {
        connections.clear()
        messages.clear()
        feed.clear()
        approvals.clear()
        history.clear()
    }
}
