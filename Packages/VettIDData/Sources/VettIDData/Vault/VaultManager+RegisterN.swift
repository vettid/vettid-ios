import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay
import VettIDVault

/// One register of the new identity N of a phone that could not tell (IOS-PLAN 0.1.35 §4.9 "A failed register").
struct RegisterAttempt {
    /// A register of N was posted for the same code before: the member API answers any repeat `409 recovery_not_available` once the
    /// first is recorded, and the vault a repeat it took `used`.
    let repeated: Bool
    /// N never had a registration accepted or unknown: only then does a `401` at the register drop it.
    let firstN: Bool
}

// The register of N (IOS-PLAN 0.1.35 §4.9; VAULT-MESSAGING 0.62.0 §11.14.6 "Two identities at most"), the first time or again for a
// further recovery: the same K, the same N keys, the new code, and a new App Attest key. Mirrors vettid-android
// `registerNewIdentity`.
extension VaultManager {
    /// The sealed `vault.recovery.register` of N, whose answers decide whether N registered for this recovery:
    /// - `ok`, or a repeat answered `409 recovery_not_available` or `used` that the status signed with K shows `registered`:
    ///   registered for this recovery;
    /// - a first attempt that failed before reaching the vault (`503`, `429`, `409 recovery_not_available`, the network), or a
    ///   readable refusal: not registered, and N's registration of before is its own again (the same N, K and code may try again);
    /// - a `401` of the register itself: N is dropped when it never had a registration accepted or unknown; otherwise nothing is
    ///   dropped. A new claim then says whether K became a key in use;
    /// - any other failure: N is kept as unknown (it may have registered).
    func registerN(
        _ s: VaultSession, _ code: RecoveryCode, _ claimed: Claimed, _ attempt: RegisterAttempt,
        claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        // The new recovery's record keeps the rule's identities; the phone-secret record is the earlier open's.
        var account = LocalAccount(userGuid: claimed.userGuid, vaultID: code.vaultID, emailHint: claimed.emailHint)
        account.recoveryRegistered = true
        await convertLegacyUnanswered(s.device)
        try resetRecord(account, carryRule: true)
        publishAccount()
        let rec = record.generation
        let built = SentFlag()
        let result: RecoveryResult
        do {
            result = try await postRegisterN(s, code, guid: claimed.userGuid, since: rec, built: built)
        } catch {
            if built.value, registerNLeftNUnregistered(error, attempt) { try await s.device.restoreRecoveryRegistration() }
            return try await registerNFailed(error, attempt, claimed, claimAgain: claimAgain)
        }
        if result.ok { return try registeredN(claimed) }
        if attempt.repeated, result.code == "used" { return try await maybeRegistered(claimed) }
        if built.value { try await s.device.restoreRecoveryRegistration() }
        return .refused(code: result.code ?? "retry")
    }

    /// The register itself; [built] is set once the request (and N's new registration) was made.
    private func postRegisterN(
        _ s: VaultSession, _ code: RecoveryCode, guid: String, since rec: Int, built: SentFlag
    ) async throws -> RecoveryResult {
        let (secrets, attester) = (phoneSecrets, config.attester)
        return try await s.alt.recoveryRegister(
            vaultID: code.vaultID, attester: attester,
            build: { [weak self] e in
                // IOS-PLAN ID8 (§11.10.9): release R's recovery only, and only with `recovery_offered`.
                let caps = e.descriptor.capabilities
                try ReleasePath.requireR(caps)
                guard ReleasePath.recoveryOffered(caps) else { throw VaultFailure(.notSupported, code: Self.codeNotOffered) }
                var (made, _) = try secrets.reuseOrCreateNoting(keyVault: code.vaultID)
                Bytes.wipe(&made.secret)
                await self?.noteRegistering(e, since: rec)
                let req = try await s.device.prepareRecoveryRegister(
                    userGuid: guid, code: code, enclave: e, attester: attester, keepingHistory: true
                )
                built.set()
                return req
            },
            open: { raw, rid in try s.device.openRecoveryResult(raw, requestID: rid) }
        )
    }

