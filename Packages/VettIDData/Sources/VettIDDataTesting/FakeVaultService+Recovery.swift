#if DEBUG
import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The phone that registered for a recovery: its identity key, KEM key and relay address.
struct FakeRecoveryPhone {
    let ik: [UInt8]
    let kem: KemPublicKey
    let relay: RelayAddr
}

/// The state of the fake's recovery (VAULT-MESSAGING §11.11, §11.14.6), under the service's lock.
struct FakeRecoveryStore {
    // The recovery the portal made (`armRecovery`).
    var recoveryID: String?
    var code = ""
    var locator = ""
    /// The phone that registered: its keys and relay address.
    var phone: FakeRecoveryPhone?
    /// The recovery record was removed by an `ok` open; the phone's first-handshake invitation stands until it pairs.
    var completed = false
    /// The recovery was cancelled or replaced: the member API takes its recovering key no more (`401`).
    var cancelled = false
    /// The registered phone is one of the vault's unlock keys though it was not adopted (a fixture for an unlock that opens
    /// without a bundle); otherwise a registered phone not adopted is answered random bytes, as a key the vault does not hold.
    var phoneHoldsUnlockKey = false
    var invitation = false
    var used = 0
    var lastWrong: String?
    // Scripted answers.
    var claimAnswers: [FakeVaultService.RecoveryClaimAnswer] = []
    var registerAnswers: [FakeVaultService.RecoveryRegisterAnswer] = []
    var openAnswers: [FakeVaultService.RecoveryOpenAnswer] = []
    // What was seen.
    var claims: [FakeVaultService.RecoveryClaimSeen] = []
    var registers: [FakeVaultService.RecoveryRegisterSeen] = []
    var opens: [FakeVaultService.RecoveryOpenSeen] = []
    var handshakeContexts: [String] = []
}

// TEST ONLY. Recovery on a new phone as vettid-vault answers it: the member API's claim and register
// (`POST /api/vault/recovery/claim`, `/register`), the open (`POST /api/vault/recovery/open`, §11.14.6) with the attempt
// counter, and the first handshake that follows (`ctx` = the recovery id), then the credential calls.
extension FakeVaultService {
    /// How the claim answers besides the recovery's own rules.
    public enum RecoveryClaimAnswer: Sendable {
        /// `409 recovery_not_available` (the recovery is not `available` yet), `409 recovery_unavailable` (no backup copy),
        /// `404 not_found`, `429` with a `Retry-After`, or no connection.
        case notAvailable, noBackup, notFound, limited(Int), offline
    }

    /// How the register answers: done (the default), refused by the enclave with a code, refused by the member API
    /// (`409 recovery_not_available`, `409 recovery_unavailable`), or not reaching it.
    public enum RecoveryRegisterAnswer: Sendable {
        case ok, refused(String), apiNotAvailable, apiNoBackup, offline
        /// The register is taken and applied, but its slot cannot be read (the answer is lost).
        case answerLostAfterRegistering
    }

    /// How the open answers besides the vault's own rules.
    public enum RecoveryOpenAnswer: Sendable {
        /// The vault's rules decide (the default).
        case vault
        /// A result with [code] that uses nothing (`quiet`, `wait`, `busy`, `retry`, `counter_unavailable`, `attestation`, …),
        /// with [attemptUsed] as the vault says it (nil: not said) and the counter's [used] when it answered.
        case refused(String, attemptUsed: Bool? = false, used: Int? = nil, retryAt: Date? = nil)
        /// The vault processes the request (an `ok` completes the recovery) but the answer is lost.
        case answerLost
        /// The slot holds bytes the phone cannot open.
        case unreadable
        /// The member API cannot be reached.
        case offline
    }

    public struct RecoveryClaimSeen: Sendable, Equatable {
        /// `qr`: by `vault_id` and `recovery_id`; `locator`: by a typed code's locator.
        public let kind: String
        public let vaultID: String?
        public let recoveryID: String?
        public let locator: String?
        public let appKey: [UInt8]
    }

