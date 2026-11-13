import Foundation
import VettIDCrypto
import VettIDRelay

// Receiving (VAULT-MESSAGING §8.2–§8.4, §6.5, §7): classification, dedupe, sessions, rekeys and tokens.
extension VaultDevice {
    /// Processes one collected message. Classification is by sender and recipient kid only (§13.6). A message of a
    /// rekey's new epoch that arrived before the rekey's `hs.fin` is neither recorded as seen nor acked
    /// (``LeaveUnacked``): the relay delivers it again, and it is opened once `hs.fin` has arrived (§6.3, §8.4).
    public func handle(_ m: RelayMessage) async throws {
        let after = AfterLockWork()
        do {
            try await AfterLockWork.$current.withValue(after) { try await handleLocked(m) }
        } catch {
            // The replies queued while handling are stored by the save that ends it, and go out only after it succeeded: when
            // the handling ended in an error (the save included), none is deposited (a rekey's `hs.resp` before its responder
            // is on disk would leave the device unable to read the new epoch after a restart), and the entries it put in the
            // outbox are taken out again.
            after.drop()
            await after.run() // what belongs to an entry the handling stored itself (an hs.fin and its code)
            throw error
        }
        // The replies to the vault go out after the lock: a relay that stalls holds up this message's ack, not the
        // answers to every other request. They are this call's own.
        await after.run()
    }

    private func handleLocked(_ m: RelayMessage) async throws {
        try await lock.withLock {
            let t = now()
            let before = mem.withLock {
                HandlingStart(
                    seen: st.seen, seenInner: st.seenInner, issuedExpMs: st.issuedExpMs,
                    outbox: Set(st.outbox.map(\.id)), awaiting: awaiting.map(\.resp), confirmAtMs: st.vault?.confirmAtMs
                )
            }
            mem.withLock { memory.keptOnError = [] }
            let fresh: Bool = mem.withLock {
                guard st.seen[m.msgID] == nil else { return false }
                st.seen[m.msgID] = Self.ms(t)
                Self.prune(&st.seen, t)
                return true
            }
            guard fresh else { return }
            do {
                try await handleFresh(m, t)
            } catch {
                // The message is not taken as handled (its ids are forgotten, so that the relay's redelivery is handled and
                // answered, not acked unanswered), and the entries the handling queued are taken out again, so that the
                // redelivery's answer is the only one: even one that another write happened to store. The exception is what
                // the handling stored by a write of its own (an `hs.fin`, ``memory.keptOnError``): it is on disk by that write.
                forgetHandling(before)
                throw error
            }
        }
    }

    /// What a handling can change in the state without a write of its own, as it was when the handling began.
    struct HandlingStart {
        let seen: [String: Int64]
        let seenInner: [String: Int64]
        let issuedExpMs: Int64
        let outbox: Set<String>
        let awaiting: [Responder]
        /// When `hs.confirm` was last queued: one the failed handling queued is taken out, so its time goes too.
        let confirmAtMs: Int64?
    }

    /// A failed handling is undone: its message ids are forgotten, the entries it queued are taken out (and are no longer in
    /// flight: their deposit was dropped with the handling's work after the lock), the standing token it minted is forgotten
    /// (the redelivery issues one), and the rekey responders it made are dropped (their `hs.resp` never went out).
    private func forgetHandling(_ before: HandlingStart) {
        mem.withLock {
            st.seen = before.seen
            st.seenInner = before.seenInner
            st.issuedExpMs = before.issuedExpMs
            // Unless the hs.confirm of an activation that stands is kept (``queueConfirmed(_:)``).
            if !st.outbox.contains(where: { $0.type == HsTypes.confirm && memory.keptOnError.contains($0.id) }) {
                st.vault?.confirmAtMs = before.confirmAtMs
            }
            let gone = Set(st.outbox.map(\.id)).subtracting(before.outbox).subtracting(memory.keptOnError)
            st.outbox.removeAll { gone.contains($0.id) }
            outboxInFlight.subtract(gone)
            let known: (Responder) -> Bool = { r in before.awaiting.contains { $0 === r } }
            for a in awaiting where !known(a.resp) {
                a.resp.abort()
                unsavedResps.remove(ObjectIdentifier(a.resp))
            }
            awaiting.removeAll { !known($0.resp) }
        }
    }

