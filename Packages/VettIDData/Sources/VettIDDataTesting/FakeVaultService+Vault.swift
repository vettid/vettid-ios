#if DEBUG
import Foundation
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

// The two relays and the vault behind its mailbox: `vault.enrolled`, the first handshake and `device.paired`
// (VAULT-MESSAGING §11.3, §6.3), then the requests of enrollment in the session (§3.5.7).
extension FakeVaultService {
    /// How long an empty collect waits for a message before it answers (a long poll, briefly).
    static let collectHold: TimeInterval = 0.05

    var vaultMailbox: String { Mailbox.id(relayKey.publicKey) }

    func message(_ payload: [UInt8]) -> RelayMessage {
        RelayMessage(msgID: Ulid.new(), depositedAt: "", sender: RelayAuth.encodeKey(relayKey.publicKey), jti: nil, payload: payload)
    }

    /// Queues [payload] for the device's mailbox. Callers hold ``cond``.
    func queue(_ payload: [UInt8]) {
        queued.append(message(payload))
        cond.broadcast()
    }

    /// vault.enrolled (§11.3), sealed to the device's KEM key, with its first standing token. Its "attestation" is the
    /// request's [nonce] itself (``TestVaultPhone``'s check compares the two, as the Nitro document's nonce is checked).
    /// Callers hold ``cond``.
    func queueEnrolled(_ deviceKem: KemPublicKey, _ addr: RelayAddr, nonce: [UInt8]) throws {
        let vaultRelay = JsonBuilder().string("url", self.vaultRelay.baseURL).string("mailbox", vaultMailbox).base64("pk", relayKey.publicKey).build()
        let bundle = JsonBuilder().uint("v", 1).uint("suite", 2).base64("ik", ik.publicKey).base64("kem", kem.publicKey.bytes).raw("relay", vaultRelay).bytes()
        let body = JsonBuilder().string("vault_id", vaultID).base64("vault_bundle", bundle).string("token", try token(addr)).uint("state_seq", 2).base64("attestation", nonce).bytes()
        let inner = Inner(id: Ulid.new(), type: "vault.enrolled", ts: Date(), body: body)
        queue(try Envelope.sealSealed(deviceKem, senderKid: Kid.anonymous, padded: try Inner.encode(inner, .sealed)).0)
    }

    func token(_ addr: RelayAddr) throws -> String {
        try DepositTokens.mintStanding(relayKey, sender: RelayAuth.encodeKey(addr.pk), audience: addr.url, now: Date())
    }

    // MARK: - The device's relay

