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
        userGuid: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester, unlockSecret: [UInt8]?
    ) async throws -> SealedRequest {
        try await lock.withLock {
            // §7.1: the app's open token for the vault's first deposit, ≤ 10 min.
            let open = try own.mintOpenToken(audience: cfg.relayURL, ttl: Self.openTokenTTL)
            let b = try AltRequests.buildEnroll(
                userGuid: userGuid, pin: pin, enclave: enclave, manifest: manifest, attester: attester, app: appIdentity(),
                openToken: open, state: mem.withLock { alt() }, now: now(), unlockSecret: unlockSecret
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
        try EnrollResult.parse(try AltResults.open(raw, kem: secrets.kem, type: AltResults.typeEnrollResult, requestID: requestID))
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
            // A recovering app does not know the vault's relay key yet: an open token for its mailbox (§11.11.5).
            let tok = recovering ? try own.mintOpenToken(audience: cfg.relayURL, ttl: Self.openTokenTTL) : try mintForVault()
            // §11.7.1: the device key's chain goes with every unlock until the vault has shown this app its signer (an
            // Android key; an iOS attester has no chain, so nothing is added).
            var opts = options
            opts.sendChain = !signerSeen
            let b = try AltRequests.buildUnlock(
                userGuid: userGuid, vaultID: vid, pin: pin, enclave: enclave, manifest: manifest, attester: attester,
                ik: secrets.identity, token: tok, state: state, options: opts, now: now()
            )
            mem.withLock { pendingUnlock = b.pending }
            try save()
            return b
        }
    }

    public func openUnlockResult(_ raw: [UInt8]) async throws -> UnlockResult {
        try await lock.withLock {
            // Taken before anything else, as vettid-android does: a result that does not apply still ends this unlock.
            guard let p = mem.withLock({ () -> PendingUnlock? in
                defer { pendingUnlock = nil }
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
                if let bundle = r.vaultBundle, st.vault == nil, st.recovery != nil { try adoptBundle(bundle) }
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

    /// The vault bundle of a recovering app's unlock result pins the vault (§11.11.5). Callers hold ``mem``.
    func adoptBundle(_ bundle: [UInt8]) throws {
        let bo = try StrictJson.parseObject(bundle)
        guard try bo.uint("v", min: 1, max: 1) == 1, try bo.uint("suite", min: 2, max: 2) == 2 else {
            throw VaultStateError(message: "vault bundle")
        }
        setVault(try Principal.parse(bo))
    }

    /// vault.recovery.register (§11.11.3): builds the request and records the recovery.
    public func prepareRecoveryRegister(
        userGuid: String, code: RecoveryCode, enclave: VerifiedEnclave, attester: Attester
    ) async throws -> SealedRequest {
        try await lock.withLock {
            guard mem.withLock({ st.vault == nil }) else { throw VaultStateError(message: "already paired with a vault") }
            let req = try AltRequests.buildRecoveryRegister(
                userGuid: userGuid, code: code, enclave: enclave, attester: attester, app: appIdentity(), now: now()
            )
            mem.withLock {
                st.signerSeen = false // a new attestation is a new key (§11.7.1)
                st.vaultID = code.vaultID
                st.recovery = RecoveryRecord(recoveryID: code.recoveryID, requestID: req.requestID)
            }
            try save()
            return req
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
