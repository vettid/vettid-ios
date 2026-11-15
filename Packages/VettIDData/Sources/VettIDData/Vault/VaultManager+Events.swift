import Foundation
import VettIDCrypto
import VettIDVault

// What the vault sends that the unlock and the lock follow (VAULT-MESSAGING §10.1, §11.4, §12): `vault.locking`,
// `vault.held`, the credential's alarm, `device.unlinked`, `account.changed`, and the relay's refusals of this phone's
// deposits.
extension VaultManager {
    static let typeHeld = "vault.held"
    static let typeAlarm = "credential.alarm"
    static let typeSync = "sync.event"

    /// Follows [s]'s events and refusal counts until the session is dropped.
    func observe(_ s: VaultSession) {
        stopObserving()
        readMoveMarker()
        // In a background a call holds, the events that are not the calls' or the lock's are left unacked at the relay: it delivers
        // them again once the app is back, so that a process that ends meanwhile loses none (the memory buffer below is the fast
        // path for what the device had already handed over).
        let flag = heldFlag
        let passes: Set<String> = [LockNotices.type, HolderPolicy.deviceUnlinked, Self.typeHeld]
        s.device.holdEvents { type in flag.on && !passes.contains(type) && !callEventTypes.contains(type) }
        let events = s.device.events()
        let counts = s.device.vaultRefusalCounts()
        let required = s.device.ownerCheckRequired()
        let reconnects = s.device.relayReconnects()
        let counted = s.device.countedEnds()
        let dropped = s.device.droppedForTime()
        observers = [
            followTimeDrops(dropped),
            followCredentialKeys(s.device.credentialKeyChanges()),
            // (VAULT-MESSAGING 0.73.0 §3.6.5) A reconnect reads the vault's state again while it is probably locked, and the
            // operations that count as failed checks (§3.6.4) spend the owner check's estimate of tries left.
            Task { @MainActor [weak self] in
                for await _ in reconnects {
                    guard let self else { return }
                    relayReconnected()
                }
            },
            Task { @MainActor [weak self] in
                for await type in counted {
                    guard let self else { return }
                    ownerChecks.countedEnded(type: type)
                }
            },
            Task { @MainActor [weak self] in
                for await _ in required {
                    guard let self else { return }
                    ownerChecks.onRequired()
                }
            },
            Task { @MainActor [weak self] in
                for await m in events {
                    guard let self else { return }
                    onEvent(m)
                }
            },
            Task { @MainActor [weak self] in
                for await n in counts {
                    guard let self, let refusals else { return }
                    refusals.onRefusals(n, phase: phase)
                    refusedByVault = refusals.suspected
                }
            },
        ]
    }

