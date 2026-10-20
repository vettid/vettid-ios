import Foundation
import VettIDVault

// Delete vault (VAULT-MESSAGING §12.5, `vault.delete` by the holder) and what follows it on this phone. Mirrors
// vettid-android `VaultManager.deleteVault` and `afterVaultDeleted`.
//
// A lost answer (chosen; not in the spec, which is silent on it): the vault may have deleted itself while this phone
// heard nothing. Its relay mailbox is then gone and nothing answers again, so a retry would wait in vain. The request
// carries an `exp` (10 minutes on the vault's clock), so that a copy waiting in a locked vault's mailbox never applies
// after it. After no answer the app asks the member API (`GET /api/vault/status`): an explicit "no vault" right after the
// member's confirmed deletion means it applied, and VettID's data on this phone is erased as after the vault's own answer; the vault still
// listed more than a minute after `exp` means it did not and never will; anything else is undecided
// (``codeDeleteUnconfirmed``): the screen says so and offers to check again (nothing sent to the vault) besides a new try.
// `device.unlinked{vault_deleted}` opens "being deleted" (IOS-PLAN §4.2, ``enterDeleting(expOnPhone:)``), which waits
// for the member API to no longer list the vault, so the member is never stuck.
extension VaultManager {
    /// The code of a deletion whose answer was lost and which the member API did not yet show as done.
    public nonisolated static let codeDeleteUnconfirmed = "delete_unconfirmed"

    /// `vault.delete` (§12.5) with the PIN and the credential password: irreversible; the screen confirms first. After the
    /// vault's answer VettID's data on this phone is erased (the welcome screen follows, as a new vault needs a new setup code). Refused
    /// while a change of PIN or password is unresolved (§11.14.9 step 2: a credential operation). Runs to its end even if
    /// the caller is cancelled: a deletion that applied always erases VettID's data here.
    public func deleteVault(pin: String, password: String) async throws {
        let task = Task { @MainActor [weak self] () throws -> Bool in
            guard let self else { throw CancellationError() }
            return try await deleteOnce(pin: pin, password: password)
        }
        guard try await task.value else { throw VaultFailure(.noResponse, code: Self.codeDeleteUnconfirmed) }
    }

    /// After a deletion whose answer was lost (in this process): what the member API says now (``DeletionCheck``), VettID's
    /// data on this phone erased when the vault is gone. Nothing is sent to the vault. Without such a deletion: undecided (the root's
    /// "no vault" screen decides then).
    public func checkVaultDeleted() async throws -> DeletionCheck {
        guard let pending = deleteUnanswered else { return .undecided }
        let task = Task { @MainActor [weak self] () -> DeletionCheck in
            guard let self else { return .undecided }
            switch await vaultListed() {
            case false?:
                await afterVaultDeleted()
                return .deleted
            case true? where pending.passed(config.uptime()):
                deleteUnanswered = nil
                return .notDeleted
            default:
                return .undecided
            }
        }
        return await task.value
    }

    /// One deletion: true when VettID's data on this phone was erased after it (or, its answer lost, the vault said it is
    /// being deleted: IOS-PLAN §4.2), false when its answer was lost and it is undecided.
    private func deleteOnce(pin: String, password: String) async throws -> Bool {
        ownDelete = OwnDelete()
        defer { ownDelete = nil }
        let answered: Bool = try await guarded {
            // It carries the PIN: refused while the PIN is uncertain too (§11.14.9 step 3).
            try await decideFirst(carriesPin: true)
            let s = try await openSession()
            let api = try openApi(s)
            let exp = try await api.requestExp()
            ownDelete?.expOnPhone = UnansweredDelete.onPhone(exp, device: s.device, now: config.now())
            do {
                try await api.deleteVault(pin: pin, password: password, exp: exp)
                return true
            } catch is RequestUnanswered {
                deleteUnanswered = UnansweredDelete(exp: exp, device: s.device, uptime: config.uptime(), now: config.now())
                return false
            } catch let e as VaultOpError {
                // The vault answered: an earlier deletion's copy, deposited before this one, was handled before it and did
                // not delete the vault.
                deleteUnanswered = nil
                throw e
            }
        }
        if !answered, await vaultListed() != false {
            // The vault's `device.unlinked{vault_deleted}` came meanwhile: the deletion applied; wait for the member API.
            guard ownDelete?.unlinked == true else { return false }
            enterDeleting(expOnPhone: ownDelete?.expOnPhone)
            return true
        }
        await afterVaultDeleted()
        return true
    }

    /// Whether the member API lists the vault: false when it says explicitly that the account has none; nil when it
    /// could not be asked.
    private func vaultListed() async -> Bool? {
        do {
            return try await vaultStatus() != nil
        } catch {
            return nil
        }
    }

    /// The vault is gone: VettID's data on this phone (its keychain items, Secure Enclave keys and files; never anything
    /// else of the phone) is erased through ``HolderWatch`` (one wipe at a time, the crash-safe wipe of
    /// ``WipeRun``), or, in a build that cannot wipe, its keys for the vault are forgotten and the record reset, as
    /// vettid-android's `afterVaultDeleted` does.
    func afterVaultDeleted() async {
        deleteUnanswered = nil
        if wiper != nil, let holder {
            await holder.wipeNow()
            return
        }
        do {
            try await dropSession(forget: true, vaultGone: true)
        } catch {
            // The vault no longer exists: a forget that fails (the relay, a key) must not keep the member on it. The
            // record is reset all the same; keys left behind are the next setup's to replace (a redeem drops a stored
            // device first).
        }
        try? resetRecord(LocalAccount())
        phase = .signedOut
    }
}

/// A deletion whose answer was lost, and when no copy of it can apply any more (chosen; not in the spec). The deadline is
/// a minute past the request's `exp`, counted on this phone's monotonic clock from the vault's own time as the device saw
/// it at the send: never on the phone's wall clock, so that a clock set ahead, a reopened session or a restart (which
/// forgets this) never concludes "not deleted" while a waiting copy could still apply.
struct UnansweredDelete {
    /// The monotonic time after which no copy can apply; nil when the device had no time from the vault (never decided).
    let deadline: TimeInterval?
    /// The request's `exp` on the phone's clock (IOS-PLAN §4.2: the bound of a vault being deleted).
    let expOnPhone: Date

    @MainActor
    init(exp: Date, device: VaultDevice, uptime: TimeInterval, now: Date) {
        deadline = device.knowsVaultTime
            ? uptime + exp.timeIntervalSince(device.vaultNow()) + VaultManager.decidedAfterExp
            : nil
        expOnPhone = Self.onPhone(exp, device: device, now: now)
    }

    /// [exp] (the vault's clock) on the phone's clock at [now]; as it is when the device had no time from the vault.
    @MainActor
    static func onPhone(_ exp: Date, device: VaultDevice, now: Date) -> Date {
        device.knowsVaultTime ? now.addingTimeInterval(exp.timeIntervalSince(device.vaultNow())) : exp
    }

    /// Whether the deadline has passed at the monotonic time [now].
    func passed(_ now: TimeInterval) -> Bool { deadline.map { now > $0 } ?? false }
}
