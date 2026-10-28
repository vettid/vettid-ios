import Foundation
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
        let events = s.device.events()
        let counts = s.device.vaultRefusalCounts()
        let required = s.device.ownerCheckRequired()
        observers = [
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

    /// Back in the foreground: the mailbox collection runs again (a session is opened when this phone holds a device),
    /// and the outbox is flushed unless a lock is pending (nothing but the lock goes to a vault that counts as locked).
    public func onForeground() {
        // A background task that began before this does not stop the collection (``onBackground(budget:)``).
        foregrounds += 1
        moveFlags.book.lifecycle += 1
        backgrounded = false
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
        if phase == .unlocked, let v = ownerChecks.ownerCheck, v.gated(t) || v.warning(t) { ownerChecks.onOpened() }
        if phase == .unlocked { Task { [weak self] in await self?.releaseUpdate.refreshOffer() } }
        Task { [weak self] in
            guard let self, let s = try? await storedSession() else { return }
            // A session opened in the background (a lock's retry) has not collected yet.
            s.device.start()
            if lockGuard.admits() { await s.device.flushOutbox() }
        }
    }

    /// Leaving the foreground (IOS-PLAN §6.6): the first attempt of a lock asked for is finished, what is in the outbox
    /// is sent (not while a lock is pending), then the collection stops, unless the app came back meanwhile. All of it
    /// within [budget] (the background time iOS gives) and stopped when the calling task is cancelled (its expiration);
    /// nothing assumes it ran longer. A pending lock's retries go on while the process runs and resume at the next start.
    public func onBackground(budget: Duration = .seconds(25)) async {
        let began = foregrounds
        moveFlags.book.lifecycle += 1
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await lockGuard.keeper.firstAttemptDone()
            if Task.isCancelled { return }
            if let s = session, lockGuard.admits() { await s.device.flushOutbox() }
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
        // Back in the foreground meanwhile: the collection runs on.
        guard began == foregrounds else { return }
        backgrounded = true
        moveFlags.book.lifecycle += 1
        stopCollecting()
    }

    func stopObserving() {
        for t in observers { t.cancel() }
        observers = []
    }

    /// One vault event. Mirrors the part of vettid-android `VaultManager.onEvent` that the unlock, the lock and the owner
    /// check need; the lists and the feed follow theirs with their rows.
    func onEvent(_ m: VaultMessage) {
        // The lock before this phone's last unlock (the one an unlock of a running vault makes), relayed late.
        if lockNotices.stale(m) { return }
        ownerChecks.onEvent(m)
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

    /// `credential.alarm` (§3.5.9): it ends the unlock window.
    private func raiseAlarm(_ m: VaultMessage) {
        guard let id = VaultJSON.string(m.object, "alarm_id") else { return }
        unlockWindow = nil
        alarm = CredentialAlarm(
            alarmID: id, state: VaultJSON.string(m.object, "state") ?? CredentialAlarm.stateFrozen,
            at: VaultJSON.string(m.object, "at"), presenter: VaultJSON.string(m.object, "presenter")
        )
    }

    /// `sync.event{kind: "credential.alarm"}` (§3.5.9): the alarm's state as another device changed it.
    private func syncAlarm(_ m: VaultMessage) {
        let o = m.object
        guard VaultJSON.string(o, "kind") == Self.typeAlarm else { return }
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
