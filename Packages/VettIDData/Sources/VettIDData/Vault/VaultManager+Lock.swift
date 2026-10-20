import Foundation
import VettIDAltChan
import VettIDVault

/// How the vault manager reaches the vault for the member's lock (``LockPorts``): the relay's `vault.lock` in the device's
/// session, the member API's lock route, and the member API's status. None of them throws.
@MainActor
final class ManagerLockPorts: LockPorts {
    weak var manager: VaultManager?
    private let timing: LockTiming

    init(timing: LockTiming) {
        self.timing = timing
    }

    var relayValidFor: Duration { .milliseconds(Int64(timing.relayValid * 1000)) }

    func relayLock() async -> Bool {
        guard let s = await manager?.lockSession() else { return false }
        do {
            try await s.api.lock(timeout: timing.relayAnswer, validFor: timing.relayValid)
            return true
        } catch {
            return false
        }
    }

    func memberLock() async -> MemberLock {
        guard let s = await manager?.lockSession(), let vaultID = s.device.vaultID else { return .noAnswer }
        do {
            let slot = try await s.alt.lock(vaultID: vaultID, atMost: timing.memberWait)
            return slot.status == Slot.queued ? .noAnswer : .answered(done: slot.status == Slot.done)
        } catch let e as MemberApiError where e.status == Self.tooMany {
            return .limited(retryAfter: .seconds(e.retryAfterSeconds))
        } catch {
            return .noAnswer
        }
    }

    func unlocked() async -> Bool? {
        guard let m = manager, await m.lockSession() != nil else { return nil }
        do {
            return try await m.vaultStatus()?.state == VaultManager.stateUnlocked
        } catch {
            return nil
        }
    }

    private static let tooMany = 429
}

// The member's lock (VAULT-LOCK as vettid-android implements it: pending, durably, until the vault has acknowledged it or
// its status says it is locked; tried again until then; never after a newer unlock). The rules are ``LockGuard``'s.
extension VaultManager {
    /// The code of an operation refused because a lock is pending: the vault counts as locked.
    public nonisolated static let codeLockPending = "lock_pending"

    public var lockNotice: LockNotice { lockGuard.keeper.notice }

    public func retryLock() { lockGuard.keeper.retryNow() }

    public func dismissLockNotice() { lockGuard.keeper.dismissConfirmed() }

    /// Whether a lock is pending (the phone counts as locked).
    public var lockPending: Bool { lockGuard.pending }

    /// The session a lock is sent through: only for a vault this phone holds (a paired device).
    func lockSession() async -> VaultSession? {
        guard let s = try? await storedSession(), s.device.deviceID != nil else { return nil }
        return s
    }

    /// The vault client for an operation on the open vault: refused (`lock_pending`) while a lock is pending.
    func openApi(_ s: VaultSession) throws -> VaultApi {
        guard lockGuard.admits() else { throw VaultFailure(.other, code: Self.codeLockPending) }
        return s.api
    }

    /// Something to finish while the vault still collects, before the member's lock (a call's hang-up, later rows): quick,
    /// never calling ``lock()``; all hooks together get ``LockSequence/hookBudget``.
    public func onBeforeLock(_ hook: @escaping @MainActor () async throws -> Void) { locking.addHook(hook) }

    /// Locks the vault. **A lock once asked for completes**: it runs in a task of its own, so a caller that goes away only
    /// stops waiting. This phone is locked from the first line, in every outcome; whether the vault is locked is known
    /// only when it acknowledged or its status says so (``lockNotice``). An unconfirmed lock is not an error: it is
    /// pending, durably, and tried again.
    public func lock() async throws {
        // A phase being computed now (a refresh, the end of an unlock) is not published after this.
        lockGeneration += 1
        // The record's writes still on their way for an operation that began before the lock are dropped.
        record.bumpGeneration()
        unlockWindow = nil
        // IOS-PLAN §4.4 (1): "Lock vault" on "This phone can't use your vault" returns to the unlock screen.
        credentialRequired = false
        phase = .locked
        // Pending, durably, before anything else is done for the lock: a process that dies from here on starts locked.
        let keeper: LockKeeper = lockGuard.keeper
        let mine = keeper.begin()
        try await locking.run(lock: { _ = await keeper.ask(mine) }, after: {})
    }
}
