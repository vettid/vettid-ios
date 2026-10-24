import Foundation
import VettIDVault

// A replaced phone erases itself (owner decision, 2026-10-05), and the member's "Erase VettID from this phone": the
// crash-safe wipe (``LocalWipe``) in the fail-secure order of ``WipeRun``. Mirrors vettid-android `VaultManager`'s
// `eraseThisPhone`, `wipeThisPhone` and `eraseAfterMark`.
extension VaultManager {
    /// How long the relay is given to forget this phone's mailbox during a wipe: best effort, bounded.
    nonisolated static let mailboxCleanup: Duration = .seconds(5)

    /// The member confirmed "Erase VettID from this phone": the wipe through ``HolderWatch`` (one at a time), run to its
    /// end even if the caller goes away. The phase says how it ended (``AppPhase/signedOut``, or
    /// ``FailureKind/eraseFailed`` with "Try again"). Refused in a build that cannot wipe.
    public func eraseThisPhone() async throws {
        guard wiper != nil else { throw VaultFailure(.notSupported) }
        let task = Task { @MainActor [weak self] in await self?.holder?.wipeNow() }
        await task.value
    }

    /// The wipe a proof of replacement runs (``HolderWatch``: a sealed `unknown_device`, an authenticated
    /// `device.unlinked{transferred|replaced}`), and the member's confirmed erase.
    func wipeReplacedPhone() async { await wipeThisPhone() }

    /// Something to reset in memory at a wipe besides the vault manager's own state (the app lock, a setup link waiting).
    public func onWipe(_ hook: @escaping @MainActor () async -> Void) { wipeHooks.append(hook) }

    func runWipeHooks() async {
        for h in wipeHooks { await h() }
    }

    /// Everything of this phone's goes: the session and the device state, the relay mailbox (best effort), the phone
    /// secret and its keys, the owner check, the account record, every keychain item and key, the files and the
    /// notifications. Only after an authenticated proof (``HolderPolicy``), when the vault already made another phone its
    /// app, or on the member's confirmed erase.
    func wipeThisPhone() async {
        guard let wiper else { return }
        let keeper: LockKeeper = lockGuard.keeper
        await WipeRun(
            record: record,
            // Nothing of this phone's is left to lock a vault with.
            abandonLock: { keeper.abandon() },
            detach: { [weak self] in await self?.detachForWipe() },
            // Crash-safe: a process that ends from here on finishes the wipe at its next start.
            // An old phone that removes its keys at the end of a kept transfer says so on the welcome screen: the reason is in
            // the wipe's marker, so that a wipe a crash interrupted still leaves the notice when it is finished (kept
            // until a wipe completes: a retried wipe still says why it ran).
            mark: { [weak self] in try wiper.begin(reason: self?.wipeMovedAway == true ? LocalWipe.reasonMovedAway : nil) },
            erase: { [weak self] in await self?.eraseAfterMark(wiper) ?? false },
            onEnd: { [weak self] phase in self?.wipeEnded(phase) },
            sleep: config.lockTiming.sleep
        ).run()
    }

    /// The session, its observers and its collection stop; the device is kept for its forget.
    private func detachForWipe() async {
        // A session being opened is stopped and waited for: none outlives the wipe.
        _ = await cancelOpening()
        if let d = session?.device { wipeDevice = d }
        stopCollecting()
    }

    /// The wipe after its marker: true when nothing is left.
    private func eraseAfterMark(_ wiper: LocalWipe) async -> Bool {
        if let d = wipeDevice {
            // Best effort, bounded: the relay forgets the mailbox; the wipe does not depend on it.
            let cleanup = Task { try? await d.deleteMailbox() }
            let wait = KickableWait()
            Task { @MainActor in
                _ = await cleanup.value
                wait.kick()
            }
            await wait.wait(Self.mailboxCleanup, sleep: config.lockTiming.sleep)
            try? await d.forget()
            wipeDevice = nil
        }
        // The devices of sessions closed before (a deletion closes its session at once) may still have a request on its
        // way: forgotten first, so that nothing of theirs is written after the erase.
        await forgetEveryDevice()
        ownerChecks.clear()
        clearLists()
        releaseUpdate.clear()
        // The canary manifest's file is in the data directory the wipe erases.
        canary.forget()
        try? phoneSecrets.delete()
        usesPhoneSecret = false
        renewSecretSuggested = false
        refusedByVault = false
        alarm = nil
        unlockWindow = nil
        pinChangeOperation = nil
        renewOperation = nil
        deleteUnanswered = nil
        forgetChangeCheck()
        account = nil
        await wiper.resetMemory()
        var done = wiper.erase()
        // A session opened meanwhile may have written keys or files: stopped, then erased again.
        if await cancelOpening() { done = wiper.erase() }
        if done { wiper.finish() }
        return done
    }

    /// Forgets every device a session of this manager held that is still alive: each waits for what it is sending, and
    /// writes nothing to the store from then on.
    func forgetEveryDevice() async {
        // One registered while another is being forgotten is forgotten too: until none is left.
        while let d = devicesMade.alive.first {
            try? await d.forget()
            devicesMade.remove(d)
        }
    }

    /// The app process going away, as the tests simulate a restart: the manager starts nothing more (no session is
    /// opened, no change decided), the decision of a lost change and its next check are cancelled, a session still being
    /// opened is stopped and waited for, the collection stops, and every device a session of this manager held is halted
    /// (``VaultDevice/halt()``): what it was sending finishes, and nothing it still had on the way sends or writes anything
    /// from then on, while the stored state stays for the next manager. The cancelled decision is waited for last. A real
    /// process death needs none of this. The manager is unusable after.
    package func halt() async {
        halted = true
        keptTimer?.cancel()
        keptTimer = nil
        changeGeneration += 1
        let tasks = [deciding, recheck].compactMap { $0 }
        deciding = nil
        recheck = nil
        for t in tasks { t.cancel() }
        _ = await cancelOpening()
        stopCollecting()
        // One registered while another is being halted is halted too: until none is left.
        while let d = devicesMade.alive.first {
            await d.halt()
            devicesMade.remove(d)
        }
        for t in tasks { await t.value }
    }

    private func wipeEnded(_ p: AppPhase) {
        if p == .signedOut {
            account = nil
            wipeMovedAway = false
        }
        // The move's state is the record's, which the wipe reset; the notice is the wipe's own (``LocalWipe/movedAway``).
        movedAway = wiper?.movedAway ?? false
        finishMoveRunner.clearFailure()
        finishMoveRunner.release()
        keptTimer?.cancel()
        keptTimer = nil
        transferKeptSince = nil
        keptCheckPending = false
        movedBack = false
        moveNotDone = false
        openTransferID = nil
        transferEpochID = nil
        phase = p
        // A vault being deleted ends with the wipe (IOS-PLAN §4.2: the marker goes with the record).
        endDeletion()
    }

    /// "Erase VettID's data on this phone", offered only after a wipe that did not finish (``FailureKind/eraseFailed``):
    /// local only, no session opened and nothing sent; every keychain item and key and every file go, without the wipe's
    /// marker bookkeeping. True when nothing is left (the welcome screen follows); false when something could not be
    /// erased (the member removes the app and installs it again). Mirrors vettid-android `AppDataClear`.
    public func clearAppData() async -> Bool {
        guard let wiper, record.eraseFailed else { return false }
        await wiper.resetMemory()
        guard wiper.clearAll() else { return false }
        ownerChecks.clear()
        clearLists()
        releaseUpdate.clear()
        canary.forget()
        record.endWipe(complete: true)
        wipeEnded(.signedOut)
        return true
    }
}
