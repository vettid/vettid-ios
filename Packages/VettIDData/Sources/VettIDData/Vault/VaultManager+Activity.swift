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
        _ config: VaultManagerConfig, _ ref: ManagerRef, _ rec: AccountRecord, _ connections: ConnectionsManager,
        _ checks: OwnerCheckManager
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
            now: config.now,
            // A vault before 0.21.0 lists only the ids of what waits: named from the item list where the app has it.
            itemNames: {
                var names: [String: ShareItem] = [:]
                for i in ref.manager?.items.items ?? [] {
                    names[i.itemID] = ShareItem(itemID: i.itemID, name: i.name, category: i.category, sensitivity: i.sensitivity.wire)
                }
                return names
            }
        )
        approvals.onDecided = { [weak feed] kinds, ref in feed?.markReadWhere(kinds: kinds, ref: ref) }
        followHold(checks, ref, feed)
        let selfID = { @MainActor in ref.manager?.session?.device.deviceID }
        return (
            feed, approvals, HistoryManager(selfID: selfID) { try await memberApi(ref) },
            HistoryExportManager(ops: { try await memberApi(ref) }, selfID: selfID)
        )
    }

    /// One vault event for the feed and the approvals (only while the vault takes events, ``onEvent(_:)``).
    func activityEvent(_ m: VaultMessage) {
        feed.onEvent(m)
        approvals.onEvent(m)
    }

    /// Entering the hold (§3.6.3): the feed is not shown, and no photo, item or revealed value is kept.
    func activityHeld() {
        feed.clear()
        attachments.clear()
        items.clear()
        sharing.clear()
    }

    /// Held or due (§3.6.3), as the owner check's state says: no feed content is kept, nor the member's own names, full
    /// email or photo (IOS-PLAN §4.7); after the check (here or on another device) they are read again. As vettid-android
    /// `VaultManager`.
    static func followHold(_ checks: OwnerCheckManager, _ ref: ManagerRef, _ feed: FeedManager) {
        checks.onHeldChange = { [weak feed] held in
            if held {
                feed?.clear()
                // Held or due: no photo or thumbnail kept (ANDROID-PLAN "Photo attachments"), and no item or revealed value
                // (chosen; not in the spec: vettid-android keeps the item list while held).
                ref.manager?.attachments.clear()
                ref.manager?.items.clear()
                ref.manager?.sharing.clear()
            } else if ref.manager?.phase == .unlocked {
                feed?.catchUp()
                // Another device's check: the items, dropped at the hold, are read again. This phone's own check reads
                // them with the other lists, last (`onPassed`, which follows at once), so not here as well.
                Task { @MainActor in
                    guard let items = ref.manager?.items, !items.listsReadPending else { return }
                    items.refreshQuietly()
                }
                // The tags and their colours, dropped at the hold, are read again (the colour keeper follows them).
                Task { @MainActor in _ = try? await ref.manager?.sharing.refreshTagsQuietly() }
            }
            guard let m = ref.manager else { return }
            switch OwnProfileStep.onCheck(wasHeld: !held, held: held, phase: m.phase) {
            case .forget: m.forgetOwnProfile()
            case .read: m.readOwnProfile()
            case .none: break
            }
        }
    }

    /// The vault is no longer open: the feed, the approvals' lists and History are dropped (the approvals kept by design
    /// stay).
    func forgetActivity() {
        feed.clear()
        approvals.forgetOpenVault()
        history.clear()
    }

    /// A wipe, or a deleted vault: every list, and what the phone keeps of them.
    func clearLists() {
        forgetOwnProfile()
        items.clear()
        sharing.clear()
        connections.clear()
        messages.clear()
        attachments.reset()
        feed.clear()
        approvals.clear()
        history.clear()
    }
}