    public struct RecoveryRegisterSeen: Sendable {
        public let userGuid: String
        public let vaultID: String
        public let recoveryID: String
        public let code: String
        public let platform: String?
        public let keyID: [UInt8]?
        public let apiKey: [UInt8]?
        public let name: String
        /// The member names of the request's body and of its `app`, sorted: what a typed and a scanned entry must agree on.
        /// The body as `name=value` lines, sorted, without the request id, and with the phone's own keys and attestation
        /// (`ik`, `kem`, `relay`, `api_key`, `device_attest`) named but not valued: what a scan and a typed entry must agree on.
        public let normalized: String
        public let shape: [String]
    }

    public struct RecoveryOpenSeen: Sendable {
        public let recoveryID: String
        public let pin: String
        public let password: String
        public let unlockSecret: [UInt8]
        public let manifestSerial: UInt64
    }

    /// What `armRecovery` made: the portal's QR and the typed code under it.
    public struct RecoveryCodeMade: Sendable {
        public let qr: String
        /// 48 characters in groups of four, as the portal shows them.
        public let typed: String
        public let vaultID: String
        public let recoveryID: String
        public let code: String
        public let locator: String
    }

    // MARK: - Switches and what was seen

    /// The vault a recovery restores: it holds a credential under [pin] and [password], and the portal shows a code.
    /// [typedApi] is the origin the typed code's check characters name (default: this service's member API).
    public func armRecovery(
        pin: String, password: String, typedApi: String? = nil, recoveryID: String? = nil, code: String? = nil, locator: String? = nil
    ) throws -> RecoveryCodeMade {
        try locked {
            let id = recoveryID ?? Ulid.new()
            let alphabet = Array(RecoveryCodes.alphabet)
            let code = code ?? String(Randomness.bytes(RecoveryCodes.length).map { alphabet[Int($0) % alphabet.count] })
            let locator = locator ?? String(Randomness.bytes(RecoveryCodes.locatorLength).map { alphabet[Int($0) % alphabet.count] })
            recovery.recoveryID = id
            recovery.code = code
            recovery.locator = locator
            recovery.phone = nil
            recovery.completed = false
            recovery.invitation = false
            recovery.used = 0
            hasCredential = true
            vaultMade = true
            vaultPin = pin
            vaultPassword = password
            credentialVersion = 4
            let check = try RecoveryCodes.typedCheck(api: typedApi ?? api.baseURL, locator: locator, code: code)
            let qr = #"{"v":1,"t":"r","vault_id":"\#(vaultID)","recovery_id":"\#(id)","code":"\#(code)","api":"\#(api.baseURL)"}"#
            return RecoveryCodeMade(
                qr: qr, typed: RecoveryCodes.grouped(locator + code + check), vaultID: vaultID, recoveryID: id, code: code, locator: locator
            )
        }
    }

    /// The recovery ended for the member API (cancelled, replaced): the recovering key's `status` is `401`, a claim `404`.
    public func cancelRecoveryAtApi() { locked { recovery.cancelled = true } }

    /// The registered phone is an unlock key of the vault though it was not adopted (an ok unlock without a bundle).
    public func registeredPhoneHoldsUnlockKey() { locked { recovery.phoneHoldsUnlockKey = true } }

    /// The next claims answer these, in order; then the recovery's rules.
    public func recoveryClaimAnswers(_ answers: RecoveryClaimAnswer...) { locked { recovery.claimAnswers += answers } }
    /// The next registers answer these, in order; then ``RecoveryRegisterAnswer/ok``.
    public func recoveryRegisterAnswers(_ answers: RecoveryRegisterAnswer...) { locked { recovery.registerAnswers += answers } }
    /// The next opens answer these, in order; then the vault's rules.
    public func recoveryOpenAnswers(_ answers: RecoveryOpenAnswer...) { locked { recovery.openAnswers += answers } }

