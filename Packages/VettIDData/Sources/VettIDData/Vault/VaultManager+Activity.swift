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
        guard let m = ref.manager, m.phase == .unlocked, !m.inBackground, let s = m.session else {
            throw VaultFailure(.other, code: "session_dropped")
        }
        return try m.openApi(s)
    }

    /// The feed, the approvals and History in memory only. Deciding an ask marks its feed item read.
    static func activityManagers(
        _ config: VaultManagerConfig, _ ref: ManagerRef, _ connections: ConnectionsManager, _ checks: OwnerCheckManager
    ) -> (FeedManager, ApprovalsManager, HistoryManager, HistoryExportManager) { // swiftlint:disable:this large_tuple
        let feed = FeedManager(
            ops: { try await memberApi(ref) }, quietOps: { try quietApi(ref) },
            // §3.6.3: nothing of the feed is shown while the vault is held or due.
            gated: { ref.manager?.featuresGated() ?? false },
            // Rule 3: while the release is checked its events and arrivals wait; told when the check is over (followBehind).
            // While the opening is paused (``VaultManager/openingPaused``) no check runs: what comes then waits too, for the
            // check that restarts at the return (fail closed, as within the opening).
            checking: { ref.manager.map { $0.releaseUpdate.checking || $0.openingPaused } ?? false },
            paused: { ref.manager?.releaseUpdate.holdsFeatures ?? false },
            ownerGated: { ref.manager?.ownerCheckGated ?? false },
            now: config.now
        )
        let approvals = ApprovalsManager(
            connections: connections, ops: { try await memberApi(ref) }, quietOps: { try quietApi(ref) },
            openUnlockWindow: { password in try await ref.manager?.openUnlockWindow(password: password) },
            now: config.now,
            // A vault before 0.21.0 lists only the ids of what waits: named from the item list where the app has it.
            itemNames: {
                var names: [String: ShareItem] = [:]
                for i in ref.manager?.items.items ?? [] {
                    names[i.itemID] = ShareItem(itemID: i.itemID, name: i.name, category: i.category, sensitivity: i.sensitivity.wire)
                }
                return names
            },
            // AA5, AA8: an agent's request is approved only for an item and fields this list names.
            itemCache: { ref.manager?.items.items ?? [] },
            // AA8 "Fail closed": the item's settings, read now; any failure is no.
            runCwdAllowed: { agent, item in
                guard let manager = ref.manager, let read = try? await manager.itemWays.read(agent, item) else { return false }
                return ItemWaysRules.runCwdAllowed(read)
            },
            held: { ref.manager?.ownerChecks.ownerCheck?.state == .held }
        )
        feed.onChanged = { ref.manager?.feedSeen($0) }
        approvals.onDecided = { [weak feed] kinds, ref in feed?.markReadWhere(kinds: kinds, ref: ref) }
        approvals.onAskRead = { [weak feed] ref, onlySingle in feed?.markAskRead(ref: ref, onlySingle: onlySingle) }
        approvals.onOpenAsksRead = { ref.manager?.openAsksRead($0) }
        checks.onReplayDue = { pass, stateEnded in ref.manager?.replayDue(pass, stateEnded: stateEnded) }
        followHold(checks, ref)
        let selfID = { @MainActor in ref.manager?.session?.device.deviceID }
        return (
            feed, approvals, HistoryManager(selfID: selfID) { try await memberApi(ref) },
            HistoryExportManager(ops: { try await memberApi(ref) }, selfID: selfID)
        )
    }

    /// One vault event for the approvals and the votes (only while the vault takes events and the release gate does not hold
    /// the features, ``onEvent(_:)``; the feed takes each event itself, ``FeedManager+Held``).
    func activityEvent(_ m: VaultMessage) {
        approvals.onEvent(m)
        votes.onEvent(m)
    }

    /// One vault event for the devices and a pairing (only while the vault takes events, ``onEvent(_:)``).
    func devicesEvent(_ m: VaultMessage) {
        devices.onEvent(m)
        itemWays.onEvent(m)
        pairing.onEvent(m)
    }

    /// Held or due (§3.6.3): IOS-PLAN §6.9 clears vault content at a hold as at the vault lock. The feed, the photos, the
    /// items and revealed values, the tags, the connections with their requests (the names and safety codes they showed)
    /// and the other member's declines, the messages, the approvals and History are dropped from memory; the member's own
    /// profile follows the check's state (``OwnProfileStep``). They are read again when the hold ends
    /// (``refreshAfterHold()``, or this phone's own check's ``refreshListsQuietly()``). Reads on their way are not
    /// published.
    /// [keepingFeed]: the feed stays (``forgetOpenLists(keepingFeed:)``).
    func forgetHeld(keepingFeed: Bool = false) {
        asksToNotify = false
        listMarks = [:]
        items.clear()
        sharing.clear()
        connections.forgetOpenVault(keepingAuthentication: true)
        messages.forgetOpenVault()
        attachments.clear()
        forgetActivity(keepingFeed: keepingFeed)
        // The events the device kept for the ones that wait for them carry the same content.
        session?.device.clearInbox()
    }

    /// Another device's owner check ended the hold (§3.6.3): what was dropped at it is read again, the tags at once, then
    /// the connections and the requests, the approvals' lists, the conversations, the items and the votes, one after the other
    /// (History is read by its screen). This phone's own check reads every list itself (`onPassed`, which follows at
    /// once), so then nothing is read here. A read of every list begun before (the unlock's) may have lost to the hold
    /// what it read: it is waited for, and the lists are read after it (a double read is harmless).
    func refreshAfterHold() {
        let reads = listsReads
        Task { [weak self] in _ = try? await self?.sharing.refreshTagsQuietly() }
        Task { [weak self] in
            guard let self, listsReads == reads else { return }
            await listsRead?.value
            guard listsReads == reads, phase == .unlocked else { return }
            try? await connections.refresh(quietly: true)
            try? await connections.refreshRequests(quietly: true)
            try? await approvals.refreshApprovals(quietly: true, requests: false)
            await messages.refreshConversationsQuietly()
            try? await items.refresh(quietly: true)
            await votes.openNow()
            if phase == .unlocked, !votes.held() { votes.startSync() }
        }
    }

    /// A check passed with the vault open, here or on another device, ended the held or due state (owner decisions of
    /// 2026-11-15; ANDROID-PLAN 0.1.132 Notifications 7, IOS-PLAN 0.1.76 §6.7; ``OwnerCheckView/replayDue(from:to:at:)``:
    /// an unlock's own check and a status read never count). The feed notes what arrives from now
    /// (``FeedManager/openWaitingAsks()``), and the first read of `pending.list` begun from now that succeeds replays the
    /// asks still waiting (``openAsksRead(_:)``). The lists are read as before: by this phone's check (`onPassed`), or for a
    /// hold's end (``refreshAfterHold()``); a due state known only by the clock that another device's check ended has
    /// neither, so the feed and the approvals are read here (the feed first: the replay waits for its full read).
    func replayDue(_ pass: OwnerCheckPass, stateEnded: Bool) {
        asksToNotify = false
        feed.closeWaitingAsks()
        guard phase == .unlocked else { return }
        asksToNotify = true
        // A monotonic stamp, not the clock: a read begun from now counts, whatever the clock is set to meanwhile.
        asksFrom = approvals.readsBegun + 1
        feed.openWaitingAsks()
        guard pass == .elsewhere, !stateEnded else { return }
        Task { [weak self] in
            await self?.feed.openNow()
            try? await self?.approvals.refreshApprovals(quietly: true, requests: false)
        }
    }

    /// A read of `pending.list` was applied (``ApprovalsManager/onOpenAsksRead``). While a replay waits
    /// (``replayDue(_:stateEnded:)``): one that failed leaves it to the next read (none before a lock: nothing); one begun
    /// before the check does not count; `unsupported_type` means there are none; the first that merged replays, against
    /// what it listed, after the feed's first full read since the check (``FeedManager/replayWaitingAsks(_:)``), while the
    /// vault is still open and not held again.
    func openAsksRead(_ read: ApprovalsManager.OpenAsksRead) {
        guard asksToNotify else { return }
        switch read {
        case .failed:
            return
        case .unsupported:
            asksToNotify = false
            feed.closeWaitingAsks()
        case .merged(let keys, let stamp):
            guard stamp >= asksFrom else { return }
            asksToNotify = false
            guard phase == .unlocked else { return feed.closeWaitingAsks() }
            feed.replayWaitingAsks(approvals.approvals.filter { keys.contains($0.key) })
        }
    }

    /// Held or due (§3.6.3), as the owner check's state says: no vault content is kept (``forgetHeld()``), nor the
    /// member's own names, full email or photo (IOS-PLAN §4.7); after the check (here or on another device) they are read
    /// again. As vettid-android `VaultManager`, which keeps the lists other than the feed while held (IOS-PLAN §6.9 does
    /// not).
    static func followHold(_ checks: OwnerCheckManager, _ ref: ManagerRef) {
        checks.onHeldChange = { held in
            guard let m = ref.manager else { return }
            if held {
                m.forgetHeld()
            } else if m.phase == .unlocked {
                m.feed.catchUp()
                m.refreshAfterHold()
            }
            switch OwnProfileStep.onCheck(wasHeld: !held, held: held, phase: m.phase) {
            case .forget: m.forgetOwnProfile()
            case .read: m.readOwnProfile()
            case .none: break
            }
        }
    }

    /// The vault is no longer open: the feed (unless [keepingFeed]), the approvals and History are dropped.
    func forgetActivity(keepingFeed: Bool = false) {
        // A kept feed still closes the passed check's waiting-asks window, and drops the replays it held, as
        // ``forgetHeld(keepingFeed:)`` ends the replay and drops its `pending.list`.
        if keepingFeed {
            feed.closeWaitingAsks()
            feed.dropReplayedArrivals()
        } else {
            feed.clear()
        }
        approvals.forgetOpenVault()
        history.clear()
        votes.clear()
        devices.clear()
        itemWays.clear()
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
        votes.clear()
        devices.clear()
        itemWays.clear()
        // The kept attempts at the results too (a lock keeps them; a wipe does not).
        votes.forgetStored()
    }
}
