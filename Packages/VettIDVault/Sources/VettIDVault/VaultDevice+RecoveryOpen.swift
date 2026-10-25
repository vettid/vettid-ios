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

    /// The `recovery_id` this app is registered for, while recovering.
    public var recoveryID: String? { mem.withLock { st.recovery?.recoveryID } }

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
            let req = try AltRequests.buildRecoveryOpen(
                userGuid: userGuid, vaultID: vid, recoveryID: rec.recoveryID, pin: pin, password: password,
                unlockSecret: unlockSecret, enclave: enclave, manifest: manifest, attester: attester, ik: secrets.identity,
                token: tok, now: now()
            )
            // Kept, unanswered, before the request is posted, in one save: a kill between the two, or a response that is lost after
            // the member API took the request, must not lose an open that went out. A save that fails posts nothing.
            mem.withLock {
                guard var record = st.recovery else { return }
                record.opens = (record.opens ?? []) + [RecoveryOpenEntry(id: req.requestID, state: .unanswered)]
                st.recovery = record
            }
            do {
                try save()
            } catch {
                mem.withLock {
                    guard var record = st.recovery else { return }
                    record.opens?.removeAll { $0.id == req.requestID }
                    st.recovery = record
                }
                throw error
            }
            return req
        }
    }

    /// What is known of each open this identity built, oldest first (IOS-PLAN 0.1.34 §4.10).
    public var recoveryOpens: [RecoveryOpenEntry] { mem.withLock { st.recovery?.opens ?? [] } }

    /// The `request_id`s of the opens this identity built, newest first (IOS-PLAN 0.1.33 §4.9).
    public var recoveryOpenRequestIDs: [String] { recoveryOpens.reversed().map(\.id) }

    /// The `request_id`s of the opens that are unanswered, newest first.
    public var unansweredOpenRequestIDs: [String] { recoveryOpens.reversed().filter { $0.state == .unanswered }.map(\.id) }

    /// Whether an open of this identity is unanswered (sticky: an open stays so until its own answer proves otherwise, and a
    /// later refusal never changes an earlier open's entry), unless one was answered `ok`.
    public var recoveryOpenEverUnanswered: Bool {
        let opens = recoveryOpens
        return opens.contains { $0.state == .unanswered } && !opens.contains { $0.state == .ok }
    }

    /// Writes what became known of the open [id], durably (the newest when nil).
    public func markRecoveryOpen(_ id: String? = nil, _ state: RecoveryOpenEntry.State) async throws {
        try await lock.withLock {
            let changed: Bool = mem.withLock {
                guard var record = st.recovery, var opens = record.opens,
                      let i = id.flatMap({ id in opens.firstIndex { $0.id == id } }) ?? (opens.isEmpty ? nil : opens.count - 1),
                      opens[i].state != state else { return false }
                opens[i].state = state
                record.opens = opens
                st.recovery = record
                return true
            }
            if changed { try save() }
        }
    }

    /// A new identity starts from the floors the earlier one has seen (`min_state_seq`, `min_header_seq`, the release and the
    /// manifest serial), never below them (IOS-PLAN 0.1.33 §4.9; chosen; not in the spec).
    public func seedFloors(from other: AltState) async throws {
        try await lock.withLock {
            mem.withLock {
                var a = alt()
                a.stateSeq = max(a.stateSeq, other.stateSeq)
                a.manifestSerial = max(a.manifestSerial, other.manifestSerial)
                for (k, v) in other.headerSeq { a.headerSeq[k] = max(a.headerSeq[k] ?? 0, v) }
                if other.releaseNumber > a.releaseNumber {
                    a.release = other.release
                    a.releaseNumber = other.releaseNumber
                }
                setAlt(a)
            }
            try save()
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