    private func handleFresh(_ m: RelayMessage, _ t: Date) async throws {
        do {
            try await process(m, t)
        } catch let e as CryptoError where e.kind == .early {
            mem.withLock { _ = st.seen.removeValue(forKey: m.msgID) }
            try save()
            throw LeaveUnacked(e.description)
        } catch is CryptoError, is TokenError {
            // dropped (§13.6: a message that does not verify changes nothing)
        } catch is RelayError, is URLError, is VaultStateError {
            // A reply to the vault that the relay refused or could not take (a token refresh, a rekey's answer, a
            // handshake's fin). The message itself was handled; it is acked and never handled again. Letting it out
            // would end the collector, and without the ack the same message would fail again at every start.
        }
        #if DEBUG
        await beforeFinalSave?()
        #endif
        try save()
    }

    static func prune(_ m: inout [String: Int64], _ t: Date) {
        let cutoff = ms(t.addingTimeInterval(-seenRetention))
        m = m.filter { $0.value >= cutoff }
    }

    func process(_ m: RelayMessage, _ t: Date) async throws { // swiftlint:disable:this cyclomatic_complexity function_body_length
        guard let sender = m.senderKey else { return }
        let raw = m.payload
        let env = try Envelope.parse(raw)
        if env.mode == .sealed {
            if env.recipientKid == secrets.kem.publicKey.kid {
                try handleEnrolled(env, sender: sender, t)
            } else if let i = mem.withLock({ ini }), env.recipientKid == i.ephKid {
                try await handleResp(raw, sender: sender, t)
            }
            return
        }
        guard let v = mem.withLock({ st.vault }) else { return }
        // §6.3: only the vault's relay key sends to a device.
        guard Ed25519.equalPublic(sender, try Base64s.decodeStd(v.relayPk)) else { return }
        let opened = mem.withLock { try? keyring.open(env, now: t) }
        guard let (inner, ep) = opened else {
            let activated: Bool = try mem.withLock {
                pruneAwaiting(t)
                let match = awaiting.firstIndex { $0.resp.kids.recipient == env.recipientKid && $0.resp.kids.sender == env.senderKid }
                guard let i = match else {
                    return false
                }
                // CryptoError.early: a message of the new epoch ahead of its hs.fin (handle leaves it for redelivery).
                let fr = try awaiting[i].resp.handleFin(raw, collectSender: sender, now: t)
                // A fin still owed follows its handshake's epoch into the rekey's.
                if let old = keyring.current()?.ctx {
                    for j in st.outbox.indices where st.outbox[j].epochIDs?.contains(old) == true {
                        if st.outbox[j].epochIDs?.contains(fr.epoch.ctx) != true { st.outbox[j].epochIDs?.append(fr.epoch.ctx) }
                    }
                }
                // §6.3.1 "Responder": activated at the verified hs.fin, hs.confirm queued in the same write.
                activateRekeyLocked(fr.epoch, t)
                awaiting.remove(at: i)
                return true
            }
            if activated { queueConfirmed(t) }
            return
        }
        resetRefusals() // the vault spoke to this device under its session
        // §6.3.1: any message but hs.fin tells which epoch the vault uses (a redelivered hs.fin of an active epoch opens here).
        if inner.type != Self.typeHsFin { noteConfirmed(ep, t) }
        if inner.type == Self.typeHsInit {
            try await handleRekey(raw, epoch: ep, sender: sender, t, inner: inner)
            return
        }
        // Not a request, so never answered; a device starts no rekey, so one confirms nothing here (§6.3.1).
        if inner.type == HsTypes.confirm { return }
        do {
            try inner.checkTime(now: t, durable: inner.exp == nil)
        } catch let e as CryptoError where e.kind == .time {
            // Dropped, as any message that fails a check. Said, so that a phone whose clock is wrong can be told, only when
            // the evidence points at the clock: a `ts` beyond the allowed skew in the future, or a durable message older
            // than any delivery delay explains. A plain expiry (a call signal or a ping collected late) is no evidence.
            let future = inner.ts.timeIntervalSince(t) > Inner.maxClockSkewFuture
            let tooOld = inner.exp == nil && t.timeIntervalSince(inner.ts) > Inner.maxDurableAge
            if future || tooOld { timeDropBroadcast.emit(inner.type) }
            throw e
        }
        noteVaultTime(inner.ts)
        // An answer (also a cached one sent again, also one that comes after its wait ended) settles its request.
        if let re = inner.re { settled(re, at: inner.ts) }
        let firstTime: Bool = mem.withLock {
            guard st.seenInner[inner.id] == nil else { return false }
            st.seenInner[inner.id] = Self.ms(t)
            Self.prune(&st.seenInner, t)
            return true
        }
        guard firstTime else {
            // §8.2: the vault re-sends a cached response with its own id. A request sent again with the same id (a lost
            // answer's resend, §11.14.9) is still waiting for it, even when the first copy arrived after its wait ended.
            if let re = inner.re { mem.withLock { pending[re] }?.complete(inner) }
            return
        }
        let body = VaultJSON.object(inner.body)
        switch inner.type {
        // §10.3 (0.10.3, 0.10.4): every device.paired carries the device's standing token; it replaces the token of
        // hs.resp before maintain() looks at it.
        case "device.paired":
            storeVaultToken(body)
            // §10.2 (0.87.0): device.features after each epoch it activates; the pairing's is this one.
            try? queueFeatures()
            // The first handshake's `device.paired` (pairing, enrollment, transfer): a fin still owed for it is of no use, and
            // its age must not later tell a paired device that the pairing failed.
            // Only the fins of the epoch it opened under: a retired epoch's message must not clear a newer handshake's fin.
            mem.withLock {
                if st.deviceID == nil { st.outbox.removeAll { $0.type == Self.typeHsFin && $0.epochIDs?.contains(ep.ctx) == true } }
            }
            // A transfer's `device.paired` is applied before the message is acked (VAULT-MESSAGING §11.14.10 rule 5: a paired
            // transfer completes at any later start): the event in memory is lost with the process, the state is not.
            if mem.withLock({ st.deviceID == nil && (VaultJSON.bool(body, "transfer") == true || alt().transferAttestKeyID != nil) }) {
                applyPaired(body)
            }
        // §6.7 (0.10.5): only a device still waiting for device.paired acts on it; a paired one drops it.
        case Self.typePairRejected:
            if mem.withLock({ isPaired }) { return }
            dropPairing()
        case "relay.token.issued": storeVaultToken(body)
        case "relay.token.refresh":
            if inner.re == nil {
                let tok = try mintForVault()
                let entry = try enqueueLocked(
                    id: nil, type: inner.type, body: Self.standing(tok), re: inner.id, status: Inner.statusOK, exp: nil, save: false
                )
                afterLock { [self] in _ = try? await deliverQueued(entry) }
            } else {
                storeVaultToken(body)
            }
        case "identity.rotate": try followRotation(body)
        default: break
        }
        if let re = inner.re {
            if inner.status != Inner.statusOK, inner.error?.code == Self.codeOwnerCheckRequired { ownerCheckBroadcast.emit(inner.type) }
            mem.withLock { pending[re] }?.complete(inner)
        } else {
            publishOnce(VaultMessage(inner: inner))
        }
        await maintain(t)
        // An `hs.resp` that may not have reached the relay goes again, after this handling's save (``resendResps()``).
        afterLock { [self] in await resendResps() }
    }