    public var recoveryClaims: [RecoveryClaimSeen] { locked { recovery.claims } }
    public var recoveryRegisters: [RecoveryRegisterSeen] { locked { recovery.registers } }
    public var recoveryOpens: [RecoveryOpenSeen] { locked { recovery.opens } }
    /// The attempts the vault's counter shows used.
    public var recoveryAttemptsUsed: Int { locked { recovery.used } }
    /// The `ctx` of every first handshake the vault received in a recovery.
    public var recoveryHandshakeContexts: [String] { locked { recovery.handshakeContexts } }
    /// An `ok` open completed the recovery (the vault removed its record).
    public var recoveryCompleted: Bool { locked { recovery.completed } }
    /// The recovered phone's first handshake did not complete yet: it is one of the vault's unlock keys, and an unlock
    /// carries the vault's bundle (§11.14.6 "A lost ok").
    public var recoveryInvitation: Bool { locked { recovery.invitation } }
    /// The vault restored the phone's first-handshake state: the invitation is gone, as after the pairing.
    func recoveryPaired() { recovery.invitation = false }

    // MARK: - The member API's routes

    /// `POST /api/vault/recovery/claim`: by `vault_id` and `recovery_id`, or by a typed code's `locator`. Callers hold ``cond``.
    func recoveryClaim(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        let answer = recovery.claimAnswers.isEmpty ? nil : recovery.claimAnswers.removeFirst()
        switch answer {
        case .offline?: return .failure(.notConnectedToInternet)
        case .notAvailable?: return .json(409, #"{"error":"recovery_not_available"}"#)
        case .noBackup?: return .json(409, #"{"error":"recovery_unavailable"}"#)
        case .notFound?: return .json(404, #"{"error":"not_found"}"#)
        case .limited(let seconds)?: return .json(429, #"{"error":"rate_limited","retry_after":\#(seconds)}"#)
        case nil: break
        }
        guard let o = try? StrictJson.parseObject(r.body), let appKey = try? o.base64("app_key") else { return .json(400, #"{"error":"bad_request"}"#) }
        let locator = try? o.string("locator")
        let vault = try? o.string("vault_id"), id = try? o.string("recovery_id")
        recovery.claims.append(RecoveryClaimSeen(kind: locator == nil ? "qr" : "locator", vaultID: vault, recoveryID: id, locator: locator, appKey: appKey))
        let known = locator.map { $0 == recovery.locator } ?? (vault == vaultID && id == recovery.recoveryID)
        guard known, let rid = recovery.recoveryID, !recovery.completed, !recovery.cancelled else { return .json(404, #"{"error":"not_found"}"#) }
        return .json(200, #"{"user_guid":"\#(userGuid)","email_hint":"\#(emailHint)","vault_id":"\#(vaultID)","recovery_id":"\#(rid)"}"#)
    }

    /// `POST /api/vault/recovery/register`: the sealed `vault.recovery.register` (§11.11.3), answered in its slot. Callers
    /// hold ``cond``.
    func recoveryRegister(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        let answer = recovery.registerAnswers.isEmpty ? RecoveryRegisterAnswer.ok : recovery.registerAnswers.removeFirst()
        switch answer {
        case .offline: return .failure(.notConnectedToInternet)
        case .apiNotAvailable: return .json(409, #"{"error":"recovery_not_available"}"#)
        case .apiNoBackup: return .json(409, #"{"error":"recovery_unavailable"}"#)
        case .ok, .refused, .answerLostAfterRegistering: break
        }
        guard let o = try? StrictJson.parseObject(r.body), let rid = try? o.string("request_id"), let env = try? o.base64("envelope"),
              let request = try? openRequest(env), let body = try? StrictJson.parseObject(request.body), let app = try? body.obj("app"),
              let kem = try? KemPublicKey.parse(try app.base64("kem")), let ik = try? app.base64("ik"), let rel = try? app.obj("relay"),
              let addr = try? RelayAddr(url: rel.string("url"), mailbox: rel.string("mailbox"), pk: rel.base64("pk"))
        else { return .json(400, #"{"error":"bad_request"}"#) }
        let da = try? DeviceAttest.parse(try app.obj("device_attest"))
        recovery.registers.append(RecoveryRegisterSeen(
            userGuid: (try? body.string("user_guid")) ?? "", vaultID: (try? body.string("vault_id")) ?? "",
            recoveryID: (try? body.string("recovery_id")) ?? "", code: (try? body.string("code")) ?? "",
            platform: da?.platform, keyID: da?.iosKeyID, apiKey: try? app.base64("api_key"), name: (try? app.string("name")) ?? "",
            normalized: Self.normalized(body, app), shape: body.members.map(\.name).sorted() + app.members.map { "app." + $0.name }.sorted()
        ))
        let result: String
        if case .refused(let code) = answer {
            result = #"{"ok":false,"code":"\#(code)"}"#
        } else if (try? body.string("recovery_id")) != recovery.recoveryID || recovery.completed {
            result = #"{"ok":false,"code":"no_recovery"}"#
        } else if (try? body.string("code")) != recovery.code {
            result = #"{"ok":false,"code":"bad_code"}"#
        } else {
            recovery.phone = FakeRecoveryPhone(ik: ik, kem: kem, relay: addr)
            result = #"{"ok":true}"#
        }
        slots[rid] = try? Self.sealResult(kem, "vault.recovery.result", rid, result)
        if case .answerLostAfterRegistering = answer { lostSlots.insert(rid) }
        return .json(202, #"{"vault_id":"\#(vaultID)"}"#)
    }

    /// `POST /api/vault/recovery/open`: the sealed `vault.recovery.open` (§11.14.6) in the order of the spec that matters to
    /// the app: the registered phone, then the counter and the entry; an `ok` makes the phone the vault's app. Callers hold
    /// ``cond``.
    func recoveryOpen(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        let answer = recovery.openAnswers.isEmpty ? RecoveryOpenAnswer.vault : recovery.openAnswers.removeFirst()
        if case .offline = answer { return .failure(.notConnectedToInternet) }
        guard let o = try? StrictJson.parseObject(r.body), let rid = try? o.string("request_id"), let env = try? o.base64("envelope"),
              let request = try? openRequest(env), let body = try? StrictJson.parseObject(request.body)
        else { return .json(400, #"{"error":"bad_request"}"#) }
        let pin = (try? body.string("pin")) ?? "", password = (try? body.string("password")) ?? ""
        let secret = (try? body.base64("unlock_secret")) ?? []
        let recoveryID = (try? body.string("recovery_id")) ?? ""
        recovery.opens.append(RecoveryOpenSeen(
            recoveryID: recoveryID, pin: pin, password: password, unlockSecret: secret,
            manifestSerial: ((try? body.optUint("manifest_serial", min: 0, max: StrictJson.maxSafeInteger)) ?? nil) ?? 0
        ))
        // Another key than the registered phone's gets random bytes (§11.4), as an unlock does.
        guard let phone = recovery.phone, (try? body.base64("device_ik")) == phone.ik else {
            plainSlots[rid] = JsonBuilder().string("status", "done").base64("envelope", Randomness.bytes(5252)).build()
            return .json(202, "{}")
        }
        if case .unreadable = answer {
            plainSlots[rid] = JsonBuilder().string("status", "done").base64("envelope", Randomness.bytes(5252)).build()
            return .json(202, "{}")
        }
        let result = scripted(answer) ?? openResult(recoveryID: recoveryID, pin: pin, password: password, secret: secret, phone: phone)
        var lost = false
        if case .answerLost = answer { lost = true }
        slots[rid] = try? Self.sealResult(phone.kem, "vault.recovery.open.result", rid, result)
        if lost { lostSlots.insert(rid) }
        return .json(202, "{}")
    }

    /// The result a scripted ``RecoveryOpenAnswer/refused(_:attemptUsed:used:retryAt:)`` stands for; nil for any other answer.
    private func scripted(_ answer: RecoveryOpenAnswer) -> String? {
        guard case .refused(let code, let attemptUsed, let used, let retryAt) = answer else { return nil }
        var b = JsonBuilder().bool("ok", false).string("code", code)
        if let attemptUsed { b = b.bool("attempt_used", attemptUsed) }
        if let used { b = b.raw("attempts", #"{"used":\#(used),"of":10}"#) }
        if let retryAt { b = b.string("retry_at", Timestamps.formatMillis(retryAt)) }
        return b.build()
    }

    /// The vault's own rules. Callers hold ``cond``.
    private func openResult(recoveryID: String, pin: String, password: String, secret: [UInt8], phone: FakeRecoveryPhone) -> String {
        func refused(_ code: String, used: Bool, counted: Bool = true) -> String {
            var b = JsonBuilder().bool("ok", false).string("code", code).bool("attempt_used", used)
            if counted { b = b.raw("attempts", #"{"used":\#(recovery.used),"of":10}"#) }
            return b.build()
        }
        guard recoveryID == recovery.recoveryID, !recovery.completed, !recovery.cancelled else { return refused("no_recovery", used: false, counted: false) }
        guard secret.count == 32 else { return refused("bad_request", used: false, counted: false) }
        if recovery.used >= 10 { return refused("exhausted", used: false) }
        let entry = "\(pin)\n\(password)"
        guard pin == vaultPin, Passwords.nfc(password) == vaultPassword.map(Passwords.nfc) else {
            if recovery.lastWrong == entry { return refused("wrong_again", used: false) }
            recovery.used += 1
            recovery.lastWrong = entry
            var b = JsonBuilder().bool("ok", false).string("code", "wrong").bool("attempt_used", true).raw("attempts", #"{"used":\#(recovery.used),"of":10}"#)
            // From the second attempt on, a wait begins (§11.14.6 "The schedule of waits"; here an hour).
            if recovery.used >= 2 { b = b.string("retry_at", Timestamps.formatMillis(Date().addingTimeInterval(3600))) }
            return b.build()
        }
        recovery.used += 1
        // The completion: the phone is the vault's app, the vault runs, and the phone's first handshake is invited.
        recovery.completed = true
        recovery.invitation = true
        recovery.lastWrong = nil
        vaultSecret = secret
        device = (phone.kem, phone.relay)
        vaultOpen = true
        statusState = Self.unlocked
        let token = (try? self.token(phone.relay)) ?? ""
        return JsonBuilder().bool("ok", true).uint("state_seq", stateSeq).uint("header_seq", headerSeq).string("token", token)
            .base64("vault_bundle", vaultBundle()).string("release", Self.pcr0(releases.serving)).uint("release_number", releases.serving)
            .bool("attempt_used", true).raw("attempts", #"{"used":\#(recovery.used),"of":10}"#).build()
    }

    static func normalized(_ body: JsonObject, _ app: JsonObject) -> String {
        let own: Set = ["ik", "kem", "relay", "api_key", "device_attest"]
        var lines = body.members.filter { $0.name != "request_id" && $0.name != "app" }.map { "\($0.name)=\($0.value)" }
        lines += app.members.map { "app.\($0.name)=" + (own.contains($0.name) ? "<own>" : "\($0.value)") }
        return lines.sorted().joined(separator: "\n")
    }

    /// `GET /api/vault/status` for the recovering phone's key: `401` once the recovery ended without it; `recovery: null` once the
    /// vault made it the app key (MEMBER-API "Completed"); the recovery `registered` before. Callers hold ``cond``.
    func recoveryStatusField() -> (unauthorized: Bool, member: String) {
        guard recovery.phone != nil else { return (false, "") }
        if recovery.completed { return (false, "") }
        if recovery.cancelled { return (true, "") }
        return (false, #","recovery":{"state":"registered","available_at":""}"#)
    }

    /// The vault's bundle (§3.4): its identity, KEM and relay keys.
    func vaultBundle() -> [UInt8] {
        let vaultRelay = JsonBuilder().string("url", self.vaultRelay.baseURL).string("mailbox", vaultMailbox).base64("pk", relayKey.publicKey).build()
        return JsonBuilder().uint("v", 1).uint("suite", 2).base64("ik", ik.publicKey).base64("kem", kem.publicKey.bytes).raw("relay", vaultRelay).bytes()
    }

    /// An unlock's `vault_bundle` for the phone a completed recovery made the app, until its first handshake completes
    /// (§11.14.6 "A lost ok"); the unlock also drops a handshake begun and not completed. Callers hold ``cond``.
    func recoveryBundleMember() -> String {
        guard recovery.invitation else { return "" }
        responder = nil
        return #","vault_bundle":"\#(Base64s.encodeStd(vaultBundle()))""#
    }
}

// swiftlint:enable line_length
#endif
