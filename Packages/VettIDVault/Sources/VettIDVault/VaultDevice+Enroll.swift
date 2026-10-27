import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDRelay

// Enrollment and pairing (VAULT-MESSAGING §11.3, §6.7): vault.enrolled, the first handshake and device.paired. The
// sealed requests of the alternate channel (enroll, transfer, recovery) come with onboarding.
extension VaultDevice {
    /// Pins [pr] as this device's vault, with a fresh keyring. Callers hold ``mem``.
    func setVault(_ pr: Principal) {
        st.vault = VaultRecord(
            ik: Base64s.encodeStd(pr.ik), kem: Base64s.encodeStd(pr.kem.bytes), relayURL: pr.relay.url,
            mailbox: pr.relay.mailbox, relayPk: Base64s.encodeStd(pr.relay.pk)
        )
        keyring = Keyring()
        for a in awaiting { a.resp.abort() }
        awaiting.removeAll()
    }

    /// vault.enrolled (§11.3), sealed to this device's KEM key: pins the vault and gives this device its first token.
    func handleEnrolled(_ env: Envelope, sender: [UInt8], _ t: Date) throws {
        let (padded, _) = try Envelope.openSealed(env, key: secrets.kem)
        let inner = try Inner.decode(padded, .sealed)
        guard inner.type == "vault.enrolled" else { return }
        // Only while an enrollment is pending (its nonce kept) or before any vault is pinned: a later vault.enrolled
        // would re-pin the vault and drop the session (chosen; not in the spec, which a valid attestation covers).
        guard mem.withLock({ alt().enrollNonce != nil || st.vault == nil }) else { return }
        let o = try StrictJson.parseObject(inner.body)
        let bundle = try o.base64("vault_bundle")
        let bo = try StrictJson.parseObject(bundle)
        guard try bo.uint("v", min: 1, max: 1) == 1, try bo.uint("suite", min: 2, max: 2) == 2 else { return }
        let pr = try Principal.parse(bo)
        guard Ed25519.equalPublic(sender, pr.relay.pk) else { return }
        let vid = try o.string("vault_id")
        guard let attempt = enrolledAttempt(try o.optString("attestation"), bundle: bundle, vaultID: vid, t) else { return }
        let tok = try o.string("token")
        let stateSeq = try o.optUint("state_seq", min: 0, max: StrictJson.maxSafeInteger)
        let ok: Bool = mem.withLock {
            setVault(pr)
            guard let exp = heldFromVault(tok) else {
                st.vault = nil
                return false
            }
            st.vault?.token = tok
            st.vault?.tokenExpMs = Self.ms(exp)
            st.vaultID = vid
            let a = alt()
            if a.enrollNonce != nil { setAlt(a.applyingEnrolled(stateSeq: stateSeq, attempt: attempt)) }
            return true
        }
        if ok { publish(VaultMessage(inner: inner)) }
    }

    /// §11.3: nonce = the app's, user_data over the vault bundle, the PCRs the request was sealed to, fresh. Checked
    /// against the newest request of the pending enrollment and then its earlier ones (``AltState/enrollAttempts``):
    /// the request whose answer was lost may be the one that made the vault. Returns the request it answers (the
    /// newest when the check is skipped, or when no enrollment is pending and no vault is pinned yet), nil when none
    /// passes. Only a request of the vault [vaultID] names is answered by it.
    func enrolledAttempt(_ attestationB64: String?, bundle: [UInt8], vaultID: String, _ t: Date) -> AltState.EnrollAttempt?? {
        let a = mem.withLock { alt() }
        let check: EnrolledAttestationCheck
        switch cfg.enrolledAttestation {
        case .verify(let c): check = c
        #if DEBUG
        case .skipForTests:
            guard let cur = a.currentEnroll else { return .some(nil) }
            return cur.vaultID == vaultID ? .some(cur) : nil
        #endif
        }
        guard let b64 = attestationB64, let doc = try? Base64s.decodeStd(b64) else { return nil }
        for attempt in a.enrollAttempts where attempt.pcrs.utf8.count == Self.pcrHex * 3 && attempt.vaultID == vaultID {
            let p = Array(attempt.pcrs)
            let pcrs = EnrolledPCRs(
                pcr0: String(p[0..<Self.pcrHex]), pcr1: String(p[Self.pcrHex..<(2 * Self.pcrHex)]),
                pcr2: String(p[(2 * Self.pcrHex)...])
            )
            if (try? check(doc, bundle, attempt.nonce, pcrs, t)) != nil { return .some(attempt) }
        }
        return nil
    }

