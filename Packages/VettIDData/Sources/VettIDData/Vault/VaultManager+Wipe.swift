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
            mark: { try wiper.begin() },
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
        ownerChecks.clear()
        connections.clear()
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

    private func wipeEnded(_ p: AppPhase) {
        if p == .signedOut { account = nil }
        phase = p
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
        connections.clear()
        releaseUpdate.clear()
        canary.forget()
        record.endWipe(complete: true)
        wipeEnded(.signedOut)
        return true
    }
}
