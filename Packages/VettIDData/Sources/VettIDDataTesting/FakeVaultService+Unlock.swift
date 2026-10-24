#if DEBUG
import Foundation
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

// TEST ONLY. The unlock (VAULT-MESSAGING §11.4) and the lock (§10.2, §12.3; MEMBER-API "Vault") as vettid-vault's
// enclave answers them (`enclave/core.go` `unlock`, `vault/unlock.go` `UnlockAlt`, `vault/opendek.go` `openDEK`): every
// unlock first locks a running vault and sends `vault.locking` (`procHost.Open`), whatever it is then answered; the
// phone secret is checked before the PIN (`device_secret`, not counted), a wrong PIN is counted in the header and backs
// off after three in a row (§11.8: 30 s, 1 min, 5 min, 15 min, 60 min), a right PIN resets it and opens the vault. A
// locked vault answers nothing over the relay.
extension FakeVaultService {
    static let unlocked = "unlocked"
    static let locked = "locked"
    /// §11.8: the waits after three failures in a row (vettid-vault `backoffDelays`).
    static let backoffDelays: [TimeInterval] = [30, 60, 300, 900, 3600]

    /// How one unlock is answered besides the vault's own rules.
    public enum UnlockAnswer: Sendable {
        /// The vault's rules decide (the default).
        case vault
        /// The vault processes it (it opens) but the slot cannot be read: the answer is lost.
        case answerLost
        /// The slot holds bytes the phone cannot open (§11.4: an unknown device gets random bytes).
        case unreadable
        /// A sealed refusal decided before the PIN (`unknown_device`, `signer_refused`, `recovery_pending`, …).
        case sealed(String)
        /// The member API cannot be reached.
        case offline
        /// The member API answers `503 vault_unavailable`.
        case unavailable
        /// The vault's rules decide, but the slot stays queued until ``releaseHeldUnlock()``: the answer is on its way.
        case held
    }

    /// What the vault received in one unlock request.
    public struct UnlockSeen: Sendable {
        public let pin: String
        public let unlockSecret: [UInt8]?
        public let cancelRecovery: Bool
    }

    /// How the vault answers the relay's `vault.lock`: it locks and answers `{}`, or nothing arrives in time.
    public enum RelayLockAnswer: Sendable { case lock, noAnswer }

    /// How the member API's lock route answers (VAULT-LOCK §2 F8): the vault locks and the slot says `done`; the slot
    /// stays `queued`; `done` but the vault does not lock; `429` with a `retry_after`.
    public enum MemberLockAnswer: Sendable { case lock, queued, doneNotLocked, limited(Int) }

    // MARK: - Switches and what was seen

    /// The next unlocks answer these, in order; then the vault's rules.
    public func unlockAnswers(_ answers: UnlockAnswer...) { locked { unlockAnswers += answers } }

    public var unlocks: [UnlockSeen] { locked { unlocksValue } }

    public var relayLockAnswer: RelayLockAnswer {
        get { locked { relayLockAnswerValue } }
        set { locked { relayLockAnswerValue = newValue } }
    }

    /// How every member API lock answers (``MemberLockAnswer/lock`` by default).
    public var memberLockAnswer: MemberLockAnswer {
        get { locked { memberLockAnswerValue } }
        set { locked { memberLockAnswerValue = newValue } }
    }

    public var relayLocks: Int { locked { relayLocksValue } }
    public var memberLocks: Int { locked { memberLocksValue } }
    public var pinFailureCount: Int { locked { pinFailures } }
    /// Whether the vault itself runs.
    public var isOpen: Bool { locked { vaultOpen } }

    /// What the vault sends this phone waits at the relay while true (a relay slower than the member API).
    public var holdMessages: Bool {
        get { locked { holdMessagesValue } }
        set {
            locked {
                holdMessagesValue = newValue
                cond.broadcast()
            }
        }
    }

    /// The held unlock's answer arrives (``UnlockAnswer/held``).
    public func releaseHeldUnlock() {
        locked {
            for (rid, env) in heldSlots { slots[rid] = env }
            heldSlots = [:]
        }
    }