    /// Every credential key the vault named in an answer to this phone, for Vault status (``credentialKeyChange``): its
    /// fingerprint, or "not known" when it named none or one that is not 32 bytes.
    private func followCredentialKeys(_ keys: AsyncStream<CredentialKeySeen>) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            for await seen in keys {
                guard let self else { return }
                credentialKeyChange = CredentialKeyChange(
                    seq: (credentialKeyChange?.seq ?? 0) + 1, fingerprint: seen.key.flatMap(CredentialKeyFingerprint.formatB64)
                )
            }
        }
    }

    /// Notes when the device drops a message for its time (``timeDropAt``).
    private func followTimeDrops(_ dropped: AsyncStream<String>) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            for await _ in dropped {
                guard let self else { return }
                timeDropAt = Date()
            }
        }
    }

    /// Back in the foreground: the mailbox collection runs again (a session is opened when this phone holds a device),
    /// and the outbox is flushed unless a lock is pending (nothing but the lock goes to a vault that counts as locked).
    public func onForeground() {
        // A background task that began before this does not stop the collection (``onBackground(budget:)``).
        foregrounds += 1
        // Back from a background that a call held: what was not handled meanwhile is read again below, with the lists.
        heldBackground = nil
        backgroundCounted = false
        session?.device.collectsLongPoll(false)
        let catchUp = eventsMissedWhileHeld
        eventsMissedWhileHeld = false
        replayHeldEvents()
        moveFlags.book.lifecycle += 1
        backgrounded = false
        ownerChecks.setForeground(true)
        guard phase != .signedOut else { return }
        // A pending lock is tried again at once (the app's retry at every start and every return to the foreground), unless
        // an attempt runs or just began, and without using up the member's "Try again" (``LockKeeper/retryOnForeground()``).
        // There is no job that runs while the app is not (chosen; not in the spec).
        lockGuard.keeper.retryOnForeground()
        // IOS-PLAN §4.2: a vault being deleted is read again, and nothing else runs.
        if deletion != nil {
            Task { [weak self] in _ = await self?.checkDeletionAgain() }
            return
        }
        // Release R (§11.14.10): the 7 days of a kept transfer are also checked on return, not only at a start.
        resumeKeptTransfer()
        // A vault past its owner-check deadline, or near it, is read again: the check screen shows what is waiting.
        let t = config.now()
        // A return to the foreground keeps the estimate of tries left (VAULT-MESSAGING 0.73.0 §3.6.5).
        if phase == .unlocked, let v = ownerChecks.ownerCheck, v.gated(t) || v.warning(t) { ownerChecks.onOpened(afterUnlock: false) }
        if phase == .unlocked { Task { [weak self] in await self?.releaseUpdate.refreshOffer() } }
        // The votes site again on return (IOS-PLAN §4.16: at unlock, at open, hourly while open), when its work was started
        // (a lock stopped it: the next opening starts it).
        votes.resumeSync()
        Task { [weak self] in
            guard let self, let s = try? await storedSession() else { return }
            // A session opened in the background (a lock's retry) has not collected yet.
            s.device.start()
            // The device's lock gate holds what may not go while a lock is pending (``setFlushGate``).
            await s.device.flushOutbox()
            // The events a held background did not handle (no list, feed or approval was touched in the background): read again now.
            if catchUp, phase == .unlocked, let s = try? await openSession() {
                // The lists are read as of now (the vault's time): what comes back from the relay older than this, after its lease, is
                // covered by the read (``supersededByReread(_:)``).
                // Each list's mark is set when that list's read answered: a failed one (or one the vault does not have) covers nothing, and
                // the events of it that come back are applied.
                let at = s.device.knowsVaultTime ? s.device.vaultNow() : nil
                refreshListsQuietly { [weak self] answered in
                    guard let self, let at else { return }
                    let until = config.now().addingTimeInterval(Self.rereadWindow)
                    for list in answered { listMarks[list] = (at, until) }
                }
                // And the alarm, whatever older events are still to be redelivered (they are ordered by their `ts`, ``raiseAlarm(_:)``).
                if let api = try? openApi(s) { await refreshAlarm(api) }
            }
        }
    }

    /// Leaving the foreground (IOS-PLAN §6.6): the first attempt of a lock asked for is finished, what is in the outbox
    /// is sent (not while a lock is pending), a vote window's lock on its way ends, then the collection stops, unless the
    /// app came back meanwhile. All of it within [budget] (the background time iOS gives) and stopped when the calling
    /// task is cancelled (its expiration); nothing assumes it ran longer. A pending lock's retries go on while the process runs and resume at the next start.
    public func onBackground(budget: Duration = .seconds(25)) async {
        let began = foregrounds
        moveFlags.book.lifecycle += 1
        // IOS-PLAN §6.3: the PIN kept for the pairing goes with the other secrets (§4.9), and so does the one kept for the
        // check's retry (VAULT-MESSAGING §3.6.5), also while an unlock and its check are on their way.
        forgetPairingPin()
        ownerChecks.setForeground(false)
        // No run with the votes site while the app is away (there is no background job).
        votes.pauseSync()
        // A live call holds the collection: decided first, so that what arrives during the work below is already kept, not acted on.
        if collectionHeld?() == true {
            heldBackground = began
            // The WebSocket's window of unacked messages would fill with the held events: a long poll meanwhile.
            session?.device.collectsLongPoll(true)
        }
        // A held background is a background for the settlement windows: counted once, when it begins.
        if heldBackground != nil, !backgroundCounted {
            moveFlags.book.backgrounds += 1
            backgroundCounted = true
        }
        backgroundWorks += 1
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await lockGuard.keeper.firstAttemptDone()
            if Task.isCancelled { return }
            if let s = session { await s.device.flushOutbox() } // through the device's lock gate
            if Task.isCancelled { return }
            // The lock of a vote's unlock window (IOS-PLAN §6.6): its answer can arrive only while the collection runs.
            await votes.windowLocksEnded()
        }
        let done = KickableWait()
        let watcher = Task { @MainActor in
            await work.value
            done.kick()
        }
        await withTaskCancellationHandler {
            await done.wait(budget, sleep: config.lockTiming.sleep)
        } onCancel: {
            work.cancel()
        }
        work.cancel()
        watcher.cancel()
        backgroundWorks -= 1
        // Back in the foreground meanwhile: the collection runs on.
        guard began == foregrounds else { return }
        // A live call keeps the collection: its peer's `call.end` and ICE come through it, and its own go out through the session.
        // The stop waits for the hold to end (``collectionHoldEnded()``). A call that went live during the work holds it too.
        if collectionHeld?() == true {
            if heldBackground == nil {
                heldBackground = began
                session?.device.collectsLongPoll(true)
                if !backgroundCounted {
                    moveFlags.book.backgrounds += 1
                    backgroundCounted = true
                }
            }
            return
        }
        finishBackground()
    }

    /// Starts a device's collection unless the app is in the background; while a call holds the background it collects by long poll.
    func startUnlessBackground(_ d: VaultDevice) {
        if backgrounded { return }
        if heldBackground != nil { d.collectsLongPoll(true) }
        d.start()
    }

    /// What a hold lets the foreground's leaving finish, once it may: the state of the background and the end of the collection.
    private func finishBackground() {
        heldBackground = nil
        backgrounded = true
        moveFlags.book.lifecycle += 1
        if !backgroundCounted { moveFlags.book.backgrounds += 1 }
        backgroundCounted = false
        // The held events stay for the foreground (a call's end in the background closes the connection, not the vault's state).
        finishingBackground = true
        let device = session?.device
        stopCollecting()
        finishingBackground = false
        // The stopped device goes back to the build's mode (it does not start again by this).
        device?.collectsLongPoll(false)
    }

    /// How many events a held background keeps (about the most a call's length brings); more drop the oldest.
    static let maxHeldEvents = 500

    /// Whether [m] is kept for later now, in a background a call holds: nothing of it is acted on until the foreground, where
    /// ``replayHeldEvents()`` handles it in order.
    private func dropsInHeldBackground(_ m: VaultMessage) -> Bool {
        // The calls take their own events from the device: they are not kept here.
        guard heldBackground != nil, !Self.locksOrEndsSession(m.type), !callEventTypes.contains(m.type) else { return false }
        eventsMissedWhileHeld = true
        heldEvents.append(m)
        if heldEvents.count > Self.maxHeldEvents {
            heldEvents.removeFirst()
            heldEventsOverflowed = true
        }
        return true
    }

    /// The held events are forgotten (the open vault ended: a lock, a sign-out, a wipe, a dropped session).
    func clearHeldEvents() {
        heldEvents = []
        heldEventsOverflowed = false
        reconnectedWhileHeld = false
    }

    /// Back in the foreground: what a held background kept is handled now, in the order it arrived, through the usual path and before
    /// the lists are read again; a reconnect meanwhile reads the owner check again. After an overflow, where the oldest events
    /// are gone, the state they carried is read instead: the alarm, the account and the owner check, the unlock window ended
    /// (an alarm ends it) and the connections' authentication forgotten (its results are events, not read again).
    private func replayHeldEvents() {
        let events = heldEvents
        let overflowed = heldEventsOverflowed
        let reconnected = reconnectedWhileHeld
        clearHeldEvents()
        guard phase == .unlocked else { return }
        for m in events { onEvent(m) }
        if reconnected || overflowed { ownerChecks.onRelayReconnected() }
        guard overflowed else { return }
        unlockWindow = nil
        connections.forgetAuthentication()
        Task { [weak self] in
            guard let self else { return }
            if let s = try? await openSession(), let api = try? openApi(s) { await refreshAlarm(api) }
            await refreshAccount()
        }
    }

    /// The relay connection is back: the owner check's state is read again, except in a background a call holds, where nothing is
    /// read (the foreground reads again, ``onForeground()``).
    private func relayReconnected() {
        guard heldBackground == nil else {
            eventsMissedWhileHeld = true
            reconnectedWhileHeld = true
            return
        }
        ownerChecks.onRelayReconnected()
    }

    /// The events that are handled in a background a call holds: the lock's own signal and what ends the session.
    static func locksOrEndsSession(_ type: String) -> Bool {
        type == LockNotices.type || type == HolderPolicy.deviceUnlinked || type == typeHeld
    }

    /// Keeps the mailbox collection running while [held] says so, when the app leaves the foreground (a live call: the app runs on
    /// in the background for its audio). The holder calls ``collectionHoldEnded()`` when [held] turns false.
    public func holdCollection(_ held: @escaping @MainActor () -> Bool) { collectionHeld = held }

    /// The hold of ``holdCollection(_:)`` ended. If the app left the foreground meanwhile and has not come back, the background
    /// that was waiting finishes now: the collection stops as ``onBackground(budget:)`` would have stopped it.
    public func collectionHoldEnded() {
        // (Not while the background's own work runs: ``onBackground(budget:)`` decides at its end.)
        guard backgroundWorks == 0, let began = heldBackground, began == foregrounds, collectionHeld?() != true else { return }
        finishBackground()
    }

    func stopObserving() {
        for t in observers { t.cancel() }
        observers = []
    }

    // swiftlint:disable cyclomatic_complexity
    /// One vault event. Mirrors the part of vettid-android `VaultManager.onEvent` that the unlock, the lock and the owner
    /// check need; the lists and the feed follow theirs with their rows.
    func onEvent(_ m: VaultMessage) {
        // The lock before this phone's last unlock (the one an unlock of a running vault makes), relayed late.
        if lockNotices.stale(m) { return }
        // In the background, kept running by a live call, only what locks or ends the session is handled here (the calls take their
        // own events from the device); nothing else is read or acted on, the owner check's events included (they are applied once, at
        // the replay). What the device had already acked is kept in memory and handled at the foreground (``replayHeldEvents()``);
        // the rest the relay delivers again after its lease.
        if dropsInHeldBackground(m) { return }
        ownerChecks.onEvent(m)
        if supersededByReread(m) { return }
        // Nothing the vault sends is taken into the app's lists while a lock is pending (as vettid-android).
        if lockGuard.takesEvents() {
            connections.onEvent(m)
            messages.onEvent(m)
            attachments.onEvent(m)
            items.onEvent(m)
            sharing.onEvent(m)
            activityEvent(m)
        }
        switch m.type {
        // §3.6.3: entering the hold ends the credential's unlock window; IOS-PLAN §6.9: no vault content is kept.
        case Self.typeHeld:
            unlockWindow = nil
            forgetHeld()
        case LockNotices.type:
            locking(m)
        case Self.typeAlarm:
            raiseAlarm(m)
        case Self.typeSync:
            syncAlarm(m)
            syncAccount(m)
            syncRelease(m)
        // `transferred` (§6.7.1 step 4) and `replaced` (§11.11.5 step 3) mean this phone was replaced; `vault_deleted`
        // (§12.5 step 1) closes the vault for good (IOS-PLAN §4.2); another reason is re-read like any change of the vault.
        case HolderPolicy.deviceUnlinked where VaultJSON.string(m.object, "reason") == Self.reasonVaultDeleted:
            onVaultDeletedEvent()
        case HolderPolicy.deviceUnlinked:
            // Release R (§11.14.10): `transferred` on an old phone that kept its keys is the end of the kept transfer.
            markMovedAway(m)
            if holder?.onVaultEvent(HolderPolicy.of(m)) != true {
                rereads += 1
                Task { [weak self] in try? await self?.refresh() }
            }
        default:
            break
        }
    }
    // swiftlint:enable cyclomatic_complexity

    /// `vault.locking` (§12.3): the vault is locking; after this phone's last unlock, a lock of this phone that was in doubt
    /// no longer is. (One whose place in time is not known confirms nothing: the status read will.)
    private func locking(_ m: VaultMessage) {
        unlockWindow = nil
        if lockNotices.confirms(m, bound: lockGuard.keeper.boundUnlockID) { lockGuard.keeper.confirmed() }
        switch phase {
        case .unlocked, .setup: phase = .locked
        default: break
        }
    }

    /// (VAULT-MESSAGING 0.73.0 §3.6.5) A read of the vault's state found it locked (the member API's `state: locked`): the
    /// app moves to its locked screen, as for a `vault.locking`.
    func lockedByProbe() {
        unlockWindow = nil
        switch phase {
        case .unlocked, .setup: phase = .locked
        default: break
        }
    }

    /// `credential.alarm` (§3.5.9): it ends the unlock window.
    private func raiseAlarm(_ m: VaultMessage) {
        guard let id = VaultJSON.string(m.object, "alarm_id") else { return }
        // An alarm ends the unlock window (§3.5.9), whatever the order of events: an older one, redelivered late, still closes it.
        unlockWindow = nil
        guard isNewestAlarmEvent(m) else { return }
        alarm = CredentialAlarm(
            alarmID: id, state: VaultJSON.string(m.object, "state") ?? CredentialAlarm.stateFrozen,
            at: VaultJSON.string(m.object, "at"), presenter: VaultJSON.string(m.object, "presenter")
        )
    }

    /// How long after the foreground's read the events older than it are dropped: the relay's lease (60 s) and a margin.
    static let rereadWindow: TimeInterval = 120

    /// The lists whose events are patches, and that the foreground reads again: an event of one that comes back from the relay (after
    /// its lease) older than that list's answered read is covered by it, and would put back what a newer event or decision had moved
    /// on (`connection.request.pending` re-adds an ended request). Every other event is applied: it is idempotent (`message.new`,
    /// `feed.event`, `vote.event`), told only by itself (`connection.event`) or state no read gives (the alarm, the authentication,
    /// the device and the vault's own).
    enum ReReadList: Hashable {
        case requests, approvals, grants, shares, critical

        init?(eventType t: String) {
            switch t {
            case "connection.request.pending", "connection.request.outgoing": self = .requests
            case ApprovalsManager.approvalType: self = .approvals
            case _ where t.hasPrefix("grant."): self = .grants
            case _ where t.hasPrefix("share."): self = .shares
            case _ where t.hasPrefix("critical-secret-use."): self = .critical
            default: return nil
            }
        }
    }

    /// Whether [m] is covered by the answered read of its own list (vault time against vault time), within the window.
    func supersededByReread(_ m: VaultMessage) -> Bool {
        guard let list = ReReadList(eventType: m.type), let mark = listMarks[list] else { return false }
        guard config.now() < mark.until else {
            listMarks[list] = nil
            return false
        }
        return m.inner.ts < mark.vault
    }

    /// Whether [m] is not older than the newest alarm event applied, or than a read of the alarm since: one redelivered late (a held
    /// background's, after its lease) must not set or clear what a newer event or read has said.
    private func isNewestAlarmEvent(_ m: VaultMessage) -> Bool {
        if let last = alarmEventAt, m.inner.ts < last { return false }
        alarmEventAt = m.inner.ts
        return true
    }

    /// `sync.event{kind: "credential.alarm"}` (§3.5.9): the alarm's state as another device changed it.
    private func syncAlarm(_ m: VaultMessage) {
        let o = m.object
        guard VaultJSON.string(o, "kind") == Self.typeAlarm, isNewestAlarmEvent(m) else { return }
        let state = VaultJSON.string(o, "state")
        let id = VaultJSON.string(o, "alarm_id")
        if state == CredentialAlarm.stateResolved {
            alarm = nil
        } else if let state, let id {
            var a = CredentialAlarm(alarmID: id, state: state, at: nil)
            if let known = alarm, known.alarmID == id { a = known }
            a.state = state
            alarm = a
        }
    }
}
