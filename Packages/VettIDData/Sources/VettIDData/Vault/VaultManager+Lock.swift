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

    func relayLock(unlockID: String?) async -> RelayLock {
        guard let s = await manager?.lockSession() else { return .noAnswer }
        do {
            try await s.api.lock(unlockID: unlockID, timeout: timing.relayAnswer, validFor: timing.relayValid)
            return .locked
        } catch let e as VaultOpError where e.code == VaultApi.codeStaleLock {
            return .stale
        } catch {
            return .noAnswer
        }
    }

    func memberLock(unlockID: String?) async -> MemberLock {
        guard let s = await manager?.lockSession(), let vaultID = s.device.vaultID else { return .noAnswer }
        do {
            let slot = try await s.alt.lock(vaultID: vaultID, atMost: timing.memberWait, unlockID: unlockID)
            switch slot.status {
            case Slot.queued: return .noAnswer
            // A code is read only beside "done" (MEMBER-API 2.10.1 "Locks").
            case Slot.done: return .answered(done: true, code: slot.code)
            default: return .answered(done: false)
            }
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

    /// At the process start: the last unlock's time, kept on the phone (``LockNotices``), and where the name of a `vault.locking`
    /// is compared with (release L: the device's current `unlock_id`, which a new process learns at its first status read).
    func resumeLockNotices() {
        lockNotices.current = { [weak self] in self?.session?.device.unlockID }
        lockNotices.opened(at: record.value.lastOpenedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }

    /// Whether this phone is held locked: a lock is pending, or one ended because the vault was opened again since.
    public var lockHoldsPhone: Bool { lockGuard.holdsPhone }

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
    public func lock() async throws { try await lockWith(session?.device.unlockID) }

    /// (Release L, "Lock it now" on ``LockNotice/openedAgain``) A fresh lock of the vault as it is now, bound to its current
    /// opening when the vault's status names it, unconditional otherwise (VAULT-LOCK Q3); made and retried as any lock. The
    /// value the last lock was bound to is never reused: it was stale. Returns once it is asked for.
    public func lockAgain() async {
        // Pending, durably and unbound, before anything is read: a tap is never lost to a slow vault or a screen that goes
        // away. The rest runs in a task of its own.
        let mine = beginLock(unlockID: nil)
        let wait = config.lockTiming.lockStatusWait
        let sleep = config.lockTiming.sleep
        Task { @MainActor [weak self] in
            guard let self else { return }
            // At most the wait for the opening running now; then bound to it, before the first attempt.
            let id = await Self.within(wait, sleep: sleep) { [weak self] in
                await LockAgain.unlockID {
                    guard let s = await self?.lockSession() else { return nil }
                    return try await s.api.status().unlockId
                }
            }
            let keeper: LockKeeper = lockGuard.keeper
            keeper.rebind(mine, to: id)
            try? await locking.run(lock: { _ = await keeper.ask(mine) }, after: {})
        }
    }

    /// What [read] answers, or nil if it does not answer within [wait].
    private static func within(
        _ wait: TimeInterval, sleep: @escaping LockSleep, _ read: @escaping @MainActor @Sendable () async -> String?
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await read() }
            group.addTask {
                try? await sleep(.milliseconds(Int64(wait * 1000)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The member's lock, bound to [unlockID] (nil: as before release L).
    private func lockWith(_ unlockID: String?) async throws {
        let mine = beginLock(unlockID: unlockID)
        let keeper: LockKeeper = lockGuard.keeper
        try await locking.run(lock: { _ = await keeper.ask(mine) }, after: {})
    }

    /// This phone locked at once, and the lock pending durably (``LockKeeper/begin(unlockID:)``); its number.
    private func beginLock(unlockID: String?) -> Int {
        // A phase being computed now (a refresh, the end of an unlock) is not published after this.
        lockGeneration += 1
        // The record's writes still on their way for an operation that began before the lock are dropped.
        record.bumpGeneration()
        unlockWindow = nil
        // IOS-PLAN §4.4 (1): "Lock vault" on "This phone can't use your vault" returns to the unlock screen.
        credentialRequired = false
        credentialRequiredResend = nil
        phase = .locked
        // Pending, durably, before anything else is done for the lock: a process that dies from here on starts locked.
        // (Release L) Bound to the vault's current unlock as this phone knows it (memory only: from the unlock result or the
        // last vault.status); without one, as before L (VAULT-LOCK §3.6, Q3).
        return lockGuard.keeper.begin(unlockID: unlockID)
    }
}
