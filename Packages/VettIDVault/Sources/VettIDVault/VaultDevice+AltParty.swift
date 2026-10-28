import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay

// The device side of the alternate channel (VAULT-MESSAGING §11.3, §11.4, §11.11.3): the sealed requests the device
// builds with its keys and state, and the results it opens and applies. Mirrors vettid-android `VaultDevice`'s
// `AltParty` conformance.
extension VaultDevice: AltParty {
    /// §11.11.4 (0.27.0): the unlock result code for a release that does not accept this key's recorded signer.
    public static let codeSignerRefused = "signer_refused"

    public func manifestSerialSeen() -> UInt64 { mem.withLock { alt().manifestSerial } }

    public func vaultIDForUnlock() -> String? { vaultID }

    func appIdentity() -> AppIdentity {
        AppIdentity(ik: secrets.identity.publicKey, kem: secrets.kem.publicKey, relay: relayAddr, name: name, apiKey: secrets.apiKey)
    }

    public func prepareEnroll( // swiftlint:disable:this function_parameter_count
        userGuid: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester, unlockSecret: [UInt8]?,
        vaultID: String
    ) async throws -> SealedRequest {
        try await lock.withLock {
            // §7.1: the app's open token for the vault's first deposit, ≤ 10 min.
            let open = try own.mintOpenToken(audience: cfg.relayURL, ttl: Self.openTokenTTL)
            let b = try AltRequests.buildEnroll(
                userGuid: userGuid, pin: pin, enclave: enclave, manifest: manifest, attester: attester, app: appIdentity(),
                openToken: open, state: mem.withLock { alt() }, now: now(), unlockSecret: unlockSecret, vaultID: vaultID
            )
            mem.withLock {
                st.signerSeen = false // a new attestation is a new key (§11.7.1)
                setAlt(b.state)
            }
            try save()
            return b.request
        }
    }

    public func openEnrollResult(_ raw: [UInt8], requestID: String) async throws -> EnrollResult {
        let r = try EnrollResult.parse(try AltResults.open(raw, kem: secrets.kem, type: AltResults.typeEnrollResult, requestID: requestID))
        if r.ok { opened(r.unlockID) }
        return r
    }

    public func prepareUnlock( // swiftlint:disable:this function_parameter_count
        userGuid: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester, options: UnlockOptions
    ) async throws -> BuiltUnlock {
        try await lock.withLock {
            // swiftlint:disable:next large_tuple
            let (vid, recovering, signerSeen, state): (String, Bool, Bool, AltState) = try mem.withLock {
                guard let vid = st.vaultID else { throw VaultStateError(message: "no vault id") }
                let recovering = st.vault == nil && st.recovery != nil
                guard st.vault != nil || recovering else { throw VaultStateError(message: "not paired with a vault") }
                return (vid, recovering, st.signerSeen, alt())
            }
            let issuedBefore = mem.withLock { st.issuedExpMs }
            // A recovering app does not know the vault's relay key yet: an open token for its mailbox (§11.11.5).
            let tok = recovering ? try own.mintOpenToken(audience: cfg.relayURL, ttl: Self.openTokenTTL) : try mintForVault()
            let issuedNow = mem.withLock { st.issuedExpMs }
            // §11.7.1: the device key's chain goes with every unlock until the vault has shown this app its signer (an
            // Android key; an iOS attester has no chain, so nothing is added).
            var opts = options
            opts.sendChain = !signerSeen
            // (Release L) Whatever opening was known is over or about to be: a lock asked for meanwhile names none (the
            // unlock's result names the new one); a status answer in flight no longer applies.
            opened(nil)
            let b = try AltRequests.buildUnlock(
                userGuid: userGuid, vaultID: vid, pin: pin, enclave: enclave, manifest: manifest, attester: attester,
                ik: secrets.identity, token: tok, state: state, options: opts, now: now()
            )
            mem.withLock {
                pendingUnlock = b.pending
                preparedUnlock = PreparedUnlock(requestID: b.pending.requestID, before: issuedBefore, minted: issuedNow)
            }
            try save()
            return b
        }
    }