    /// `device.pair.rejected` (§6.7, 0.10.5): stop waiting, drop the handshake's epoch and the request token of its
    /// `hs.resp`. Nothing is sent back; a redelivery finds no epoch to open it and is dropped.
    func dropPairing() {
        mem.withLock {
            handshakeGeneration &+= 1 // an after-lock closure of the dropped handshake shows nothing
            sas = nil
            st.transferSas = nil
            sasRestored = false
            ini?.abort()
            ini = nil
            for a in awaiting { a.resp.abort() }
            awaiting.removeAll()
            keyring.destroy()
            keyring = Keyring()
            st.vault?.token = ""
            st.vault?.tokenExpMs = 0
            st.vault?.confirmed = nil
            st.vault?.confirmAtMs = nil
            // The fin of the handshake that is dropped is of no use to anyone.
            st.outbox.removeAll { $0.type == Self.typeHsFin }
        }
    }

    /// Answers a vault-initiated rekey (§6.5). The responder is persisted before `hs.resp` goes out: the vault switches
    /// to the new epoch on `hs.resp`, so a restart that lost it would leave this device unable to read anything.
    ///
    /// One `hs.resp` per `hs.init` (§6.3): the `hs.init`'s inner id is marked seen in the save that holds its responder, kept
    /// from the later of this phone's time and the `hs.init`'s `ts`, so that it outlives the `hs.init`'s own window. The mark
    /// is keyed on the inner id: it is inside the epoch's AEAD, and a vault that deposits the `hs.init` again (a new msg_id,
    /// §6.5; the relay's own redelivery of the same msg_id is dropped by `seen`) sends the same bytes, so the same id. A
    /// repeat makes no second responder (§6.5: acked and dropped); only while its `hs.resp` may not have reached the relay
    /// are the same bytes deposited again.
    func handleRekey(_ raw: [UInt8], epoch ep: Epoch, sender: [UInt8], _ t: Date, inner: Inner) async throws {
        let initID = inner.id
        let prepared: (Responder, VaultRecord)? = try mem.withLock {
            pruneAwaiting(t)
            if st.seenInner[initID] != nil {
                guard let a = awaiting.first(where: { $0.initID == initID }), a.respBytes != nil, let v = st.vault else { return nil }
                return (a.resp, v)
            }
            // §6.3.1: a rekey under the confirmed epoch while it is not current is accepted as if current.
            guard keyring.current() === ep || isConfirmedLocked(ep) else { return nil }
            let v = try requireVault()
            let pi = try PendingInit.openRekey(raw, current: ep, now: t)
            let (resp, env) = try pi.respond(ResponderConfig(
                identity: secrets.identity, pinnedSuite: v.suite, policy: .vaultToDevice, collectSender: sender,
                recordRelayKey: try Base64s.decodeStd(v.relayPk), knownInitiatorIk: try Base64s.decodeStd(v.ik), now: t,
                features: DeviceFeatures.all
            ))
            awaiting.append(Awaiting(resp: resp, createdMs: Self.ms(t), initID: initID, respBytes: env))
            unsavedResps.insert(ObjectIdentifier(resp))
            pruneAwaiting(t)
            st.seenInner[initID] = Self.ms(max(t, inner.ts))
            Self.prune(&st.seenInner, t)
            return (resp, v)
        }
        guard let (resp, v) = prepared else { return }
        // The responder is stored by the save that ends ``handleLocked(_:)``, before this deposit (``afterLock(_:)``).
        // Sent also while a lock is pending, ungated (as vettid-android sends it): a rekey the vault started and this phone
        // left unanswered holds every later one until it expires (VAULT-MESSAGING §6.5).
        afterLock { [self] in
            #if DEBUG
            await beforeRespDeposit?()
            #endif
            await depositResp(v, resp)
        }
    }

