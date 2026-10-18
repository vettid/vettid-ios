import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDVault

/// The opened unlock result as the phone secret's tries judge it (``PhoneSecrets/unlock(isolation:attempt:)``).
extension UnlockOutcome: SecretCheckedAnswer {
    public var code: String? { result.code }
}

/// Which of the phone's secrets an unlock carries.
enum UnlockSecretPath {
    /// The current record, then the candidates and the pending epoch-1 records (``PhoneSecrets/unlock(isolation:attempt:)``).
    case current
    /// The replaced records, only on the member's tap (``PhoneSecrets/tryEarlierSecret(isolation:attempt:)``).
    case earlier
}

// The unlock (VAULT-MESSAGING §11.4) over the alternate channel with the phone's unlock secret (§11.14.1), the release
// check before the PIN (§11.10.6) and what the result says (§11.8 backoff, §11.10.4 release moves, §11.11.4 recovery,
// §13.2 rollback). Mirrors vettid-android `VaultManager.preflight`, `unlockOnce`, `unlockStep` and `unlockWithSecret`.
extension VaultManager {
    nonisolated static let updateMoved = "moved"
    nonisolated static let updateAbandoned = "abandoned"
    nonisolated static let updateRefused = "refused"
    /// ``unlockWithEarlierSecret(pin:)`` with no earlier secret that the vault answered.
    public nonisolated static let codeNoEarlierSecret = "no_earlier_secret"

    /// The release check before the PIN (§11.10.6). IOS-PLAN ID8: an instance without `recovery_r` is refused here
    /// already ("This vault's release is too old for the iPhone app"), before any PIN is asked for.
    public func preflight() async throws -> PreflightInfo {
        try await guarded {
            let s = try await openSession()
            let p = try await s.alt.preflight(s.device.altState)
            try ReleasePath.requireR(p.capabilities)
            return PreflightInfo(
                routed: Self.view(p.routed), lastNumber: p.lastNumber, softwareUpdated: p.softwareUpdated, rollback: p.rollback,
                offer: p.offer.map(Self.view), between: p.between.map(Self.view)
            )
        }
    }