    public func abandonPreparedUnlock(_ built: BuiltUnlock) async {
        await lock.withLock {
            let restored = mem.withLock { () -> Bool in
                guard let p = preparedUnlock, p.requestID == built.pending.requestID else { return false }
                preparedUnlock = nil
                if pendingUnlock?.requestID == p.requestID { pendingUnlock = nil }
                // Only the build's own mint is undone: a token issued since (a refresh while the request waited) stays.
                if st.issuedExpMs == p.minted { st.issuedExpMs = p.before }
                return true
            }
            // Kept as the build kept it. A failed write leaves the build's later expiry in the store: after a restart the
            // token is renewed later than it should be. The refusal that held the request back is what the caller reports.
            if restored { try? save() }
        }
    }

    public func openUnlockResult(_ raw: [UInt8]) async throws -> UnlockResult {
        try await lock.withLock {
            // Taken before anything else, as vettid-android does: a result that does not apply still ends this unlock.
            guard let p = mem.withLock({ () -> PendingUnlock? in
                defer {
                    pendingUnlock = nil
                    preparedUnlock = nil
                }
                return pendingUnlock
            }) else { throw VaultStateError(message: "no pending unlock") }
            let inner = try AltResults.openInner(raw, kem: secrets.kem, type: AltResults.typeUnlockResult, requestID: p.requestID)
            var r = try UnlockResult.parse(inner.body)
            r.at = inner.ts
            let next = try AltRequests.applyUnlock(mem.withLock { alt() }, p, r)
            try mem.withLock {
                setAlt(next)
                // §11.7.1: a refusal for the signer: the next unlock carries the chain again, until device.list shows one.
                st.signerSeen = st.signerSeen && r.code != Self.codeSignerRefused
                guard r.ok else { return }
                // The name of the opening: none when the vault did not resume (a move, §11.10.6) or is from before L. A
                // failed unlock sets none: building it cleared the name, and the next vault.status says what runs.
                opened(r.token == nil ? nil : r.unlockID)
                if let bundle = r.vaultBundle, st.vault == nil, st.recovery != nil { try adoptBundle(bundle) }
                // (IOS-PLAN 0.1.39 §4.9) An unlock's `ok` with the bundle is a lost ok: the invitation may be an earlier registration's.
                // Any unlock that carries the bundle while recovering counts, the one with this phone's own key after an unanswered
                // handshake too (chosen; not in the spec).
                if r.vaultBundle != nil, st.recovery != nil { st.recovery?.lostOk = true }
                // (IOS-PLAN 0.1.40 §4.9) The invitation the vault named, in the same save: each `ok` replaces the one before, and a
                // result without the member leaves none (the walk).
                if st.recovery != nil {
                    st.recovery?.invitation = r.invitationRecoveryID
                    st.recovery?.invitationSent = nil
                }
                // §11.11.5 step 1 (0.10.6): whether the password can recover the credential; kept across a restart.
                if st.recovery != nil, let backup = r.credentialBackup { st.recovery?.credentialBackup = backup }
                if let t = r.token, let exp = heldFromVault(t), st.vault != nil, Self.ms(exp) > st.vault?.tokenExpMs ?? 0 {
                    st.vault?.token = t
                    st.vault?.tokenExpMs = Self.ms(exp)
                }
            }
            try save()
            return r
        }
    }

    /// (IOS-PLAN §4.3) The unconfirmed move's marker changed by [change] (``AltState/moveFailed`` set, or the marker
    /// cleared), under the device's lock and stored before this returns; nothing is written when it is unchanged. The
    /// state as it is now.
    @discardableResult
    public func changeMoveMarker(_ change: @Sendable (AltState) -> AltState) async throws -> AltState {
        try await lock.withLock {
            let (before, after): (AltState, AltState) = mem.withLock {
                let a = alt()
                return (a, change(a))
            }
            guard after != before else { return before }
            mem.withLock { setAlt(after) }
            try save()
            return after
        }
    }