    /// Whether a register of N that threw left N not registered for its code (N's registration of before is then put back): the
    /// request did not reach the vault on a first attempt, or was refused for certain. Never for a repeat that may have registered,
    /// nor for a `401` to an N that never registered (``dropNewIdentity()`` drops it all).
    private func registerNLeftNUnregistered(_ error: any Error, _ attempt: RegisterAttempt) -> Bool {
        if let f = error as? VaultFailure, f.code == Self.codeNotOffered { return true }
        if let e = error as? MemberApiError, !e.queued {
            switch e.code {
            case MemberApiError.recoveryUnavailable: return true
            case MemberApiError.recoveryNotAvailable: return !attempt.repeated
            // A re-registered N may be the identity the vault adopted: its registration of before stays.
            case MemberApiError.unauthorized where e.status == 401: return !attempt.firstN
            default: break
            }
        }
        return !attempt.repeated && Self.failedBeforeVault(error)
    }

    /// A register of N that threw: what it answers (``registerN(_:_:_:_:claimAgain:)``).
    private func registerNFailed(
        _ error: any Error, _ attempt: RegisterAttempt, _ claimed: Claimed, claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        if let f = error as? VaultFailure, f.code == Self.codeNotOffered { return .refused(code: Self.codeNotOffered) }
        if let e = error as? MemberApiError, !e.queued {
            switch e.code {
            case MemberApiError.recoveryUnavailable: return .refused(code: Self.codeNoBackup)
            case MemberApiError.recoveryNotAvailable:
                return attempt.repeated ? try await maybeRegistered(claimed) : .refused(code: Self.codeNotAvailable)
            case MemberApiError.unauthorized where e.status == 401:
                // A `401` of the register itself queued nothing: K is no claim key, and an N that never registered goes.
                if attempt.firstN { try await dropNewIdentity() }
                return try await claimedAgainAfterUnauthorized(e, claimAgain: claimAgain)
            default: break
            }
        }
        throw error
    }

    /// A claim key that has since become a key in use is no claim key: a new claim says whether. Anything else decides nothing: the
    /// `401` stands, and everything is kept.
    private func claimedAgainAfterUnauthorized(
        _ e: MemberApiError, claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        do {
            _ = try await claimAgain()
        } catch let again as MemberApiError where again.code == MemberApiError.keyInUse {
            return try await claimKeyInUse()
        } catch {
            // Nothing more is known.
        }
        throw e
    }

    /// A failure that did not reach the vault: the member API's `503` (`release_starting`, `vault_unavailable`) or `429` to the
    /// request itself, or the network.
    nonisolated static func failedBeforeVault(_ error: any Error) -> Bool {
        if let e = error as? MemberApiError { return !e.queued && (e.status == 429 || e.status == 503) }
        if let f = error as? VaultFailure { return f.kind == .network }
        return error is URLError || error is RelayError
    }

    /// N registered for this recovery: the rule's decisions are made again from the next reads.
    private func registeredN(_ claimed: Claimed) throws -> RecoveryRegistration {
        try persistRecord(record.generation) {
            guard var ct = $0.couldNotTell else { return }
            (ct.ended, ct.unlock, ct.unlockByReads, ct.bothEnded, ct.transferIncomplete) = (false, false, false, false, false)
            (ct.refusalsSinceMs, ct.refusalsForMs) = (nil, nil)
            $0.couldNotTell = ct
            $0.couldNotTellRead = nil
        }
        usesPhoneSecret = phoneSecrets.inUse
        config.attestStartOver?.set(recovering: true)
        phase = .setup(.recovering)
        return .registered(emailHint: claimed.emailHint)
    }

    /// A repeat refused because the first copy may have been recorded: N keeps the new registration, and the status signed with K
    /// decides (`registered`: registered for this recovery). Otherwise N stays unknown, and the code may be tried again.
    private func maybeRegistered(_ claimed: Claimed) async throws -> RecoveryRegistration {
        guard await ruleRead() == .registered else { return .refused(code: "retry") }
        return try registeredN(claimed)
    }
}