    /// Deposits [r]'s `hs.resp` bytes in one attempt the client does not send again once it may have reached the relay
    /// (``RelayClient/deposit(mailboxID:token:payload:resendAfterSent:)``), so that a refusal is the relay's word on it.
    /// Claimed under ``mem``: only while the bytes are kept (not yet accepted), never before a save holds the responder
    /// (§8.3), nor while another deposit of it runs; the first claim is its first attempt (``Awaiting/attempted``). Never
    /// called with ``lock`` held: its bookkeeping takes it.
    ///
    /// Accepted: the bytes are no longer kept, saved (a later redelivery of its `hs.init` is dropped). `quota_exceeded`: not
    /// a refusal of this `hs.resp` but a full mailbox; the device's re-send waits (``noteRespQuota(_:)``), then goes again,
    /// the same bytes. Any other failure (a lost answer, a retryable error, a stop, an answer that is no refusal): it may have
    /// arrived; the responder stays for its `hs.fin`, expires if none comes, and keeps the bytes for a re-send
    /// (``resendResps()``).
    ///
    /// Refused for good (a 4xx or 5xx that trying again will not cure): on the first attempt the vault never sees it, so the
    /// responder ends and so does its mark, and the `hs.init` may be answered afresh (that is no second `hs.resp`). On a
    /// re-send an earlier attempt's outcome was unknown, so the vault may hold that copy: the responder and the mark stay,
    /// and only the re-sending stops (saved; no second, different `hs.resp`; at worst the responder waits out
    /// ``handshakeTTL``). A responder restored from the file counts as attempted: its first deposit may have happened
    /// before the restart, so a refusal then leaves it until ``handshakeTTL`` too.
    func depositResp(_ v: VaultRecord, _ r: Responder) async {
        let id = ObjectIdentifier(r)
        let claim: (bytes: [UInt8], first: Bool)? = mem.withLock {
            guard let i = awaiting.firstIndex(where: { $0.resp === r }), let b = awaiting[i].respBytes,
                  !unsavedResps.contains(id), respsInFlight.insert(id).inserted else { return nil }
            defer { awaiting[i].attempted = true }
            return (b, !awaiting[i].attempted)
        }
        guard let (bytes, first) = claim else { return }
        defer { mem.withLock { _ = respsInFlight.remove(id) } }
        do {
            try await depositToVault(v, bytes, resendAfterSent: false)
            try? await withLockSaving { updateAwaiting(r) { $0.respBytes = nil } }
        } catch let e as RelayError where e.code == RelayError.quotaExceeded {
            mem.withLock { updateAwaiting(r) { noteRespQuota(&$0) } }
        } catch let e as RelayError where e.status >= 400 && !e.retryable {
            try? await withLockSaving {
                guard first else { return updateAwaiting(r) { $0.respBytes = nil } }
                let mark = awaiting.first { $0.resp === r }?.initID
                awaiting.removeAll { $0.resp === r }
                r.abort()
                if let mark { st.seenInner[mark] = nil }
            }
        } catch {}
    }

