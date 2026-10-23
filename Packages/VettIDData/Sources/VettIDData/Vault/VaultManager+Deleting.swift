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
// re-reads the status on a schedule up to a bound (``DeletionWatch``) and, once the vault is no longer listed (`{vault:
// null}`, or `401` to the app key), erases VettID's data on this phone as after a deletion (``afterVaultDeleted()``)
// and shows the one-time notice on "no vault". Nothing is sent to the vault meanwhile: no session opens.
//
// (Chosen; not in the spec) A deletion this phone sent and the vault answered erases this phone at once, as before: the
// answer says that it applied. The event during this phone's own deletion is left to it: an answer erases, a lost answer
// opens this state with the request's `exp` in the bound.
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
        deletionReads.start(until: marker.until, readFirst: false)
    }

    /// A start that found the marker: "being deleted" before anything else, and a read at once; past the bound, the
    /// "still finishing" state without a new timer.
    func resumeDeleting(_ m: DeletingMarker) -> AppPhase {
        guard deletion == nil else { return .deleting }
        closeForDeleting()
        deletion = VaultDeletion(since: m.since, until: m.until, slow: config.now() >= m.until)
        deletionReads.start(until: m.until, readFirst: true)
        return .deleting
    }

    /// Check again (after the bound; a second tap waits for the first), and a return to the foreground: one read.
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

    /// One read of the member API's status for a vault being deleted (§4.2 point 3).
    private func readDeletionStatus() async -> DeletionRead {
        do {
            return try await vaultStatus() == nil ? .gone : .listed
        } catch let e as MemberApiError where e.code == MemberApiError.unauthorized {
            // The row, and with it the app key, was removed.
            return .gone
        } catch {
            return .unreachable
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