    /// The vault bundle of a recovering app's unlock result pins the vault (§11.11.5). Callers hold ``mem``.
    func adoptBundle(_ bundle: [UInt8]) throws {
        let bo = try StrictJson.parseObject(bundle)
        guard try bo.uint("v", min: 1, max: 1) == 1, try bo.uint("suite", min: 2, max: 2) == 2 else {
            throw VaultStateError(message: "vault bundle")
        }
        setVault(try Principal.parse(bo))
    }

    /// vault.recovery.register (§11.11.3): builds the request and records the recovery. [keepingHistory] (IOS-PLAN 0.1.38 §4.9,
    /// the new identity of a phone that could not tell, registered again for a new recovery): the history of the identity's opens
    /// stays, and the registration it replaces is kept for ``restoreRecoveryRegistration()``.
    public func prepareRecoveryRegister(
        userGuid: String, code: RecoveryCode, enclave: VerifiedEnclave, attester: Attester, keepingHistory: Bool = false
    ) async throws -> SealedRequest {
        try await lock.withLock {
            guard mem.withLock({ st.vault == nil }) else { throw VaultStateError(message: "already paired with a vault") }
            let req = try AltRequests.buildRecoveryRegister(
                userGuid: userGuid, code: code, enclave: enclave, attester: attester, app: appIdentity(), now: now()
            )
            mem.withLock {
                st.signerSeen = false // a new attestation is a new key (§11.7.1)
                st.vaultID = code.vaultID
                var record = RecoveryRecord(recoveryID: code.recoveryID, requestID: req.requestID)
                if keepingHistory, let before = st.recovery {
                    record.opens = before.opens
                    // Another register for the same code (a request sealed again, or a repeat) replaces what the first replaced:
                    // a repeat the vault answered was not recorded by the member API, so neither was the first.
                    let same = before.recoveryID == code.recoveryID
                    record.replaced = same ? before.replaced : ReplacedRecovery(recoveryID: before.recoveryID, requestID: before.requestID)
                    // (IOS-PLAN 0.1.39 §4.9) Every recovery this identity registered for is kept, newest last: the invitation an
                    // unlock's `ok` leaves may be an earlier registration's.
                    let earlier = before.registeredBefore
                    record.earlier = same || earlier.contains(before.recoveryID) ? earlier : earlier + [before.recoveryID]
                }
                st.recovery = record
            }
            try save()
            return req
        }
    }

    /// (IOS-PLAN 0.1.38 §4.9) A register that did not register (it failed before reaching the vault, or was refused): the
    /// registration it replaced is this identity's again, with the history of its opens; without one, the registration is
    /// forgotten (``dropRecoveryRegistration()``).
    public func restoreRecoveryRegistration() async throws {
        try await lock.withLock {
            let changed: Bool = mem.withLock {
                guard st.deviceID == nil, st.vault == nil, let now = st.recovery else { return false }
                if let back = now.replaced {
                    st.recovery = RecoveryRecord(
                        recoveryID: back.recoveryID, requestID: back.requestID, opens: now.opens,
                        earlier: now.registeredBefore.filter { $0 != back.recoveryID }
                    )
                } else {
                    st.recovery = nil
                    st.vaultID = nil
                }
                return true
            }
            if changed { try save() }
        }
    }

    /// Forgets a registration the enclave refused (§11.11.3), so that a new code can be tried.
    public func dropRecoveryRegistration() async throws {
        try await lock.withLock {
            let dropped: Bool = mem.withLock {
                guard st.deviceID == nil, st.vault == nil else { return false }
                st.recovery = nil
                st.vaultID = nil
                return true
            }
            if dropped { try save() }
        }
    }

    public func openRecoveryResult(_ raw: [UInt8], requestID: String) throws -> RecoveryResult {
        try RecoveryResult.parse(try AltResults.open(raw, kem: secrets.kem, type: AltResults.typeRecoveryResult, requestID: requestID))
    }
}