    /// The vault's clock moves ahead (a backoff runs out).
    public func advanceVaultClock(_ seconds: TimeInterval) { locked { vaultClockAhead += seconds } }

    /// The vault now holds [secret] as this phone's (a `pin.change` or `vault.secret.renew` it stored, whose answer the
    /// phone did not get).
    public func storeSecret(_ secret: [UInt8]) { locked { vaultSecret = secret } }

    /// The vault locks by itself (§3.6.4: ten failed checks; §12.3 any lock the app did not ask for): `vault.locking`
    /// with [reason], and it no longer runs.
    public func lockByItself(reason: String) {
        locked {
            guard vaultOpen else { return }
            try? reply("vault.locking", #"{"reason":"\#(reason)"}"#)
            close()
        }
    }

    /// How a `device.unlinked` reaches this phone: as the vault sends it, with its sealed bytes altered (a forgery), from
    /// another relay key than the vault's, or twice (the same message replayed).
    public enum UnlinkDelivery: Sendable { case asSent, tampered, wrongSender, twice }

    /// The vault tells this phone it is no longer its app (`device.unlinked{reason}`, §6.7.1 step 4, §11.11.5 step 3).
    public func unlinkThisPhone(reason: String, delivery: UnlinkDelivery = .asSent) {
        locked {
            guard let epoch = keyring.current() else { return }
            let inner = Inner(id: Ulid.new(), type: "device.unlinked", ts: stampNow, body: Array(#"{"reason":"\#(reason)"}"#.utf8))
            guard var payload = try? epoch.seal(inner) else { return }
            switch delivery {
            case .asSent: queue(payload)
            case .tampered:
                payload[payload.count - 1] ^= 0x01
                queue(payload)
            case .wrongSender:
                let other = Ed25519PrivateKey.generate()
                queued.append(RelayMessage(msgID: Ulid.new(), depositedAt: "", sender: RelayAuth.encodeKey(other.publicKey), jti: nil, payload: payload))
                cond.broadcast()
            case .twice:
                queue(payload)
                queue(payload)
            }
        }
    }

    // MARK: - The member API's routes

    /// `POST /api/vault/unlock`: the sealed `vault.unlock` opened with the ETK and answered in its slot. Callers hold
    /// ``cond``.
    func unlock(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        let answer = unlockAnswers.isEmpty ? UnlockAnswer.vault : unlockAnswers.removeFirst()
        if case .offline = answer { return .failure(.notConnectedToInternet) }
        if case .unavailable = answer { return .json(503, #"{"error":"vault_unavailable"}"#) }
        guard let o = try? StrictJson.parseObject(r.body), let rid = try? o.string("request_id"), let env = try? o.base64("envelope"),
              let request = try? openRequest(env), let body = try? StrictJson.parseObject(request.body), let kem = device?.kem ?? recovery.phone?.kem
        else { return .json(400, #"{"error":"bad_request"}"#) }
        let pin = (try? body.string("pin")) ?? ""
        let secret = try? body.base64("unlock_secret")
        let cancel = body.has("cancel_recovery")
        // The vault records the highest manifest serial it was sent (§11.10.4) and answers it.
        if let sent = (try? body.optUint("manifest_serial", min: 0, max: StrictJson.maxSafeInteger)) ?? nil {
            vaultManifestSerial = max(vaultManifestSerial, sent)
        }
        unlocksValue.append(UnlockSeen(pin: pin, unlockSecret: secret, cancelRecovery: cancel))
        let update = recordUpdate(body, requestID: rid)
        // procHost.Open: a running vault is locked first, as for an owner request, whatever the unlock is answered.
        if vaultOpen {
            try? reply("vault.locking", #"{"reason":"unlock"}"#)
            close()
        }
        switch answer {
        case .unreadable:
            plainSlots[rid] = JsonBuilder().string("status", "done").base64("envelope", Randomness.bytes(5252)).build()
        case .sealed(let code):
            slots[rid] = try? Self.sealResult(kem, "vault.unlock.result", rid, #"{"ok":false,"code":"\#(code)","header_seq":\#(headerSeq)}"#)
        case .held:
            heldSlots[rid] = try? Self.sealResult(kem, "vault.unlock.result", rid, unlockResult(pin: pin, secret: secret, update: update))
        case .vault, .answerLost, .offline, .unavailable:
            slots[rid] = try? Self.sealResult(kem, "vault.unlock.result", rid, unlockResult(pin: pin, secret: secret, update: update), ts: stampNow)
            if case .answerLost = answer { lostSlots.insert(rid) }
        }
        return .json(202, "{}")
    }

    /// The vault's own rules, in the order of `UnlockAlt`. Callers hold ``cond``.
    private func unlockResult(pin: String, secret: [UInt8]?, update: UpdateSeen?) -> String {
        let now = Date().addingTimeInterval(vaultClockAhead)
        guard let secret, secret.count == 32 else { return refused("bad_request") }
        if let until = backoffUntil, now < until { return refused("backoff", retryAfter: until.timeIntervalSince(now)) }
        // openDEK: the secret is checked before the PIN, and its failure is not a PIN attempt.
        guard secret == vaultSecret else { return refused("device_secret") }
        guard pin == vaultPin else {
            pinFailures += 1
            headerSeq += 1
            let wait = pinFailures < 3 ? 0 : Self.backoffDelays[min(pinFailures - 3, Self.backoffDelays.count - 1)]
            backoffUntil = wait > 0 ? now.addingTimeInterval(wait) : nil
            return refused("bad_pin", retryAfter: wait)
        }
        pinFailures = 0
        backoffUntil = nil
        let token = device.flatMap { try? self.token($0.relay) } ?? ""
        let serving = releases.serving
        let (member, staysLocked) = releaseRules(update)
        let ok = #"{"ok":true,"state_seq":\#(stateSeq),"header_seq":\#(headerSeq),"token":"\#(token)","release":"\#(Self.pcr0(serving))","release_number":\#(serving),"release_status":"active","manifest_serial":\#(vaultManifestSerial)\#(member)\#(recoveryBundleMember())}"#
        // A move (§11.10.4 step 8) locks without opening.
        if staysLocked { return ok }
        vaultOpen = true
        statusState = Self.unlocked
        handleWhileLockedRequests()
        return ok
    }

    private func refused(_ code: String, retryAfter: TimeInterval = 0) -> String {
        #"{"ok":false,"code":"\#(code)","header_seq":\#(headerSeq),"retry_after":\#(Int(retryAfter.rounded(.up)))}"#
    }

    /// `POST /api/vault/lock` (MEMBER-API "Vault"): before release L the slot's `done` proves nothing (VAULT-LOCK §2 F8).
    /// Callers hold ``cond``.
    func memberLock(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        memberLocksValue += 1
        releases.busy = false
        let answer = memberLockAnswerValue
        guard let rid = try? StrictJson.parseObject(r.body).string("request_id") else { return .json(400, #"{"error":"bad_request"}"#) }
        switch answer {
        case .limited(let seconds): return .json(429, #"{"error":"rate_limited","retry_after":\#(seconds)}"#)
        case .queued: break
        case .doneNotLocked: plainSlots[rid] = #"{"status":"done"}"#
        case .lock:
            if vaultOpen {
                try? reply("vault.locking", #"{"reason":"owner"}"#)
                close()
            }
            plainSlots[rid] = #"{"status":"done"}"#
        }
        return .json(202, "{}")
    }

    /// `vault.lock` over the relay (§10.2): answered `{}`, then `vault.locking`, and the vault locks. Callers hold
    /// ``cond``.
    func relayLock(_ m: Inner) throws {
        relayLocksValue += 1
        releases.busy = false
        guard relayLockAnswerValue == .lock else { return }
        try reply(m.type, "{}", re: m.id)
        try reply("vault.locking", #"{"reason":"owner"}"#)
        close()
    }

    /// The vault stops: it no longer runs and the member API says so. Callers hold ``cond``.
    func close() {
        vaultOpen = false
        statusState = Self.locked
    }
}

// swiftlint:enable line_length
#endif
