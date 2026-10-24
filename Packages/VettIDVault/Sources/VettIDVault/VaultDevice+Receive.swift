import Foundation
import VettIDCrypto
import VettIDRelay

// Receiving (VAULT-MESSAGING §8.2–§8.4, §6.5, §7): classification, dedupe, sessions, rekeys and tokens.
extension VaultDevice {
    /// Processes one collected message. Classification is by sender and recipient kid only (§13.6). A message of a
    /// rekey's new epoch that arrived before the rekey's `hs.fin` is neither recorded as seen nor acked
    /// (``LeaveUnacked``): the relay delivers it again, and it is opened once `hs.fin` has arrived (§6.3, §8.4).
    public func handle(_ m: RelayMessage) async throws {
        try await lock.withLock {
            let t = now()
            let fresh: Bool = mem.withLock {
                guard st.seen[m.msgID] == nil else { return false }
                st.seen[m.msgID] = Self.ms(t)
                Self.prune(&st.seen, t)
                return true
            }
            guard fresh else { return }
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
            try save()
        }
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
            try mem.withLock {
                pruneAwaiting(t)
                let match = awaiting.firstIndex { $0.resp.kids.recipient == env.recipientKid && $0.resp.kids.sender == env.senderKid }
                guard let i = match else {
                    return
                }
                // CryptoError.early: a message of the new epoch ahead of its hs.fin (handle leaves it for redelivery).
                let fr = try awaiting[i].resp.handleFin(raw, collectSender: sender, now: t)
                keyring.activate(fr.epoch, now: t)
                awaiting.remove(at: i)
            }
            return
        }
        resetRefusals() // the vault spoke to this device under its session
        if inner.type == Self.typeHsInit {
            try await handleRekey(raw, epoch: ep, sender: sender, t)
            return
        }
        do {
            try inner.checkTime(now: t, durable: inner.exp == nil)
        } catch let e as CryptoError where e.kind == .time {
            // Dropped, as any message that fails a check; but said, so that a phone whose clock is wrong can be told.
            timeDropBroadcast.emit(inner.type)
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
                _ = try await sendLocked(
                    id: nil, type: inner.type, body: Self.standing(tok), re: inner.id, status: Inner.statusOK, exp: nil
                )
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
            publish(VaultMessage(inner: inner))
        }
        await maintain(t)
    }

    /// `device.pair.rejected` (§6.7, 0.10.5): stop waiting, drop the handshake's epoch and the request token of its
    /// `hs.resp`. Nothing is sent back; a redelivery finds no epoch to open it and is dropped.
    func dropPairing() {
        mem.withLock {
            sas = nil
            ini?.abort()
            ini = nil
            for a in awaiting { a.resp.abort() }
            awaiting.removeAll()
            keyring.destroy()
            keyring = Keyring()
            st.vault?.token = ""
            st.vault?.tokenExpMs = 0
        }
    }

    /// Answers a vault-initiated rekey (§6.5). The responder is persisted before `hs.resp` goes out: the vault switches
    /// to the new epoch on `hs.resp`, so a restart that lost it would leave this device unable to read anything.
    func handleRekey(_ raw: [UInt8], epoch ep: Epoch, sender: [UInt8], _ t: Date) async throws {
        let prepared: (Awaiting, [UInt8], VaultRecord)? = try mem.withLock { // swiftlint:disable:this large_tuple
            guard keyring.current() === ep else { return nil }
            let v = try requireVault()
            let pi = try PendingInit.openRekey(raw, current: ep, now: t)
            let (resp, env) = try pi.respond(ResponderConfig(
                identity: secrets.identity, pinnedSuite: v.suite, policy: .vaultToDevice, collectSender: sender,
                recordRelayKey: try Base64s.decodeStd(v.relayPk), knownInitiatorIk: try Base64s.decodeStd(v.ik), now: t
            ))
            let a = Awaiting(resp: resp, createdMs: Self.ms(t))
            awaiting.append(a)
            pruneAwaiting(t)
            return (a, env, v)
        }
        guard let (a, env, v) = prepared else { return }
        try save()
        do {
            try await depositToVault(v, env)
        } catch let e as RelayError {
            // Refused: the vault never sees this hs.resp. Otherwise it may have arrived: the responder stays for its
            // hs.fin, and expires if none comes.
            if !e.retryable {
                mem.withLock {
                    awaiting.removeAll { $0.resp === a.resp }
                    a.resp.abort()
                }
            }
            throw e
        }
    }

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
                _ = try await sendLocked(id: nil, type: "relay.token.issued", body: Self.standing(tok), re: nil, status: nil, exp: nil)
            }
            let exp = Double(v.tokenExpMs) / 1000
            if exp - t.timeIntervalSince1970 < Self.refreshBefore, t.timeIntervalSince1970 < exp {
                _ = try await sendLocked(id: nil, type: "relay.token.refresh", body: VaultJSON.empty, re: nil, status: nil, exp: nil)
            }
        } catch {
            // retried at the next message
        }
    }
}