    public func unlock(pin: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt {
        await unlockStep(pin: pin, options: Self.options(approve, cancelRecovery: cancelRecovery))
    }

    /// A locked vault past its owner-check deadline (§3.6.5): the unlock, then the check with [pin] and [password] before
    /// the app opens, so that the member types both once. The check itself comes with I1.7b
    /// (``ownerCheckAfterUnlock(pin:password:)``).
    public func unlockWithCheck(pin: String, password: String, approve: ReleaseView?, cancelRecovery: Bool) async throws -> UnlockAttempt {
        await unlockStep(pin: pin, options: Self.options(approve, cancelRecovery: cancelRecovery)) { [weak self] in
            await self?.ownerCheckAfterUnlock(pin: pin, password: password)
        }
    }

    /// (Release R, ANDROID-PLAN "Other screens") An unlock with `cancel_recovery`, then at once the owner check with the
    /// PIN and the password, which records that the member is present (§11.14.5). The check comes with I1.7b.
    public func unlockCancellingRecovery(pin: String, password: String, approve: ReleaseView?) async throws -> UnlockAttempt {
        await unlockStep(pin: pin, options: Self.options(approve, cancelRecovery: true)) { [weak self] in
            await self?.ownerCheckAfterCancelledRecovery(pin: pin, password: password)
        }
    }

    /// (iPhone, IOS-PLAN §6.3 item 5) Whether the earlier-secret step can be offered: a replaced record exists.
    public var earlierSecretOffered: Bool { (try? phoneSecrets.hasEarlierSecret()) ?? false }

    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step, only on the member's tap on the "this phone no longer holds
    /// the keys" screen: an unlock with [pin] and each replaced record, newest first, each once. Only `ok`, or
    /// `transfer_incomplete`, makes that record current again.
    public func unlockWithEarlierSecret(pin: String) async throws -> UnlockAttempt {
        await unlockStep(pin: pin, options: UnlockOptions(), path: .earlier)
    }

    /// A recovery in progress, from `GET /api/vault/status` (MEMBER-API "Vault"), for the unlock screen.
    public func recovery() async throws -> RecoveryView? {
        try await guarded {
            guard let st = try await vaultStatus(), let state = st.recoveryState else { return nil }
            return RecoveryView(state: state, availableAt: st.recoveryAvailableAt ?? "")
        }
    }

    // MARK: - One unlock

    static func options(_ approve: ReleaseView?, cancelRecovery: Bool) -> UnlockOptions {
        UnlockOptions(approve: approve.map { Approval(toPcr0: $0.pcr0, toRelease: $0.number) }, cancelRecovery: cancelRecovery)
    }

    /// One unlock (§11.4). After `update: moved` it unlocks again at once (§11.10.6). Never beside a lock attempt; once the
    /// vault opened, no older lock is ever sent (``LockKeeper``). A failure before the sealed result (network, status,
    /// timeout, unreadable result) is never proof of anything ([holder]); a sealed `unknown_device` is.
    func unlockStep(
        pin: String, options: UnlockOptions, path: UnlockSecretPath = .current, beforeOpen: @MainActor () async -> Void = {}
    ) async -> UnlockAttempt {
        do {
            try prepared()
        } catch {
            let f = VaultFailures.map(error) as? VaultFailure
            return .failed(f?.kind ?? .other, code: f?.code)
        }
        // §6.7.1 (0.17.0): a phone a transfer set up from an older vault release has no user_guid (§11.4 needs it).
        guard !record.value.userGuid.isEmpty else { return .failed(.notSupported, code: UnlockAttempt.codeNoUserGuid) }
        // Read before the unlock: a lock asked for while it is on its way bumps it, and this unlock then opens nothing.
        let locks = lockGeneration
        let rec = record.generation
        let opened: (outcome: UnlockOutcome, session: VaultSession)
        do {
            opened = try await lockGuard.keeper.unlocking(opened: { $0.outcome.ok }) {
                try await guarded {
                    let s = try await openSession()
                    var out = try await unlockWithSecret(s, pin: pin, options: options, path: path)
                    if out.ok, out.result.update?.result == Self.updateMoved {
                        // §11.10.6: after a move the vault is locked under the new release; unlock again, which reaches it.
                        out = try await unlockWithSecret(s, pin: pin, options: UnlockOptions(), path: .current)
                    }
                    // A sealed result: the enclave knows this phone; earlier relay refusals no longer count.
                    s.device.clearVaultRefusals()
                    refusals?.clear()
                    refusedByVault = false
                    return (out, s)
                }
            }
        } catch let f as VaultFailure {
            _ = holder?.onFailure(f) // never proof (a 503, paused or not, included)
            return .failed(f.kind, code: f.code, retryAfterSeconds: f.retryAfterSeconds)
        } catch {
            return .failed(.other, code: nil)
        }
        let r = opened.outcome.result
        guard r.ok else {
            if await holder?.onSealedUnlockResult(HolderPolicy.of(r)) == true { return .failed(.other, code: r.code) }
            return Self.refusal(r)
        }
        await didOpen(r, opened.session, locks: locks, record: rec, beforeOpen: beforeOpen)
        if let u = r.update, u.result == Self.updateRefused { return .updateRefused(code: u.code ?? Self.updateRefused) }
        return .success
    }

    /// The vault opened: the stale lock notices, the outbox, and the phase, unless a lock overtook this unlock.
    private func didOpen(
        _ r: UnlockResult, _ s: VaultSession, locks: Int, record rec: Int, beforeOpen: @MainActor () async -> Void
    ) async {
        // The vault is open as of the result's ts: a vault.locking from before it is stale, also after a restart.
        lockNotices.opened(at: r.at)
        if let at = r.at { try? record.opened(since: rec, atMs: Int64((at.timeIntervalSince1970 * 1000).rounded(.down))) }
        // A lock asked for while this unlock was on its way is the newer wish: still pending, or already confirmed by its
        // attempt, which followed the unlock at once. This phone stays locked, nothing is opened or flushed.
        let lockedSince = lockGuard.lockedWhatever(unlocked: true)
        let overtaken = lockedSince || locks != lockGeneration || rec != record.generation
        let guardRef = lockGuard
        Task {
            // No lock from before this unlock: none is ever left in the outbox (locks never go through it).
            _ = try? await s.device.dropFromOutbox(VaultManager.typeVaultLock)
            // Nothing but the lock while one is pending: what the member wrote earlier waits for the next unlock.
            if !overtaken && guardRef.admits() { await s.device.flushOutbox() }
        }
        if overtaken {
            if lockedSince { phase = .locked }
            return
        }
        if !s.device.recovering { await beforeOpen() }
        let p = afterUnlocked(s)
        if locks == lockGeneration, rec == record.generation, !lockGuard.lockedWhatever(unlocked: true) { phase = p }
    }

    nonisolated static let typeVaultLock = "vault.lock"

    /// The phase of a vault that just opened.
    func afterUnlocked(_ s: VaultSession) -> AppPhase {
        if s.device.recovering { return .setup(.recovering) }
        if s.device.credentialVersion == nil { return .setup(.needsCredential) }
        return record.value.setupComplete ? .unlocked : .setup(.finishing)
    }

    /// One unlock with this phone's unlock secret (release R, §11.14.1): the current record, then the candidates and the
    /// pending epoch-1 records after `device_secret` (``PhoneSecrets/unlock(isolation:attempt:)``), or the replaced
    /// records on the member's tap. IOS-PLAN ID8: an instance without `recovery_r` is refused before anything is built.
    private func unlockWithSecret(
        _ s: VaultSession, pin: String, options: UnlockOptions, path: UnlockSecretPath
    ) async throws -> UnlockOutcome {
        let guid = record.value.userGuid
        let attester = config.attester
        let attempt: ([UInt8]) async throws -> UnlockOutcome = { secret in
            try await s.alt.unlock(
                party: s.device, userGuid: guid, pin: pin, attester: attester, options: options,
                unlockSecretFor: { caps in
                    try ReleasePath.requireR(caps)
                    return secret
                }
            )
        }
        switch path {
        case .current:
            return try await phoneSecrets.unlock(attempt: attempt)
        case .earlier:
            switch try await phoneSecrets.tryEarlierSecret(attempt: attempt) {
            case .restored(let answer, let opened):
                // §6.3 item 5: after `ok`, a History entry and an immediate prompt for a new phone secret (I1.8).
                if opened { earlierSecretRestored() }
                return answer
            case .unchanged(let last?): return last
            case .unchanged(nil): throw VaultFailure(.deviceSecret, code: Self.codeNoEarlierSecret)
            }
        }
    }

    /// A sealed refusal (§11.4) as the screens see it.
    static func refusal(_ r: UnlockResult) -> UnlockAttempt { // swiftlint:disable:this cyclomatic_complexity
        let wait = Int64(clamping: r.retryAfterSeconds)
        return switch r.code {
        case "bad_pin": .badPin(retryAfterSeconds: wait)
        case "backoff": .backoff(retryAfterSeconds: wait)
        case "recovery_pending": .recoveryPending
        // §11.7.1: sealed, decided before the PIN; not a PIN failure and no backoff.
        case VaultDevice.codeSignerRefused: .signerRefused
        case "state_rollback": .stateRollback
        case "attestation": .failed(.attestation, code: r.code)
        case "manifest": .failed(.manifest, code: r.code)
        // Release R (§11.4, §11.14): decided before the PIN, not PIN failures.
        case UnlockEpoch.deviceSecret: .failed(.deviceSecret, code: r.code)
        case UnlockEpoch.transferIncomplete: .failed(.transferIncomplete, code: r.code)
        case "retry": .failed(.retry, code: r.code)
        default: .failed(.other, code: r.code)
        }
    }

    static func view(_ r: Release) -> ReleaseView {
        ReleaseView(number: r.number, pcr0: r.pcr0, status: r.status.rawValue, endsAt: r.endsAt, notes: r.notes)
    }
}
