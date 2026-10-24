import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay

// The recovery open (VAULT-MESSAGING §11.14.6, release R) on the registered phone: the sealed `vault.recovery.open`, its
// result, which pins the vault and gives the phone its first token, and the first handshake that follows. Mirrors
// vettid-android `VaultDevice`'s "recovery open" section. The recovery of before release R (§11.11.5 steps 1 to 3:
// a recovering app's unlock, `credential.recover`) is not implemented on iOS (IOS-PLAN ID8).
extension VaultDevice {
    /// (Release R, §11.14.6) The vault is pinned from a recovery's result but the recovery is not finished (the first
    /// handshake or the credential did not complete): the vault answered `ok` and made this phone its app. Ends with
    /// ``finishRecoveryOpen()``.
    public var recoveryOpenedNotFinished: Bool { mem.withLock { st.vault != nil && st.recovery != nil } }

    /// While recovering: the vault's `credential_backup` from this app's unlock result (§11.11.5 step 1, a vault before
    /// release R); nil when not reported. A release R vault does not send it (§11.14.6 "What is removed in release R").
    public var recoveryCredentialBackup: Bool? { mem.withLock { st.recovery?.credentialBackup } }

    /// `vault.recovery.open`: the registered phone's PIN, password and unlock secret, with an open token for its own
    /// mailbox (the vault's relay key is not known yet), signed by its identity key.
    public func prepareRecoveryOpen( // swiftlint:disable:this function_parameter_count
        userGuid: String, pin: String, password: String, unlockSecret: [UInt8], enclave: VerifiedEnclave,
        manifest: ReleaseManifest, attester: Attester
    ) async throws -> SealedRequest {
        try await lock.withLock {
            let (vid, rec): (String, RecoveryRecord) = try mem.withLock {
                guard let vid = st.vaultID else { throw VaultStateError(message: "no vault id") }
                guard let rec = st.recovery else { throw VaultStateError(message: "no recovery registered") }
                return (vid, rec)
            }
            let tok = try own.mintOpenToken(audience: cfg.relayURL, ttl: Self.openTokenTTL)
            return try AltRequests.buildRecoveryOpen(
                userGuid: userGuid, vaultID: vid, recoveryID: rec.recoveryID, pin: pin, password: password,
                unlockSecret: unlockSecret, enclave: enclave, manifest: manifest, attester: attester, ik: secrets.identity,
                token: tok, now: now()
            )
        }
    }

    /// Opens `vault.recovery.open.result`; on `ok` pins the vault from the bundle and keeps the token, so that the phone's
    /// first handshake follows (`hs.init` with `ctx` = `recovery_id`, then `credential.get`).
    public func openRecoveryOpenResult(_ raw: [UInt8], requestID: String) async throws -> RecoveryOpen.Result {
        try await lock.withLock {
            let body = try AltResults.open(raw, kem: secrets.kem, type: RecoveryOpen.typeResult, requestID: requestID)
            let r = try RecoveryOpen.Result.parse(body)
            guard r.ok else { return r }
            try mem.withLock {
                if let bundle = r.vaultBundle { try adoptBundle(bundle) }
                if st.vault != nil {
                    let exp = heldFromVault(r.token).map(Self.ms) ?? 0
                    st.vault?.token = r.token
                    st.vault?.tokenExpMs = exp
                }
                // As after an unlock: the state floor, and the release with its header_seq for the next unlock's rollback
                // check (min_header_seq).
                setAlt(AltRequests.applyRecoveryOpen(
                    alt(), stateSeq: r.stateSeq, headerSeq: r.headerSeq, release: r.release, releaseNumber: r.releaseNumber
                ))
            }
            try save()
            return r
        }
    }

    /// After an `ok` open: `hs.init` with purpose `app` and `ctx` = `recovery_id` (accepted without approval, as the first
    /// app's), deposited with the token from the result. The recovery stays registered until the credential is here too
    /// (``finishRecoveryOpen()``).
    public func completeRecoveryOpen(timeout: TimeInterval = awaitDefault) async throws {
        try await lock.withLock {
            let (v, rec): (VaultRecord, RecoveryRecord) = try mem.withLock {
                let v = try requireVault()
                guard let rec = st.recovery else { throw VaultStateError(message: "no recovery registered") }
                guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
                return (v, rec)
            }
            try await startInit(purpose: .app, ctx: rec.recoveryID, depositToken: v.token)
            try save()
        }
        _ = try await awaitPaired(timeout: timeout)
    }

    /// (Release R) The recovered phone holds the credential: the recovery is over (``recoveryOpenedNotFinished`` false).
    public func finishRecoveryOpen() async throws {
        try await lock.withLock {
            try mem.withLock {
                guard st.deviceID != nil else { throw VaultStateError(message: "not paired") }
                st.recovery = nil
            }
            try save()
        }
    }
}