    /// Re-deposits, by itself, every `hs.resp` whose deposit may not have reached the relay (``Awaiting/respBytes`` kept: a
    /// retryable failure or a lost answer, a stop before the deposit), the same bytes, as an outbox would: at each
    /// collection start and after each handled message. Not one waiting out a `quota_exceeded`, nor one past
    /// ``handshakeTTL``, nor one a save does not hold yet (``depositResp(_:_:)``). With no inbound traffic and no
    /// collection start nothing is re-sent: the vault then sends nothing either, and its rekey ends at its bound, as one
    /// this device never answered.
    func resendResps() async {
        let due: ([Responder], VaultRecord?) = mem.withLock {
            let cutoff = Self.ms(now().addingTimeInterval(-Self.handshakeTTL))
            let up = cfg.uptime()
            let list = awaiting.filter { $0.respBytes != nil && $0.createdMs >= cutoff && up >= $0.quotaUntil }.map(\.resp)
            return (list, st.vault)
        }
        guard let v = due.1 else { return }
        for r in due.0 { await depositResp(v, r) }
    }

    /// Changes the awaiting rekey of [r] in place. Callers hold ``mem``.
    private func updateAwaiting(_ r: Responder, _ change: (inout Awaiting) -> Void) {
        guard let i = awaiting.firstIndex(where: { $0.resp === r }) else { return }
        change(&awaiting[i])
    }

    /// An `hs.resp`'s re-send after a `quota_exceeded` waits: from a minute, doubling to an hour (RELAY-PROTOCOL §7.1;
    /// VAULT-MESSAGING §8.6 for a device). Memory only.
    private func noteRespQuota(_ a: inout Awaiting) {
        a.quotaBackoff = min(max(a.quotaBackoff * 2, Self.respQuotaFirst), Self.respQuotaMax)
        a.quotaUntil = cfg.uptime() + a.quotaBackoff
    }

