import Foundation

// (VAULT-MESSAGING 0.73.0 §3.6.5) The app's estimate of the tries left, and the read of the vault's state that sends no
// check. As vettid-android `OwnerCheckManager` and `CheckSink`.
extension OwnerCheckManager {
    /// The member API's `state` of a vault the host saw lock (MEMBER-API; VAULT-MESSAGING §11.5 "A stopped vault is locked").
    nonisolated static let stateLocked = "locked"
    /// (VAULT-MESSAGING §3.6.4) The operations that verify the PIN as an owner check does, other than the check itself: a
    /// `bad_pin` or `bad_password` to one counts as a failed check, and one with no answer may have counted. As
    /// vettid-android `CheckSink.COUNTED`.
    nonisolated static let countedTypes: Set<String> = [
        "pin.change", "credential.password.change", "device.transfer.approve", "vault.delete", "wallet.caps.raise", "item.reveal",
        "account.name.set", "vault.secret.renew", "credential.reset", "credential.create",
    ]

    func failed(_ e: VaultFailure) async -> OwnerCheckOutcome {
        switch e.code {
        case Self.codeBadPin:
            let (left, estimated) = await checksLeftAfterFailure()
            return .badPin(checksLeft: left, estimated: estimated)
        case Self.codeBadPassword:
            let (left, estimated) = await checksLeftAfterFailure()
            return .badPassword(checksLeft: left, estimated: estimated)
        // A backoff's wait: the error body's `retry_after` (VAULT-MESSAGING 0.17.0 §3.6.1, §10.1); 0 from older vaults.
        case Self.codeBackoff: return .backoff(retryAfterSeconds: e.retryAfterSeconds)
        default:
            let r = OwnerCheckOutcome.failed(e.kind, code: e.code)
            // (VAULT-MESSAGING 0.73.0 §3.6.5) A check sent that got no answer may have counted at the vault.
            return r.isUnanswered ? .failed(e.kind, code: e.code, estimatedLeft: spendEstimate()) : r
        }
    }

    /// A failed check counts (§3.6.4): `failures` is read again, for at most ``statusAfterFailure`` (the tenth locks the
    /// vault, and then nothing answers). The count, and whether it is only the app's estimate (``estimate``; VAULT-MESSAGING
    /// 0.73.0 §3.6.5): the read after the failure did not come. Only a count the vault gave is kept in the view and on disk.
    func checksLeftAfterFailure() async -> (Int?, Bool) {
        let wait = KickableWait()
        let read = FreshStatus()
        Task { @MainActor [weak self] in
            if let r = try? await self?.readStatus(), r.fresh { read.view = r.view }
            wait.kick()
        }
        await wait.wait(Self.statusAfterFailure, sleep: sleep)
        if let after = read.view {
            // The tenth failure locks the vault (§3.6.4), whether or not `vault.locking` has arrived yet: the app says so at
            // once, from the vault's own count only (a count estimated here could show an open vault as locked).
            // (chosen; not in the spec) Also when this answer is stale (a newer unlock cleared the flag): the vault did lock.
            if after.checksLeft <= 0 { markLocked(causeKnown: true) }
            return (after.checksLeft, false)
        }
        return (spendEstimate(), true)
    }

    /// (VAULT-MESSAGING 0.73.0 §3.6.5) An unlock or a start: a count is read next, and until then none is known; a read of
    /// the vault's state that started before is dropped.
    func forgetEstimate() {
        estimate = 0
        probeEpoch += 1
    }

    /// One try less in the estimate (never below 0); the new estimate.
    func spendEstimate() -> Int {
        estimate = max(estimate - 1, 0)
        return estimate
    }

    /// (VAULT-MESSAGING §3.6.4, 0.73.0 §3.6.5) An operation that verifies the PIN as the check does ended: answered
    /// `bad_pin` or `bad_password` (it counted), or with no answer (it may have). Either spends a try of the estimate; an
    /// operation outside ``countedTypes`` changes nothing. As vettid-android `CheckSink`.
    func countedEnded(type: String) {
        if Self.countedTypes.contains(type) { _ = spendEstimate() }
    }

    /// The relay connection came back (``VaultManager``).
    func onRelayReconnected() { relayReconnects += 1 }

    /// The vault is known locked; [causeKnown]: by ten wrong checks (`vault.locking{owner_check}`, or an estimate of 0). A
    /// cause already known is never downgraded while the vault stays locked (a read may finish after `vault.locking`).
    func markLocked(causeKnown: Bool) {
        lockCauseUnknown = !causeKnown && (!lockedByOwnerCheck || lockCauseUnknown)
        lockedByOwnerCheck = true
    }

    /// Nothing says the vault is locked (an unlock, a passed check, a wipe).
    func markOpen() {
        lockedByOwnerCheck = false
        lockCauseUnknown = false
    }

    public func probeVault(lockCauseKnown: Bool) async -> VaultProbe {
        let started = probeEpoch
        // An answer to `vault.status`, whatever it says of the check, means the vault is open (the relay is the vault's own
        // voice). As long as a failure waits for it.
        let wait = KickableWait()
        let read = FreshStatus()
        Task { @MainActor [weak self] in
            if (try? await self?.readStatus()) != nil { read.answered = true }
            wait.kick()
        }
        await wait.wait(Self.statusAfterFailure, sleep: sleep)
        let answered = read.answered
        // The member API's `unlocked` is not an answer (the host saw a lease, not the enclave); only `locked` is taken.
        let api = answered ? nil : await memberState()
        // The member locked the vault, or it was wiped or unlocked, during the read: the result is stale and dropped.
        if started != probeEpoch || Task.isCancelled { return .noAnswer }
        if answered { return .open }
        guard api == Self.stateLocked else { return .noAnswer }
        markLocked(causeKnown: lockCauseKnown)
        onFoundLocked()
        return .locked
    }
}