    func answerRelay(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        if r.path == "/v1/register" {
            if let gate = locked({ registerGateValue }) { return .held(gate, registerAnswer) }
            return registerAnswer
        }
        if r.path == "/v1/mailbox", r.method == "GET" {
            if locked({ transfer.collectRefused }) { return .json(403, #"{"code":"mailbox_unknown","message":""}"#) }
            return collect()
        }
        if r.path.hasPrefix("/v1/blob/") { return deviceBlob(r) }
        if r.path.hasPrefix("/v1/mailbox/"), r.method == "DELETE" { return .empty(204) }
        return .json(404, #"{"code":"not_found","message":""}"#)
    }

    /// Holds the device relay's `register` (a new device being made while a session opens) until ``releaseRegisters()``.
    public func holdRegisters() { locked { registerGateValue = FakeHTTPServer.Gate() } }

    /// The `register` requests held now.
    public var heldRegisters: Int { locked { registerGateValue?.waiting ?? 0 } }

    public func releaseRegisters() {
        locked {
            registerGateValue?.open()
            registerGateValue = nil
        }
    }

    private var registerAnswer: FakeHTTPServer.Answer {
        .json(201, #"{"mailbox_id":"x","limits":{"max_payload_bytes":262144,"message_ttl_seconds":1,"visibility_timeout_seconds":60,"max_token_lifetime_seconds":1,"open_token_max_lifetime_seconds":\#(Self.relayInviteLimit),"max_claim_bytes":65536,"claim_ttl_seconds":\#(Self.relayInviteLimit)}}"#)
    }

    /// One collect: the queued messages, waiting briefly while there are none.
    private func collect() -> FakeHTTPServer.Answer {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(Self.collectHold)
        while queued.isEmpty || holdMessagesValue, cond.wait(until: deadline) {}
        if holdMessagesValue { return .json(200, #"{"messages":[]}"#) }
        let msgs = queued.map { JsonBuilder().string("msg_id", $0.msgID).string("sender", $0.sender).base64("payload", $0.payload).build() }
        queued.removeAll()
        return .json(200, #"{"messages":\#(JsonBuilder.array(msgs))}"#)
    }

    // MARK: - The vault's relay: the vault itself

    func answerVaultRelay(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        if r.method == "PUT", r.path == "/v1/blob/\(vaultMailbox)" { return vaultBlobPut(r) }
        if r.method == "GET", r.path.hasPrefix("/v1/claim/") { return locked { transferClaim(r) } }
        guard r.method == "POST", r.path == "/v1/mailbox/\(vaultMailbox)" else { return .json(404, #"{"code":"not_found","message":""}"#) }
        if locked({ refusesDeposit() }) { return .json(403, #"{"code":"token_revoked","message":""}"#) }
        // §12.5 step 2: a deleted vault's mailbox is gone, and every deposit is refused.
        if locked({ vaultDeletedValue }) { return .json(404, #"{"code":"mailbox_unknown","message":""}"#) }
        guard let payload = try? StrictJson.parseObject(r.body).base64("payload") else { return .json(400, #"{"code":"bad_request","message":""}"#) }
        locked {
            do {
                try deposited(payload)
            } catch {
                // A message the vault cannot use is dropped, as the vault does.
            }
        }
        return .json(201, #"{"msg_id":"\#(Ulid.new())"}"#)
    }

    /// A deposit to the vault: the device's hs.init, its hs.fin, or a request in the session. Callers hold ``cond``.
    private func deposited(_ raw: [UInt8]) throws {
        // A transfer's target has no device until the new phone's hs.init arrives (FakeVaultService+Transfer.swift).
        if device == nil, transfer.inviteID != nil { return try acceptTransferInit(raw) }
        guard let device else { return }
        if let r = responder {
            // §6.3: the hs.fin activates the epoch; device.paired follows in the session.
            let fin = try r.handleFin(raw, collectSender: device.relay.pk, now: Date())
            keyring.activate(fin.epoch, now: Date())
            responder = nil
            if transfer.inviteID != nil { return try transferFinished() }
            recoveryPaired()
            try reply("device.paired", #"{"device_id":"dev-1","role":"app","vault_id":"\#(vaultID)","release":"\#(Self.pcr0)","release_number":3}"#)
            return
        }
        // §6.5: the device's hs.resp to a vault-initiated rekey (after an identity rotation).
        if try rekeyResponse(raw) { return }
        if keyring.current() == nil {
            let kem = kem
            let p = try PendingInit.open(raw, lookup: { k in k == kem.publicKey.kid ? kem : nil }, now: Date())
            deviceIk = p.body.from.ik
            if recovery.invitation { recovery.handshakeContexts.append(p.body.ctx) }
            let (resp, env) = try p.respond(ResponderConfig(identity: ik, token: try token(device.relay), policy: .vaultToDevice, collectSender: device.relay.pk))
            responder = resp
            queue(env)
            return
        }
        let inner = try keyring.open(try Envelope.parse(raw), now: Date()).inner
        try request(inner)
    }

    /// Sends [type] in the session: an event, or with [re] the answer to a request. Callers hold ``cond``.
    /// An answer is cached under its request's id (§8.2), and lost on its way when the test asked for that
    /// (``loseAnswers(_:)``).
    func reply(_ type: String, _ body: String, re: String? = nil, error: String? = nil) throws {
        guard let epoch = keyring.current() else { return }
        let ts = stampNow
        let inner = error.map { Inner(id: Ulid.new(), type: type, ts: ts, re: re, status: Inner.statusError, error: InnerError($0), body: Array(body.utf8)) }
            ?? Inner(id: Ulid.new(), type: type, ts: ts, re: re, status: re == nil ? nil : Inner.statusOK, body: Array(body.utf8))
        if let re { responses[re] = inner }
        if re != nil, answerLost(type) { return }
        queue(try epoch.seal(inner))
    }

    /// [m] refused with [error] (its code and message) and [body]. Callers hold ``cond``.
    func replyError(_ m: Inner, _ error: InnerError, body: String) throws {
        guard let epoch = keyring.current() else { return }
        let inner = Inner(id: Ulid.new(), type: m.type, ts: stampNow, re: m.id, status: Inner.statusError, error: error, body: Array(body.utf8))
        responses[m.id] = inner
        queue(try epoch.seal(inner))
    }

    /// The requests of enrollment (§3.5.7, §10.6, §10.8), and those of Settings (``settingsRequest(_:_:)``). Callers hold
    /// ``cond``.
    private func request(_ m: Inner) throws { // swiftlint:disable:this cyclomatic_complexity
        beforeHandling(m)
        // A locked vault does not collect: what is sent to it waits in its mailbox until the next unlock (§12.1).
        if !vaultOpen {
            lockedRequests.append(m)
            return
        }
        // §5.3, §8.2: an expired request is dropped unanswered (``stampsOnVaultClock``); a retransmission gets the cached
        // answer, never run again.
        guard try arrives(m) else { return }
        let body = try StrictJson.parseObject(m.body)
        // VAULT-MESSAGING 0.52.0 §3.5.4 "Using a UTK": a readable `utk_id` naming a UTK of the pool spends it before
        // anything else is checked, whatever the answer.
        presented = nil
        if let id = try? body.string("utk_id"), id.count == 16, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
           let ltk = utks.removeValue(forKey: id) {
            presented = (id, ltk)
        }
        if let r = refuseNextAnswers.removeValue(forKey: m.type) { return try replyError(m, r.error, body: r.body) }
        if let refusal = refusal(m.type) { return try reply(m.type, "{}", re: m.id, error: refusal) }
        // §3.6.3: the owner check's clock before each batch, then its gate on the app.
        try ownerCheckTick()
        if !holdAllows(m.type) { return try reply(m.type, "{}", re: m.id, error: "owner_check_required") }
        // §3.5.9: the holder's types to another app, then a clone alarm holding the credential operations (the UTK
        // already spent, 0.52.0).
        if notHolderValue, Self.holderTypes.contains(m.type) { return try reply(m.type, "{}", re: m.id, error: "forbidden") }
        if noHolderValue, Self.holderTypes.contains(m.type) {
            return try replyError(m, InnerError("credential_required", "no holder"), body: #"{"reason":"no_holder"}"#)
        }
        if let freeze = alarmRefusal(m.type) { return try reply(m.type, "{}", re: m.id, error: freeze) }
        switch m.type {
        case "credential.utk.get": try utkGet(m, body)
        case "credential.create": try create(m, body)
        case "credential.get": try reply(m.type, #"{"credential":"\#(currentBlob)","version":\#(credentialVersion),"updated_at":"2026-10-18T00:00:00Z"}"#, re: m.id)
        case "vault.status": try status(m)
        case Self.typeOwnerCheck: try ownerCheck(m, body)
        case "credential.ack": try credentialAck(m, body)
        case "settings.get": try reply(m.type, #"{"version":\#(settingsVersion),"settings":{"credential.backup":\#(backup),"credential.unlock_ttl_seconds":\#(unlockTtl),"owner_check.interval_seconds":\#(Int(checkInterval)),"owner_check.hold":\#(!holdOffValue)}}"#, re: m.id)
        case "settings.set": try settingsSet(m, body)
        case "vault.lock": try relayLock(m)
        case "vault.enroll.confirm":
            confirmedValue = true
            try reply(m.type, "{}", re: m.id)
        default: try settingsRequest(m, body)
        }
    }

    /// The vault opened: what waited in its mailbox is handled now, in order; a request whose `exp` has passed is dropped
    /// (§5.3). Callers hold ``cond``.
    func handleWhileLockedRequests() {
        let waiting = lockedRequests
        lockedRequests = []
        for m in waiting {
            if let exp = m.exp, stampNow > exp { continue }
            try? request(m)
        }
    }

    /// A request refused before anything is done: one the test made fail (`retry`, or ``refuse(_:with:times:)``'s code),
    /// or, until the credential exists, everything but what creates it (§3.5.7, `credential_required`). Callers hold
    /// ``cond``.
    private func refusal(_ type: String) -> String? {
        if failNextTypes.remove(type) != nil { return "retry" }
        if let r = refusedTypesValue[type], r.times > 0 {
            refusedTypesValue[type] = r.times > 1 ? (r.code, r.times - 1) : nil
            return r.code
        }
        let beforeCredential: Set = ["credential.utk.get", "credential.create", "credential.version", "vault.status", "vault.lock"]
        return !hasCredential && !beforeCredential.contains(type) ? "credential_required" : nil
    }

    /// settings.set against the current version (§10.8). Callers hold ``cond``.
    private func settingsSet(_ m: Inner, _ body: JsonObject) throws {
        guard try body.uint("version", min: 0, max: StrictJson.maxSafeInteger) == settingsVersion else {
            return try reply(m.type, "{}", re: m.id, error: "conflict")
        }
        if let set = try body.optObj("set") {
            if case .bool(_, let on)? = set["credential.backup"] { backup = on }
            if let ttl = try set.optUint("credential.unlock_ttl_seconds", min: 30, max: 3_600) { unlockTtl = Int(ttl) }
            try ownerCheckSettings(set)
        }
        settingsVersion += 1
        try reply(m.type, #"{"version":\#(settingsVersion)}"#, re: m.id)
    }

    /// credential.create (§3.5.5; release R `sealed{pin, password}`, §11.14.9) in vettid-vault's order: the UTK spent,
    /// then `exists` once the vault has one; a weak password when the test asked for it (§11.14.7). Callers hold
    /// ``cond``.
    private func create(_ m: Inner, _ body: JsonObject) throws {
        let utk = try body.string("utk_id")
        guard let ltk = spend(utk) else { return try reply(m.type, "{}", re: m.id, error: "utk_invalid") }
        let pt = try CredentialSeal.openPayload(ltk: ltk, vaultID: vaultID, utkID: utk, type: m.type, innerID: m.id, sealed: try body.base64("sealed"))
        if hasCredential { return try reply(m.type, "{}", re: m.id, error: "exists") }
        let p = try StrictJson.parseObject(pt)
        if let reason = weakPasswordReason {
            weakPasswordReason = nil
            return try reply(m.type, #"{"reason":"\#(reason)"}"#, re: m.id, error: "weak_password")
        }
        createsValue.append((try p.optString("pin"), try p.string("password")))
        hasCredential = true
        vaultPassword = try p.string("password")
        credentialVersion = 1
        // §3.6.1: the first credential.create starts the owner check's clock.
        startCheckClock()
        try reply(m.type, #"{"credential":"\#(currentBlob)","version":1,"key":"k","utks":\#(try issueUTKs(2))}"#, re: m.id)
    }

    /// The private key of the UTK [id] the request presented, already spent (VAULT-MESSAGING 0.52.0 §3.5.4); nil for
    /// any other (`utk_invalid`). Callers hold ``cond``.
    func spend(_ id: String) -> KemPrivateKey? {
        guard let p = presented, p.id == id else { return nil }
        presented = nil
        return p.ltk
    }

    /// The minimum time between two UTK resyncs of a device, divided by the release's `time_scale` (VAULT-MESSAGING
    /// 0.52.0 §3.5.4 "Resync", §11.10.8).
    static let resyncEvery: TimeInterval = 600

    /// `credential.utk.get`: the pool topped up (none while ``vaultPoolFull``); with `"resync": true` the pool dropped
    /// and 20 issued, once per 10 minutes (scaled), else `too_soon{allowed_after}` and nothing changed. Callers hold
    /// ``cond``.
    private func utkGet(_ m: Inner, _ body: JsonObject) throws {
        guard (try? body.bool("resync")) == true else {
            return try reply(m.type, #"{"utks":\#(vaultPoolFullValue ? "[]" : try issueUTKs(3))}"#, re: m.id)
        }
        let now = vaultNow
        if let last = lastResync {
            let after = last.addingTimeInterval(Self.resyncEvery / Double(max(timeScaleValue ?? 1, 1)))
            if now < after {
                resyncsValue.append(false)
                return try reply(m.type, #"{"allowed_after":"\#(Timestamps.formatMillis(after))"}"#, re: m.id, error: "too_soon")
            }
        }
        resyncsValue.append(true)
        lastResync = now
        utks = [:]
        vaultPoolFullValue = false
        try reply(m.type, #"{"utks":\#(try issueUTKs(20))}"#, re: m.id)
    }

    /// [n] fresh UTKs (§3.5.4), their private keys kept. Callers hold ``cond``.
    func issueUTKs(_ n: Int) throws -> String {
        var items: [String] = []
        for _ in 0..<n {
            let k = try KemPrivateKey.generate()
            let id = Bytes.hex(Randomness.bytes(8))
            utks[id] = k
            items.append(JsonBuilder().string("utk_id", id).base64("ek", k.publicKey.bytes).string("expires_at", Timestamps.formatMillis(Date().addingTimeInterval(3600))).build())
        }
        return JsonBuilder.array(items)
    }
}

// swiftlint:enable line_length
#endif