    static let respQuotaFirst: TimeInterval = 60
    static let respQuotaMax: TimeInterval = 3600

    // MARK: - Tokens (§7)

    /// A standing token for the vault (sub = the vault's relay key), 30 days.
    func mintForVault() throws -> String {
        let (pk, url): ([UInt8], String) = try mem.withLock { (try Base64s.decodeStd(try requireVault().relayPk), st.relayURL) }
        let ttl = DepositTokens.standingTTL
        let tok = try own.mintToken(sender: RelayAuth.encodeKey(pk), audience: url, ttl: ttl)
        mem.withLock { st.issuedExpMs = Self.ms(now().addingTimeInterval(ttl - 60)) }
        return tok
    }

    /// Checks a token the vault issued to this device; returns its expiry. Callers hold ``mem``.
    func heldFromVault(_ tok: String) -> Date? {
        guard let v = st.vault, let pk = try? Base64s.decodeStd(v.relayPk), let c = try? DepositTokens.verify(tok, issuer: pk) else {
            return nil
        }
        guard c.iss == v.mailbox, c.sub == RelayAuth.encodeKey(secrets.relay.publicKey) else { return nil }
        return c.exp
    }

    func storeVaultToken(_ o: JsonObject) {
        guard let tok = VaultJSON.string(o, "token") else { return }
        if let kind = VaultJSON.string(o, "kind"), kind != "standing" { return }
        mem.withLock {
            guard st.vault != nil, let exp = heldFromVault(tok) else { return }
            if Self.ms(exp) > st.vault?.tokenExpMs ?? 0 {
                st.vault?.token = tok
                st.vault?.tokenExpMs = Self.ms(exp)
                // Entries held for a spent token go under the new one, now rather than at the next start (§8.6).
                if st.outbox.contains(where: { $0.quotaToken != nil }) {
                    // In a task of its own: a whole flush does not hold up this message's handling and its ack.
                    afterLock { [weak self] in Task { await self?.gatedFlush() } }
                }
            }
        }
    }

    func followRotation(_ o: JsonObject) throws {
        let r = try Rotation.parse(try o.obj("rotation"))
        try mem.withLock {
            guard let v = st.vault else { return }
            let (finalIk, kem) = try Rotation.resolveChain(try Base64s.decodeStd(v.ik), [r])
            st.vault?.ik = Base64s.encodeStd(finalIk)
            if let kem { st.vault?.kem = Base64s.encodeStd(kem.bytes) }
        }
    }

    static func standing(_ tok: String) -> [UInt8] { JsonBuilder().string("kind", "standing").string("token", tok).bytes() }

    /// Refreshes tokens in both directions (§7.2).
    func maintain(_ t: Date) async {
        let (vault, hasEpoch, issuedExp) = mem.withLock { (st.vault, keyring.current() != nil, st.issuedExpMs) }
        guard let v = vault, hasEpoch else { return }
        do {
            if issuedExp != 0, Double(issuedExp) / 1000 - t.timeIntervalSince1970 < Self.issueBefore {
                let tok = try mintForVault()
                let e = try enqueueLocked(
                    id: nil, type: "relay.token.issued", body: Self.standing(tok), re: nil, status: nil, exp: nil, save: false
                )
                afterLock { [self] in _ = try? await deliverQueued(e) }
            }
            let exp = Double(v.tokenExpMs) / 1000
            // Not a second one while the device's own is still in the outbox (held by the lock gate, or a quota): they would all
            // go at once.
            let owed = mem.withLock { st.outbox.contains { $0.type == Self.typeTokenRefresh && $0.re == nil } }
            if !owed, exp - t.timeIntervalSince1970 < Self.refreshBefore, t.timeIntervalSince1970 < exp {
                let e = try enqueueLocked(
                    id: nil, type: "relay.token.refresh", body: VaultJSON.empty, re: nil, status: nil, exp: nil, save: false
                )
                afterLock { [self] in _ = try? await deliverQueued(e) }
            }
        } catch {
            // retried at the next message
        }
        tickConfirmLocked(t, save: false)
    }
}
