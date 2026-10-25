import Foundation
import VettIDAltChan
import VettIDVault

/// This phone's own `vault.delete` on its way (``VaultManager/deleteVault(pin:password:)``): its `exp` on the phone's
/// clock once known, and whether the vault's `device.unlinked{vault_deleted}` came meanwhile.
struct OwnDelete {
    var expOnPhone: Date?
    var unlinked = false
}

// A vault being deleted (IOS-PLAN §4.2, ANDROID-PLAN §4 "A vault being deleted"; VAULT-MESSAGING §12.5 "Order"). The
// vault's `device.unlinked{vault_deleted}` arrives in step 1, but the member API lists the vault until step 5: the app
// closes the open vault at once, keeps a non-secret marker (``DeletingMarker``) so that a restart reopens in this state,
// re-reads the status on a schedule up to a bound (``DeletionWatch``). Owner decision, 2026-10-24: the member API has
// no definite "deleted" answer yet (a deleted vault gets the same bare `401`), so `{vault: null}`, `401` (a clock's
// included) and `403` never end this state and never erase; past the bound the member can confirm "Remove from this
// phone" (``AccountRepository/eraseThisPhone()``), which shows the one-time notice on "no vault". A definite word (the
// `410 vault_deleted` of MEMBER-API "Vault deletion", not read yet) ends it through ``deletionGone()``. Nothing is
// sent to the vault meanwhile: no session opens.
//
// A deletion this phone sent and the vault answered starts this state too (as vettid-android's `deleteVault` does), with
// the request's `exp` in the bound. The event during this phone's own deletion is left to it: an answer starts this
// state, a lost answer starts it only when the event came.
extension VaultManager {
    /// The code of an operation refused because the vault is being deleted.
    public nonisolated static let codeVaultDeleting = "vault_deleting"
    /// The `reason` of the vault's `device.unlinked` in a deletion (§12.5 step 1).
    nonisolated static let reasonVaultDeleted = "vault_deleted"
    /// The bound: 10 minutes after the event, or this phone's `vault.delete`'s `exp` plus 2 minutes when later.
    nonisolated static let deletingBound: TimeInterval = 600
    nonisolated static let deletingAfterExp: TimeInterval = 120

    /// `device.unlinked{vault_deleted}` from the vault, over its session (trusted as it is, §4.2).
    func onVaultDeletedEvent() {
        if ownDelete != nil {
            ownDelete?.unlinked = true
            return
        }
        enterDeleting(expOnPhone: deleteUnanswered?.expOnPhone)
    }

    /// The vault closes at once and the marker is stored; the re-reads start (the first after 5 s).
    func enterDeleting(expOnPhone: Date?) {
        guard deletion == nil else { return }
        finishMoveRunner.release()
        let since = config.now()
        var until = since.addingTimeInterval(Self.deletingBound)
        if let e = expOnPhone?.addingTimeInterval(Self.deletingAfterExp), e > until { until = e }
        let marker = DeletingMarker(vaultID: record.value.vaultID, since: since, until: until)
        // A marker that cannot be written leaves the state to this process: the vault is closed all the same.
        _ = try? record.update(since: record.generation) { $0.deleting = marker }
        closeForDeleting()
        deletion = VaultDeletion(since: marker.since, until: marker.until)
        deletionReads.start(since: marker.since, until: marker.until, readFirst: false)
    }

    /// A start that found the marker: "being deleted" before anything else, and a read at once; past the bound, the
    /// "still finishing" state without a new timer.
    func resumeDeleting(_ m: DeletingMarker) -> AppPhase {
        guard deletion == nil else { return .deleting }
        closeForDeleting()
        let slow = VaultDeletion.pastBound(since: m.since, until: m.until, now: config.now())
        deletion = VaultDeletion(since: m.since, until: m.until, slow: slow)
        deletionReads.start(since: m.since, until: m.until, readFirst: true)
        return .deleting
    }

    /// One read of the status now, or the one already on its way (Check again, and a return to the foreground). It never
    /// erases: only a definite word does (none yet), or the member's confirmed removal.
    public func checkDeletionAgain() async -> DeletionRead {
        guard deletion != nil else { return .gone }
        return await deletionReads.readOnce()
    }

    /// The member has seen the notice on "no vault".
    public func dismissVaultDeletedNotice() { vaultDeletedNotice = false }

    /// Refuses every session while the vault is being deleted: nothing more is sent to it.
    func refuseWhileDeleting() throws {
        if deletion != nil || record.value.deleting != nil { throw VaultFailure(.vaultUnavailable, code: Self.codeVaultDeleting) }
    }

    /// The deletion's state ends: after the erase (the notice when it left the phone as freshly installed), or a wipe of
    /// this phone for any reason.
    func endDeletion() {
        deletionWatch?.stop()
        guard deletion != nil else { return }
        deletion = nil
        if storedPhase == .signedOut { vaultDeletedNotice = true }
    }

    var deletionReads: DeletionWatch {
        if let w = deletionWatch { return w }
        let w = DeletionWatch(
            now: config.now, sleep: config.deletionSleep,
            read: { [weak self] in await self?.readDeletionStatus() ?? .unreachable },
            onGone: { [weak self] in await self?.deletionGone() },
            onSlow: { [weak self] in self?.deletion?.slow = true }
        )
        deletionWatch = w
        return w
    }

    /// One read of the member API's status for a vault being deleted (§4.2 point 3). Never ``DeletionRead/gone``:
    /// neither `{vault: null}` nor a `401`, `403`, 5xx or timeout is a definite word, so nothing here erases this phone.
    private func readDeletionStatus() async -> DeletionRead {
        do {
            let vault = try await vaultStatus()
            return .of(vaultListed: vault != nil, servicePaused: servicePaused)
        } catch {
            return .of(failure: error)
        }
    }

    /// The vault is gone: VettID's data on this phone is erased (the marker with the record), then "no vault".
    private func deletionGone() async {
        deletionWatch?.stop()
        await afterVaultDeleted()
        endDeletion()
    }

    /// Closes the open vault (§4.2 point 1): the shell and every vault screen (the phase), a release update, the
    /// session and its collection, a pending lock, the PIN steps and the changes in memory, the owner check, the lists.
    /// The app key and the device keys stay: the status needs the app key.
    private func closeForDeleting() {
        // An unlock, a refresh or a lock on its way publishes nothing over this state, nor writes the record.
        lockGeneration += 1
        rereads += 1
        record.bumpGeneration()
        storedPhase = .deleting
        releaseUpdate.clear()
        lockGuard.keeper.abandon()
        stopCollecting()
        pinChangeOperation = nil
        renewOperation = nil
        forgetChangeCheck()
        unlockWindow = nil
        alarm = nil
        ownerChecks.clear()
        forgetOwnProfile()
        connections.clear()
        messages.clear()
        attachments.reset()
    }
}