    /// Drops the pending enrollment (a refused one, or one that never reached the member API): a later
    /// `vault.enrolled` for it is not accepted. Only while no vault is pinned.
    public func abandonEnrollment() async throws {
        try await lock.withLock {
            let changed: Bool = mem.withLock {
                guard st.vault == nil else { return false }
                let a = alt()
                guard a.currentEnroll != nil || !a.enrollPrior.isEmpty else { return false }
                setAlt(a.withoutEnrollment())
                return true
            }
            if changed { try save() }
        }
    }

    /// The first handshake's hs.resp: activates the epoch, keeps the token and sends hs.fin.
    func handleResp(_ raw: [UInt8], sender: [UInt8], _ t: Date) async throws {
        let (res, v): (InitiatorResult, VaultRecord) = try mem.withLock {
            guard let i = ini else { throw VaultStateError(message: "no handshake") }
            let res: InitiatorResult
            do {
                res = try i.handleResp(raw, collectSender: sender, now: t)
            } catch let e as CryptoError where e.kind == .used {
                ini = nil
                throw e
            }
            ini = nil
            // (IOS-PLAN 0.1.39 §4.9) The recovered phone's handshake the vault answered: its `ctx` names the registration whose
            // attested key the vault binds. Saved with the epoch.
            if let ctx = st.recovery?.pairing { st.recoveryPairedCtx = ctx }
            if let tok = res.resp.token, let exp = heldFromVault(tok) {
                st.vault?.token = tok
                st.vault?.tokenExpMs = Self.ms(exp)
            }
            if res.epoch.suite > st.vault?.suite ?? 0 { st.vault?.suite = res.epoch.suite }
            keyring.activate(res.epoch, now: t)
            return (res, try requireVault())
        }
        try save()
        try await depositToVault(v, res.fin)
        if let s = res.sas {
            mem.withLock { sas = s }
            sasBroadcast.emit(s)
        }
    }

    /// Waits for vault.enrolled (§11.3), which pins the vault and gives this device its first token.
    public func awaitEnrolled(timeout: TimeInterval = awaitDefault) async throws {
        _ = try await awaitEvent("vault.enrolled", timeout: timeout)
    }

    /// Runs the first app's handshake (purpose app, ctx = vault id; it carries the SAS commitment, but the vault answers
    /// it without approval, so no code is shown) and waits for device.paired.
    public func completeEnrollment(timeout: TimeInterval = awaitDefault) async throws {
        try await lock.withLock {
            let (v, ctx): (VaultRecord, String) = try mem.withLock {
                let v = try requireVault()
                guard let ctx = st.recovery?.recoveryID ?? st.vaultID else { throw VaultStateError(message: "no vault id") }
                guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
                return (v, ctx)
            }
            try await startInit(purpose: .app, ctx: ctx, depositToken: v.token)
            try save()
        }
        _ = try await awaitPaired(timeout: timeout)
    }

    /// Waits for `device.paired`, or `device.pair.rejected`, which ends the wait with ``PairingRejected``. Returns a
    /// transfer's `user_guid` (0.17.0, §6.7.1), or nil.
    func awaitPaired(timeout: TimeInterval) async throws -> String? {
        let ev = try await awaitEvent(of: ["device.paired", Self.typePairRejected], timeout: timeout)
        if ev.type == Self.typePairRejected { throw PairingRejected() }
        let o = ev.object
        let guid: String? = try await lock.withLock {
            let guid = applyPaired(o)
            try save()
            return guid
        }
        return guid
    }

    /// Applies a `device.paired` to the state: the device and vault ids, the release, a transfer's attested App Attest key (the
    /// one the vault bound now, IOS-PLAN §6.2) and its `user_guid`. Idempotent. Callers hold ``lock`` and save.
    @discardableResult
    func applyPaired(_ o: JsonObject) -> String? {
        let guid: String? = mem.withLock {
            st.deviceID = VaultJSON.string(o, "device_id")
            if let vid = VaultJSON.string(o, "vault_id") { st.vaultID = vid }
            if let rel = VaultJSON.string(o, "release"), rel.utf8.count == Self.pcrHex,
               let num = VaultJSON.int(o, "release_number"), num > 0 {
                var a = alt()
                a.release = rel
                a.releaseNumber = UInt64(num)
                setAlt(a)
            }
            var a = alt()
            if let k = a.transferAttestKeyID {
                a.enrolledAttestKeyID = k
                a.transferAttestKeyID = nil
                setAlt(a)
            }
            if let g = Self.transferUserGuid(o) { st.transferUserGuid = g }
            return Self.transferUserGuid(o)
        }
        mem.withLock { isPaired = true }
        return guid
    }

