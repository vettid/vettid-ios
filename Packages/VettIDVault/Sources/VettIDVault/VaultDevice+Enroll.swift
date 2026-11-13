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
        if ok { publishOnce(VaultMessage(inner: inner)) }
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
        var generation: UInt64 = 0 // this handshake, as ``handshakeGeneration`` counts it while it is the current one
        let (res, v): (InitiatorResult, VaultRecord) = try mem.withLock {
            guard let i = ini else { throw VaultStateError(message: "no handshake") }
            let res: InitiatorResult
            do {
                res = try i.handleResp(raw, collectSender: sender, now: t)
            } catch let e as CryptoError where e.kind == .used {
                ini = nil
                throw e
            }
            answeredInit = ObjectIdentifier(i)
            generation = handshakeGeneration
            ini = nil
            // (IOS-PLAN 0.1.39 §4.9) The recovered phone's handshake the vault answered: its `ctx` names the registration whose
            // attested key the vault binds. Saved with the epoch.
            if let ctx = st.recovery?.pairing { st.recoveryPairedCtx = ctx }
            keepTransferSas(res.sas)
            if let tok = res.resp.token, let exp = heldFromVault(tok) {
                st.vault?.token = tok
                st.vault?.tokenExpMs = Self.ms(exp)
            }
            if res.epoch.suite > st.vault?.suite ?? 0 { st.vault?.suite = res.epoch.suite }
            // A new pairing (enrollment, transfer, recovery) starts with its own epoch confirmed (§6.3.1), as dropPairing.
            st.vault?.confirmed = nil
            st.vault?.confirmAtMs = nil
            keyring.activate(res.epoch, now: t)
            return (res, try requireVault())
        }
        // The fin is kept in the outbox until the relay accepts it: a pairing or transfer code is spent by its handshake, and
        // an hs.fin that never arrives leaves the code burnt. It goes out after the lock (``afterLock(_:)``) and again at
        // each flush.
        let fin = try storeFin(res.fin, vault: v, epoch: res.epoch.ctx, at: t)
        // Kept, with its deposit and the code, when the handling's final write fails, whether or not its own write succeeded: the
        // handshake's state (the epoch, `ini`) is not undone, so the fin it owes is not either; an unsaved one stays in memory and
        // is stored by the next write, and its deposit waits for a write that works (``deliver``).
        mem.withLock { _ = memory.keptOnError.insert(fin.id) }
        // The code is shown once the fin has gone out, or, when the relay would not take it, is kept for the next flush.
        let shown = res.sas
        let mine = generation
        afterLock(keep: true) { [self] in
            do {
                // Held by the lock gate, it waits in the outbox, as after a passing failure.
                try await deliverQueued(fin)
            } catch let x as RelayError where Self.isTerminal(x) {
                // Refused for good: when the flow was told (``deliver``: the fin's first attempt), it gets no code.
                if mem.withLock({ finFailed }) { return }
            } catch {
                // A passing failure: the fin stays owed, and the code is shown.
            }
            if let s = shown { await show(s, generation: mine) }
        }
    }

    /// Shows the comparison code [s] of the handshake of [generation], only while it is the current one: a new one bumps
    /// ``handshakeGeneration``, and its flow must not be handed the old code.
    private func show(_ s: String, generation mine: UInt64) async {
        guard mem.withLock({ guard handshakeGeneration == mine else { return false }; sas = s; return true }) else { return }
        sasBroadcast.emit(s)
    }

    /// A transfer to this phone (unpaired, with the key its `hs.init` attested): its comparison code is saved with the
    /// handshake's epoch, in the same write as the `hs.fin` it owes (``DeviceState/transferSas``); it is handed out once
    /// shown, or after a restart (``transferSas``). Callers hold ``mem``.
    private func keepTransferSas(_ sas: String?) {
        guard st.deviceID == nil, alt().transferAttestKeyID != nil, let sas else { return }
        st.transferSas = sas
        sasRestored = false
    }

    /// Stores the `hs.fin` in the outbox, marked in flight until its deposit, and saves. Dropped when the token it is sent
    /// under expires (a minute past it, as the wait for an hs.resp is: a phone clock that runs ahead must not drop a fin the
    /// relay would still take), at the latest after a handshake's lifetime (chosen; not in the spec). Callers hold ``lock``.
    private func storeFin(_ fin: [UInt8], vault v: VaultRecord, epoch: String, at t: Date) throws -> OutboxEntry {
        let entry = mem.withLock {
            let limit = Self.ms(t.addingTimeInterval(Self.handshakeTTL))
            let expiry = heldFromVault(v.token).map { Self.ms($0.addingTimeInterval(Self.initGrace)) } ?? limit
            var e = OutboxEntry(
                id: Ulid.new(t), type: Self.typeHsFin, relayURL: v.relayURL, mailbox: v.mailbox, token: v.token,
                envelope: Base64s.encodeStd(fin)
            )
            e.dropAfterMs = min(expiry, limit)
            e.epochIDs = [epoch]
            st.outbox.append(e)
            outboxInFlight.insert(e.id) // until the deposit: a flush in between leaves it alone
            return e
        }
        // A failed save loses nothing: the entry stays in memory and is saved with the next write; its deposit waits for a save
        // that works (``deliver``). It stays marked: the deposit that follows always runs (``handle`` runs the after-lock work)
        // and its `deliver` unmarks it, so that no flush deposits the fin next to it. Save failures are treated as transient
        // (chosen; not in the spec).
        _ = try? save()
        #if DEBUG
        finStoredHook?(entry.id)
        #endif
        return entry
    }

    /// Waits for vault.enrolled (§11.3), which pins the vault and gives this device its first token.
    public func awaitEnrolled(timeout: TimeInterval = awaitDefault) async throws {
        _ = try await awaitEvent("vault.enrolled", timeout: timeout)
    }

    /// Runs the first app's handshake (purpose app, ctx = vault id; it carries the SAS commitment, but the vault answers
    /// it without approval, so no code is shown) and waits for device.paired.
    public func completeEnrollment(timeout: TimeInterval = awaitDefault) async throws {
        let prepared: PreparedInit = try await lock.withLock {
            let (v, ctx): (VaultRecord, String) = try mem.withLock {
                let v = try requireVault()
                guard let ctx = st.recovery?.recoveryID ?? st.vaultID else { throw VaultStateError(message: "no vault id") }
                guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
                return (v, ctx)
            }
            let p = try prepareInit(purpose: .app, ctx: ctx, depositToken: v.token)
            try save()
            return p
        }
        try await sendInit(prepared)
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

    /// An `hs.init` built and kept as the handshake in flight, not yet deposited (``sendInit(_:)``).
    struct PreparedInit {
        let initiator: Initiator
        let vault: VaultRecord
        let depositToken: String
        /// When the token the deposit uses expires, if it can be read (VAULT-MESSAGING §8.6, 0.83.0).
        let tokenExp: Date?
        /// Whether it is an open token (a pairing or transfer link's): only then is a `token_used` after a retry waited on.
        let tokenIsOpen: Bool
    }

    /// How long past the token's `exp` a retried `hs.init` answered `token_used` or `token_revoked` waits for the `hs.resp`
    /// that its first attempt may have brought (VAULT-MESSAGING §8.6, 0.83.0).
    static let initGrace: TimeInterval = 60
    /// Without a readable `exp` the wait is the pairing link's 10 minutes (§8.6).
    static let initWaitFallback: TimeInterval = 600

    /// Builds the `hs.init` and makes it the handshake in flight, so that an `hs.resp` that arrives before the deposit call
    /// returns finds it. Callers hold ``lock``, save, leave it, and then deposit with ``sendInit(_:)``: a slow relay must not
    /// hold the lock. The `hs.fin` of a handshake this one replaces is dropped.
    func prepareInit(
        purpose: Purpose, ctx: String, depositToken: String, profile: [UInt8]? = nil, at: Date? = nil,
        deviceAttest: DeviceAttest? = nil, id: String? = nil, apiKey: [UInt8]? = nil, unlockSecret: [UInt8]? = nil
    ) throws -> PreparedInit {
        let v = try mem.withLock { try requireVault() }
        let tok = try mintForVault()
        let i = try Initiator.create(InitiatorConfig(
            purpose: purpose, ctx: ctx, identity: secrets.identity, staticKem: secrets.kem.publicKey, relay: relayAddr,
            token: tok, profile: profile, deviceAttest: deviceAttest, apiKey: apiKey, unlockSecret: unlockSecret,
            responderIk: try Base64s.decodeStd(v.ik),
            responderEk: try KemPublicKey.parse(try Base64s.decodeStd(v.kem)), responderRelayKey: try Base64s.decodeStd(v.relayPk),
            policy: .vaultToDevice, id: id, now: at ?? now(), features: DeviceFeatures.all
        ))
        try refuseSending()
        let claims = (try? Base64s.decodeStd(v.relayPk)).flatMap { try? DepositTokens.verify(depositToken, issuer: $0) }
        #if DEBUG
        beforePrepareInitHook?()
        #endif
        mem.withLock {
            ini?.abort()
            ini = i
            answeredInit = nil
            handshakeGeneration &+= 1
            sas = nil // a code the old handshake's closure showed meanwhile is not the new flow's
            finFailed = false
            st.outbox.removeAll { $0.type == Self.typeHsFin }
            pairingHeldFin = nil
        }
        publishPairingHeld()
        return PreparedInit(
            initiator: i, vault: v, depositToken: depositToken, tokenExp: claims?.exp, tokenIsOpen: claims?.isOpen == true
        )
    }

    /// The `hs.fin` will not reach the vault: the waiting flows are told (``PairingNotCompleted``), and no code is shown.
    ///
    /// Only when the fin entry [owed] is still in the outbox: a new handshake removes the fins and resets the failure
    /// under ``mem`` in one step, and the check here is in the same step as the signal, so a fin of the old handshake cannot
    /// fail the new one.
    func notifyFinFailed(ifOwed owed: String) {
        let waiters: [OneShot<Bool>]? = mem.withLock {
            guard st.outbox.contains(where: { $0.id == owed }) else { return nil }
            finFailed = true
            sas = nil
            defer { inboxWaiters.removeAll() }
            return inboxWaiters
        }
        guard let waiters else { return }
        for w in waiters { w.complete(true) }
        sasBroadcast.emit("")
    }

    /// Whether the vault's `hs.resp` was handled for [p]'s handshake.
    private func answered(_ p: PreparedInit) -> Bool {
        mem.withLock { answeredInit == ObjectIdentifier(p.initiator) }
    }

    /// Deposits a prepared `hs.init`, outside the lock.
    ///
    /// - A deposit that fails after the vault's `hs.resp` was handled for this handshake did reach the vault: it is a
    ///   success, and nothing is undone.
    /// - `token_used` or `token_revoked` to a deposit of an open token (a pairing or transfer link's) that the relay client had
    ///   already tried before (``RelayError/afterRetry``) mean the first attempt may have been delivered: it waits for
    ///   `hs.resp` until the token's `exp` plus 60 s, at most 11 minutes (VAULT-MESSAGING §8.6, 0.83.0), and fails only then.
    ///   A standing token (enrollment, recovery) is not waited on: the rule is for the open token alone.
    /// - Any other failure drops the handshake, unless a newer one replaced it, and throws.
    func sendInit(_ p: PreparedInit) async throws {
        do {
            try refuseSending()
            let relay = relayFor(p.vault.relayURL)
            let payload = p.initiator.envelope
            let (box, token) = (p.vault.mailbox, p.depositToken)
            _ = try await relay.deposit(mailboxID: box, token: token, payload: payload)
        } catch {
            if answered(p) { return }
            if p.tokenIsOpen, let x = error as? RelayError, x.afterRetry,
               x.code == RelayError.tokenUsed || x.code == RelayError.tokenRevoked,
               (try? await waitForAnswer(p)) == true {
                return
            }
            #if DEBUG
            initRaceHook?(p.initiator)
            #endif
            // Answered or dropped is decided in one look: an `hs.resp` that lands now has set the answer and cleared the
            // handshake together, and a pairing that succeeded must not be undone.
            let reached: Bool = mem.withLock {
                if answeredInit == ObjectIdentifier(p.initiator) { return true }
                if ini === p.initiator {
                    p.initiator.abort()
                    ini = nil
                }
                return false
            }
            if reached { return }
            if p.tokenIsOpen, let x = error as? RelayError,
               [RelayError.tokenUsed, RelayError.tokenRevoked, RelayError.tokenExpired].contains(x.code) {
                throw OpenTokenRefused(relay: x)
            }
            throw error
        }
    }

    /// Waits until the handshake of [p] is answered (true), or it is gone, or the token's `exp` plus ``initGrace`` has passed
    /// by the device's clock, or 11 minutes have passed on the monotonic clock (false). Throws when cancelled.
    private func waitForAnswer(_ p: PreparedInit) async throws -> Bool {
        let cap = cfg.uptime() + Self.initWaitFallback + Self.initGrace
        let deadline = (p.tokenExp ?? now().addingTimeInterval(Self.initWaitFallback)).addingTimeInterval(Self.initGrace)
        while true {
            // Answered, or gone (dropped, rejected, replaced), read together: the answer clears the handshake.
            let (isAnswered, isGone): (Bool, Bool) = mem.withLock {
                (answeredInit == ObjectIdentifier(p.initiator), ini !== p.initiator)
            }
            if isAnswered { return true }
            if isGone || now() >= deadline || cfg.uptime() >= cap { return false }
            try await Task.sleep(nanoseconds: 250_000_000)
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

    /// Stores the blob; with [awaitingAck] its `credential.ack` is pending until the vault takes it (``ackSettled(_:)``).
    func keepCredential(blob: String, version: Int64, awaitingAck: Bool = false) async throws {
        try await lock.withLock {
            mem.withLock {
                st.credential = CredentialCopy(blob: blob, version: version)
                if awaitingAck { st.ackPending = version }
            }
            try save()
        }
    }

    /// How long a `credential.ack` is waited for, and how often one is tried again.
    static let ackWait: TimeInterval = 15
    static let ackRetryEvery: TimeInterval = 30
    static let ackTerminal: Set<String> = [
        CredentialOps.codeStaleCredential, "credential_frozen",
    ]

    /// Sends `credential.ack` for [version] once and, taken, settles it. Throws what the vault answers, the cancel, or
    /// ``OutboxHeld`` when the lock gate holds it (it stays pending).
    func sendAck(_ version: Int64) async throws {
        let body = JsonBuilder().uint("version", UInt64(version)).bytes()
        do {
            _ = try await opOnce("credential.ack", body: body, timeout: min(Self.ackWait, cfg.requestTimeout(for: "credential.ack")))
        } catch let e as VaultOpError where Self.ackTerminal.contains(e.code) {
            // The vault has moved past this version (`stale_credential`), or has frozen the credential (`credential_frozen`):
            // nothing more is sent for it (chosen; not in the spec). `forbidden` (a phone still recovering) and
            // `credential_required` (no holder yet) are passing states: the ack stays owed and is tried again at the usual rate.
            // `forbidden` still reaches the caller, who acts on it.
            try? await ackSettled(version)
            return
        }
        try? await ackSettled(version)
    }

    /// The `credential.ack` of the stored blob that an earlier one did not get through, best effort and outside the
    /// credential lock (an outbox flush: after an unlock, a return to the foreground or going to the background). An
    /// operation refused after the blob check (a wrong password) leaves the version unconfirmed, and so does one that
    /// presented the blob and succeeded: only `credential.ack` confirms a version. Not more often than every
    /// ``ackRetryEvery`` seconds.
    func sendPendingAck() async {
        guard let pending = ackPendingVersion else { return }
        guard credentialVersion == pending else {
            try? await ackSettled(pending)
            return
        }
        // Asked before the retry's time is taken: a held one does not count as tried (``requestMayGo(_:)``).
        guard await requestMayGo("credential.ack") else { return }
        let go: Bool = mem.withLock {
            let t = cfg.uptime()
            if let last = lastAckTry, t - last < Self.ackRetryEvery { return false }
            lastAckTry = t
            return true
        }
        guard go, !mem.withLock({ halted }) else { return }
        try? await sendAck(pending)
    }

    /// TEST ONLY: makes an outbox flush leave a pending `credential.ack` alone (it counts as just tried), or lets it go out.
    #if DEBUG
    public func holdBackAckRetries(_ hold: Bool) { mem.withLock { lastAckTry = hold ? cfg.uptime() : nil } }
    #endif

    /// Whether the stored blob's `credential.ack` is still to be sent.
    public var credentialAckPending: Bool { ackPendingVersion != nil }

    /// The version of the stored blob whose `credential.ack` is still to be sent, or nil.
    var ackPendingVersion: Int64? { mem.withLock { st.ackPending } }

    /// The blob of [version] is confirmed (or replaced): nothing is left to send for it.
    func ackSettled(_ version: Int64) async throws {
        try await lock.withLock {
            let changed: Bool = mem.withLock {
                guard st.ackPending == version else { return false }
                st.ackPending = nil
                return true
            }
            if changed { try save() }
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