    func startInit(
        purpose: Purpose, ctx: String, depositToken: String, profile: [UInt8]? = nil, at: Date? = nil,
        deviceAttest: DeviceAttest? = nil, id: String? = nil, apiKey: [UInt8]? = nil, unlockSecret: [UInt8]? = nil
    ) async throws {
        let v = try mem.withLock { try requireVault() }
        let tok = try mintForVault()
        let i = try Initiator.create(InitiatorConfig(
            purpose: purpose, ctx: ctx, identity: secrets.identity, staticKem: secrets.kem.publicKey, relay: relayAddr,
            token: tok, profile: profile, deviceAttest: deviceAttest, apiKey: apiKey, unlockSecret: unlockSecret,
            responderIk: try Base64s.decodeStd(v.ik),
            responderEk: try KemPublicKey.parse(try Base64s.decodeStd(v.kem)), responderRelayKey: try Base64s.decodeStd(v.relayPk),
            policy: .vaultToDevice, id: id, now: at ?? now()
        ))
        try refuseSending()
        _ = try await relayFor(v.relayURL).deposit(mailboxID: v.mailbox, token: depositToken, payload: i.envelope)
        mem.withLock {
            ini?.abort()
            ini = i
        }
    }

    static let userGuidMax = 128

    /// The member's `user_guid` from a transfer's `device.paired` (`transfer: true`, 0.17.0 §6.7.1): 1–128 printable
    /// ASCII characters, so that it fits the unlock's signing string (§11.4). Nil for a plain pairing, or when it is
    /// absent or fails the check.
    static func transferUserGuid(_ o: JsonObject) -> String? {
        guard VaultJSON.bool(o, "transfer") == true, let g = VaultJSON.string(o, "user_guid") else { return nil }
        let b = Array(g.utf8)
        guard (1...userGuidMax).contains(b.count), b.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return g
    }

    // MARK: - The Protean Credential (§3.5): what the credential operations keep on the device

    func keepUTKs(_ utks: [UtkRecord]) async throws {
        try await lock.withLock {
            mem.withLock { st.utks.append(contentsOf: utks) }
            try save()
        }
    }

    func keepCredential(blob: String, version: Int64) async throws {
        try await lock.withLock {
            mem.withLock { st.credential = CredentialCopy(blob: blob, version: version) }
            try save()
        }
    }

    /// Puts back a UTK that was taken but never sent (nothing reached the vault), first in the pool. A UTK that was sent is
    /// never put back: the vault spends it whatever it answers (VAULT-MESSAGING 0.52.0 §3.5.4).
    func returnUTK(_ u: UtkRecord) async throws {
        try await lock.withLock {
            mem.withLock { if !st.utks.contains(where: { $0.id == u.id }) { st.utks.insert(u, at: 0) } }
            try save()
        }
    }

    /// Takes an unexpired UTK from the pool, or nil when it is empty.
    func takeUTK() async throws -> UtkRecord? {
        try await lock.withLock {
            let t = Self.ms(now())
            let u: UtkRecord? = mem.withLock {
                while !st.utks.isEmpty {
                    let u = st.utks.removeFirst()
                    if u.expiresAtMs > t { return u }
                }
                return nil
            }
            try save()
            return u
        }
    }

    /// Whether the vault has shown this app its signer (`device.list`, §11.7.1) and no unlock was refused since.
    public var signerSeen: Bool { mem.withLock { st.signerSeen } }

    /// Records what this app's own `device.list` entry said about its signer.
    public func markSignerSeen(_ seen: Bool) async throws {
        try await lock.withLock {
            let changed: Bool = mem.withLock {
                guard st.signerSeen != seen else { return false }
                st.signerSeen = seen
                return true
            }
            if changed { try save() }
        }
    }
}
