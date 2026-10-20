#if DEBUG
import CryptoKit
import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake service) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault service as the vault manager meets it, in process: the member API (setup-code redeem, the
/// enclave route, the alternate channel's enroll and its result slot, the status), the served release manifest, one
/// enclave instance, the relay of this device's mailbox and the vault behind its own mailbox (the first handshake, then
/// the credential calls of enrollment). Built from VettIDCrypto as vettid-vault's reference client and enclave are;
/// nothing in it is checked against Nitro (the manager's enclave check is the test's, ``enclaveCheck``). Switches make
/// each answer the onboarding screens show; every request the vault received is recorded.
public final class FakeVaultService: @unchecked Sendable {
    public static let testOnlyMarker = "VETTID TEST ONLY: the fake vault service"
    public static let pcr0 = String(repeating: "a3", count: 48)
    static let pcr1 = String(repeating: "11", count: 48)
    static let pcr2 = String(repeating: "22", count: 48)

    /// How the redeem answers.
    public enum RedeemAnswer: Sendable { case ok, invalidCode, offline }

    /// How the enrollment answers: done; refused by the enclave (`vault_exists`, `attestation`); done by the vault (it
    /// makes the vault and deposits `vault.enrolled`) but its answer lost in transport; not reaching the API at all. Once
    /// the vault exists, every later enrollment is answered `vault_exists`, as a real vault answers it.
    public enum EnrollAnswer: Sendable {
        case ok, refused(String), answerLost, offline
        /// As ``answerLost``, with `vault.enrolled` delivered only after the next request reached the vault.
        case answerLostEnrolledLate
        /// The request is taken (`202`) and makes nothing, but its result slot cannot be read (a timeout).
        case slotLost
        /// The request makes nothing and its slot says `expired` (§11.5: not forwarded, or no answer from the enclave).
        case slotExpired
        /// The enclave could not decrypt the request: the slot is done with `etk_unknown` and no envelope.
        case etkUnknown
    }

    /// What the vault received in one enrollment request.
    public struct EnrollSeen: Sendable {
        public let pin: String
        public let unlockSecret: [UInt8]?
    }

    public let api = FakeHTTPServer()
    /// The relay of this device's mailbox.
    public let relay = FakeHTTPServer()
    /// The relay of the vault's mailbox.
    public let vaultRelay = FakeHTTPServer()

    public let vaultID = "0123456789abcdef0123456789abcdef"
    public let userGuid = "user-0001"
    public let emailHint = "m***@example.com"
    public let email = "member@example.com"
    public let typedCode = "ABCD2345"
    public let secret = "AbCdEfGhIjKlMnOpQrStUv"
    let instanceID = "i-0123456789abcdef0"

    let cond = NSCondition()
    /// The VAULT-MESSAGING §16 TEST manifest key (private scalar 32 × 0x21, public; key_id 1edbb48b6669decd), which no
    /// build pins.
    let manifestSigner = FakeVaultService.testManifestSigner
    let etk: KemPrivateKey
    var ik = Ed25519PrivateKey.generate()
    var kem: KemPrivateKey
    let relayKey = Ed25519PrivateKey.generate()
    let keyring = Keyring()

    // Switches (set by the test; read under ``cond``).
    var redeemAnswerValue: RedeemAnswer = .ok
    var enrollAnswers: [EnrollAnswer] = []
    var capabilitiesValue: [String]? = [Capabilities.recoveryOffered, Capabilities.recoveryR]
    var timeScaleValue: UInt64?
    var recoveryCounterValue = "ok"
    var timeScalesValue = TimeScalePolicy.production
    var weakPasswordReason: String?
    var statusState = "unlocked"
    var noVault = false
    /// The published manifest's serial; nil: nothing is published (404).
    var publishedSerialValue: UInt64? = 7
    var manifestFetchesValue = 0
    var manifestOfflineValue = false
    var manifestBrokenValue = false
    /// The highest manifest serial the vault was sent (its sealed header's, §11.10.4).
    var vaultManifestSerial: UInt64 = 7

    // The state of the fake (under ``cond``).
    var slots: [String: [UInt8]] = [:]
    var queued: [RelayMessage] = []
    var device: (kem: KemPublicKey, relay: RelayAddr)?
    var responder: Responder?
    var utks: [String: KemPrivateKey] = [:]
    var hasCredential = false
    var vaultMade = false
    var failNextTypes: Set<String> = []
    /// A vault.enrolled held back until the next enrollment request (``EnrollAnswer/answerLostEnrolledLate``).
    struct LateEnrolled {
        let kem: KemPublicKey
        let relay: RelayAddr
        let nonce: [UInt8]
    }

    var lateEnrolled: LateEnrolled?
    var lostSlots: Set<String> = []
    var plainSlots: [String: String] = [:]
    var enclaveOfflineValue = false
    var redeemVaultID: String?
    var holdLateValue = false
    var settingsVersion: UInt64 = 1
    var backup = true
    var redeemsValue = 0
    var enrollsValue: [EnrollSeen] = []
    var createsValue: [(pin: String?, password: String)] = []
    var confirmedValue = false

    // The unlock and the lock (FakeVaultService+Unlock.swift), under ``cond``.
    /// Whether the vault itself runs (the enclave's truth; ``statusState`` is the member API's view of it).
    var vaultOpen = true
    var vaultPin: String?
    var vaultSecret: [UInt8]?
    var pinFailures = 0
    var backoffUntil: Date?
    var headerSeq: UInt64 = 1
    var stateSeq: UInt64 = 2
    var vaultClockAhead: TimeInterval = 0
    var unlockAnswers: [UnlockAnswer] = []
    var unlocksValue: [UnlockSeen] = []
    /// The releases the fake runs and the release updates it was sent (``FakeVaultService+Release.swift``).
    var releases = FakeReleases()
    var relayLockAnswerValue: RelayLockAnswer = .lock
    var memberLockAnswerValue: MemberLockAnswer = .lock
    var heldSlots: [String: [UInt8]] = [:]
    var holdMessagesValue = false
    var relayLocksValue = 0
    var memberLocksValue = 0

    // The owner check (FakeVaultService+OwnerCheck.swift), under ``cond``, on the vault's clock.
    var vaultPassword: String?
    var credentialVersion: Int64 = 1 { didSet { credentialAcked = false } }
    var checkLastAt: Date?
    var checkDeadline: Date?
    var checkInterval: TimeInterval = 86_400
    var checkFailures = 0
    /// The state the vault last acted on ("", "due" or "held"), as vettid-vault's `OwnerCheck.Gate`.
    var checkGate = ""
    var waitingCounts = [0, 0, 0, 0]
    var holdOffValue = false
    var holdOffUntilValue: Date?
    var passwordFailures = 0
    var passwordNotBefore: Date?
    var presentRecordedValue = true
    var ownerChecksValue: [OwnerCheckSeen] = []

    // Settings (FakeVaultService+Settings.swift), under ``cond``.
    var snapshotJSON: String?
    var snapshotVersion = 0
    var nameRequestJSON: String?
    var nameSeq: Int64 = 0
    var nameAllowedAfter: Date?
    var nameSetsValue: [NameSetSeen] = []
    var pinChangesValue: [PinChangeSeen] = []
    var passwordChangesValue: [PasswordChangeSeen] = []
    var epochAdvancedValue = true
    var criticalItemsValue = 0
    var unlockTtl = 300
    var windowUntil: Date?
    // A lost answer (FakeVaultService+Replay.swift), under ``cond``.
    /// Answers cached by the request's inner id (§8.2: 24 hours; here for the fake's life).
    var responses: [String: Inner] = [:]
    var seenRequests: Set<String> = []
    var lostAnswerTypes: Set<String> = []
    var lostRequestTypes: Set<String> = []
    /// ``loseAnswers(_:from:)``: the answers of ``lostAnswerTypes`` are lost only once a request of this type arrived.
    var lostAnswersFrom: String?
    var lostAnswersStarted = true
    /// ``moveCredential(on:)`` and ``lockByItself(on:)``: what happens when the next request of the type arrives.
    var moveCredentialOn: String?
    var lockOn: String?
    var stampsOnVaultClockValue = false
    var requestsSeenValue: [String] = []
    /// Requests that reached the vault's mailbox while it was locked, handled after the next unlock (subject to `exp`).
    var lockedRequests: [Inner] = []
    var lastExpValue: [String: Date] = [:]
    // New phone secret and Delete vault (FakeVaultService+Secrets.swift), under ``cond``.
    var renewsValue: [RenewSeen] = []
    var deletesValue: [DeleteSeen] = []
    /// The vault deleted itself (§12.5): it answers nothing more and its mailbox refuses every deposit.
    var vaultDeletedValue = false
    var statusLagsDeletionValue = false
    var slotQueuedAfterDeletionValue = 0
    var statusGateValue: FakeHTTPServer.Gate?
    // The rotation, a new credential and the clone alarm (FakeVaultService+Credential.swift), under ``cond``.
    var alarmValue: FakeAlarm?
    var credentialKeyValue = FakeVaultService.credentialKeyID
    var rotationsValue: [String] = []
    var resetsValue: [ResetSeen] = []
    /// `credential.version` answers without its `key` (a vault before staging release 18).
    var versionWithoutKeyValue = false
    /// Requests of these types refused with the code, as many more times as the count says (``refuse(_:with:times:)``).
    var refusedTypesValue: [String: (code: String, times: Int)] = [:]
    var alarmConfirmsValue: [Bool] = []
    /// Which credential the blob is of (a reset makes a new one) and whether the holder confirmed the current version.
    var credentialGeneration = 0
    var credentialAcked = true
    /// The device's identity key (from its hs.init) and the vault-initiated rekey on its way after an identity rotation.
    var deviceIk: [UInt8]?
    var rekeying: Initiator?
    var identityRotationsValue = 0
    /// Connections, invitations, requests and blocks, and the emulated peer (FakeVaultService+Connections.swift).
    var social = FakeSocial()

    public init() throws {
        etk = try KemPrivateKey.generate()
        kem = try KemPrivateKey.generate()
        api.handle { [weak self] r in self?.answerAPI(r) ?? .empty(500) }
        relay.handle { [weak self] r in self?.answerRelay(r) ?? .empty(500) }
        vaultRelay.handle { [weak self] r in self?.answerVaultRelay(r) ?? .empty(500) }
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        cond.lock()
        defer { cond.unlock() }
        return try body()
    }

    // MARK: - Switches and what was seen

    public var redeemAnswer: RedeemAnswer {
        get { locked { redeemAnswerValue } }
        set { locked { redeemAnswerValue = newValue } }
    }

    /// The next enrollments answer these, in order; then ``EnrollAnswer/ok``.
    public func enrollAnswers(_ answers: EnrollAnswer...) { locked { enrollAnswers += answers } }

    /// The instance's capabilities (§11.10.9); nil: a descriptor from before release R lists none.
    public var capabilities: [String]? {
        get { locked { capabilitiesValue } }
        set { locked { capabilitiesValue = newValue } }
    }

    /// The instance's time scale (§11.10.9), in its descriptor and `vault.status`; nil: a release before it.
    public var timeScale: UInt64? {
        get { locked { timeScaleValue } }
        set { locked { timeScaleValue = newValue } }
    }

    /// `vault.status`'s `recovery.counter` (§11.14.11): `ok` unless a test makes it `unavailable`.
    public var recoveryCounter: String {
        get { locked { recoveryCounterValue } }
        set { locked { recoveryCounterValue = newValue } }
    }

    /// The time scales the phone's build accepts (``trust``): production's unless a test says.
    public var timeScales: TimeScalePolicy {
        get { locked { timeScalesValue } }
        set { locked { timeScalesValue = newValue } }
    }

    /// The next `credential.create` is refused `weak_password` with this reason (§11.14.7).
    public func refusePassword(_ reason: String) { locked { weakPasswordReason = reason } }

    /// The next request of [type] in the session is answered `retry` (nothing done): the app stops there, as if it
    /// crashed before the vault acted.
    public func failNext(_ type: String) { locked { _ = failNextTypes.insert(type) } }

    /// The vault already holds this phone's credential (a `credential.create` whose answer was lost): the next create is
    /// answered `exists`.
    public func credentialAlreadyCreated() { locked { hasCredential = true } }

    /// What `GET /api/vault/status` says: the vault's state, or no vault at all (`"vault": null`).
    public func status(_ state: String, noVault: Bool = false) {
        locked {
            statusState = state
            self.noVault = noVault
        }
    }

    /// The enclave route cannot be reached: an enrollment fails before any request is posted.
    public var enclaveOffline: Bool {
        get { locked { enclaveOfflineValue } }
        set { locked { enclaveOfflineValue = newValue } }
    }

    /// A held-back `vault.enrolled` (``EnrollAnswer/answerLostEnrolledLate``) waits for ``deliverLateEnrolled()``
    /// instead of the next request.
    public var holdLateEnrolled: Bool {
        get { locked { holdLateValue } }
        set { locked { holdLateValue = newValue } }
    }

    /// Delivers the held-back `vault.enrolled` now.
    public func deliverLateEnrolled() {
        locked {
            if let late = lateEnrolled {
                lateEnrolled = nil
                try? queueEnrolled(late.kem, late.relay, nonce: late.nonce)
            }
        }
    }

    /// The next redeems name this vault instead of ``vaultID`` (another account's code).
    public func redeemNames(_ vaultID: String?) { locked { redeemVaultID = vaultID } }

    public var redeems: Int { locked { redeemsValue } }
    public var enrolls: [EnrollSeen] { locked { enrollsValue } }
    public var credentialCreates: [(pin: String?, password: String)] { locked { createsValue } }
    public var backupSetting: Bool { locked { backup } }
    public var confirmed: Bool { locked { confirmedValue } }

    /// The setup QR's text for this service (§11.12.1).
    public var setupQR: String { #"{"v":1,"t":"e","api":"\#(api.baseURL)","s":"\#(secret)"}"# }

    // MARK: - Trust

    /// The manifest key the served manifest is signed with: the manager's pin.
    public var manifestKey: ManifestKey { get throws { try ManifestKey(spki: Array(manifestSigner.publicKey.derRepresentation)) } }

    public var trust: AltTrust { get throws { AltTrust(nitroRoots: [], manifestKeys: [try manifestKey], timeScales: timeScales) } }

    /// The enclave check of the tests (§11.2 without Nitro): the descriptor as served, the manifest's entry for its
    /// release.
    public static let enclaveCheck: EnclaveCheck = { descriptor, _, manifest, _, _ in
        let d = try Descriptor.parse(descriptor)
        guard let r = manifest.byPcr0(d.release) else { throw AttestationError.release("not listed", unknown: true) }
        return VerifiedEnclave(descriptor: d, measurements: r.measurements, release: r)
    }

    /// The served manifest of [serial], listing this service's release 3 `active` (and release 4 `active` when
    /// [release4]), signed by [signer] (the TEST key).
    public func servedManifest(serial: UInt64 = 7, signer: P256.Signing.PrivateKey? = nil, release4: Bool = false) throws -> [UInt8] {
        let entries = (release4 ? [3, 4] : [3]).map { (n: UInt64) in
            JsonBuilder().uint("release", n).string("pcr0", Self.pcr0(n)).string("pcr1", Self.pcr1).string("pcr2", Self.pcr2).string("seal_key", "arn:aws:kms:us-east-1:000000000000:key/test\(n == 3 ? "" : String(n))").string("status", "active").string("published_at", "2026-09-01T00:00:00Z").string("notes", "https://vettid.org/security/releases/\(n)/").build()
        }
        let m = JsonBuilder().uint("v", 1).uint("serial", serial).string("issued_at", "2026-10-02T12:00:00Z").raw("releases", JsonBuilder.array(entries)).bytes()
        let key = signer ?? manifestSigner
        let sig = try key.signature(for: Array(ReleaseManifest.label.utf8) + [0] + m).rawRepresentation
        let keyID = try ManifestKey(spki: Array(key.publicKey.derRepresentation)).keyID
        return JsonBuilder().base64("manifest", m).base64("sig", Array(sig)).string("key_id", keyID).bytes()
    }

    // MARK: - The member API

    private func answerAPI(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer { // swiftlint:disable:this cyclomatic_complexity
        locked {
            if r.path == MemberApiClient.manifestPath { return manifestAnswer() }
            // Every vault route is signed by the app key (§11.12.2).
            guard r.header(AppRequestSigning.header) != nil else { return .json(401, #"{"error":"unauthorized"}"#) }
            switch (r.method, r.path) {
            case ("POST", "/api/vault/enroll/redeem"): return redeem(r)
            case ("GET", "/api/vault/enclave"): return enclave(r)
            case ("POST", "/api/vault/enroll"): return enroll(r)
            case ("POST", "/api/vault/unlock"): return unlock(r)
            case ("POST", "/api/vault/lock"): return memberLock(r)
            case ("GET", "/api/vault/status"):
                let a: FakeHTTPServer.Answer = if noVault || vaultDeletedValue && !statusLagsDeletionValue {
                    .json(200, #"{"vault":null}"#)
                } else {
                    .json(200, #"{"vault":{"vault_id":"\#(vaultID)","state":"\#(statusState)","release":{"number":\#(releases.routed),"status":"active"}}}"#)
                }
                return statusGateValue.map { .held($0, a) } ?? a
            default:
                if r.method == "GET", r.path.hasPrefix("/api/vault/requests/") { return slot(String(r.path.dropFirst("/api/vault/requests/".count))) }
                return .json(404, #"{"error":"not_found"}"#)
            }
        }
    }

    private func redeem(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        switch redeemAnswerValue {
        case .offline: return .failure(.notConnectedToInternet)
        case .invalidCode: return .json(404, #"{"error":"invalid_code"}"#)
        case .ok: break
        }
        guard let o = try? StrictJson.parseObject(r.body), (try? o.base64("app_key")) != nil else { return .json(400, #"{"error":"bad_request"}"#) }
        let bySecret = (try? o.string("s")) == secret || (try? o.string("secret")) == secret
        let byCode = (try? o.string("email")) == email && (try? o.string("code")) == typedCode
        guard bySecret || byCode else { return .json(404, #"{"error":"invalid_code"}"#) }
        redeemsValue += 1
        return .json(200, #"{"vault_id":"\#(redeemVaultID ?? vaultID)","user_guid":"\#(userGuid)","email_hint":"\#(emailHint)"}"#)
    }

    private func enclave(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        if enclaveOfflineValue { return .failure(.notConnectedToInternet) }
        guard let n = route(asked: Self.askedRelease(r)) else { return .json(409, #"{"error":"vault_busy","retry_after":1}"#) }
        let release = Self.pcr0(n)
        let d = Descriptor.marshal(instanceID: instanceID, etk: etk.publicKey, release: release, notAfter: Date().addingTimeInterval(3600), capabilities: capabilitiesValue, timeScale: timeScaleValue)
        return .json(200, JsonBuilder().string("instance_id", instanceID).string("release", release).base64("descriptor", d).base64("attestation", [1, 2, 3]).build())
    }

    private func slot(_ requestID: String) -> FakeHTTPServer.Answer {
        if lostSlots.contains(requestID) { return .failure(.timedOut) }
        if let plain = plainSlots[requestID] { return .json(200, plain) }
        guard let env = slots[requestID] else { return .json(200, #"{"status":"queued"}"#) }
        if vaultDeletedValue, slotQueuedAfterDeletionValue > 0 {
            slotQueuedAfterDeletionValue -= 1
            return .json(200, #"{"status":"queued"}"#)
        }
        return .json(200, JsonBuilder().string("status", "done").base64("envelope", env).build())
    }

    /// vault.enroll (§11.3): opened with the ETK; the vault made, `vault.enrolled` queued for the device, the sealed
    /// result in the slot.
    private func enroll(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        let answer = enrollAnswers.isEmpty ? EnrollAnswer.ok : enrollAnswers.removeFirst()
        if case .offline = answer { return .failure(.notConnectedToInternet) }
        guard let o = try? StrictJson.parseObject(r.body), let rid = try? o.string("request_id"), let env = try? o.base64("envelope"),
              let request = try? openRequest(env), let body = try? StrictJson.parseObject(request.body), let app = try? body.obj("app"),
              let appKem = try? KemPublicKey.parse(try app.base64("kem")), let rel = try? app.obj("relay"),
              let addr = try? RelayAddr(url: rel.string("url"), mailbox: rel.string("mailbox"), pk: rel.base64("pk"))
        else { return .json(400, #"{"error":"bad_request"}"#) }
        let nonce = (try? body.base64("nonce")) ?? []
        enrollsValue.append(EnrollSeen(pin: (try? body.string("pin")) ?? "", unlockSecret: try? body.base64("unlock_secret")))
        // A vault.enrolled held back arrives once a later request reached the vault, whatever that one is answered.
        if let late = lateEnrolled, !holdLateValue {
            lateEnrolled = nil
            try? queueEnrolled(late.kem, late.relay, nonce: late.nonce)
        }
        if unansweredSlot(answer, rid) { return .json(202, #"{"vault_id":"\#(vaultID)"}"#) }
        if case .refused(let code) = answer {
            slots[rid] = try? Self.sealResult(appKem, "vault.enroll.result", rid, #"{"ok":false,"code":"\#(code)"}"#)
        } else if vaultMade {
            // Create-only (§11.3): the vault an earlier request made answers every later one so.
            slots[rid] = try? Self.sealResult(appKem, "vault.enroll.result", rid, #"{"ok":false,"code":"vault_exists"}"#)
        } else {
            device = (appKem, addr)
            vaultMade = true
            vaultPin = enrollsValue.last?.pin
            vaultSecret = enrollsValue.last?.unlockSecret
            do {
                if case .answerLostEnrolledLate = answer {
                    lateEnrolled = LateEnrolled(kem: appKem, relay: addr, nonce: nonce)
                    return .failure(.networkConnectionLost)
                }
                try queueEnrolled(appKem, addr, nonce: nonce)
                slots[rid] = try Self.sealResult(appKem, "vault.enroll.result", rid, #"{"ok":true,"vault_id":"\#(vaultID)"}"#)
            } catch {
                return .empty(500)
            }
            if case .answerLost = answer { return .failure(.networkConnectionLost) }
        }
        return .json(202, #"{"vault_id":"\#(vaultID)"}"#)
    }

    /// A request taken without a sealed result: its slot cannot be read, says `expired`, or carries `etk_unknown`.
    /// Callers hold ``cond``.
    private func unansweredSlot(_ answer: EnrollAnswer, _ rid: String) -> Bool {
        switch answer {
        case .slotLost: lostSlots.insert(rid)
        case .slotExpired: plainSlots[rid] = #"{"status":"expired"}"#
        case .etkUnknown: plainSlots[rid] = #"{"status":"done","code":"etk_unknown"}"#
        default: return false
        }
        return true
    }

    func openRequest(_ env: [UInt8]) throws -> Inner {
        let (padded, _) = try Envelope.openSealed(try Envelope.parse(env), key: etk)
        return try Inner.parse(try Padding.unpadFixed(padded, Padding.altChannelRequest), .sealed)
    }

    static func sealResult(_ kem: KemPublicKey, _ type: String, _ requestID: String, _ body: String, ts: Date = Date()) throws -> [UInt8] {
        let inner = Inner(id: Ulid.new(), type: type, ts: ts, re: requestID, status: Inner.statusOK, body: Array(body.utf8))
        return try Envelope.sealSealed(kem, senderKid: Kid.anonymous, padded: try Padding.padFixed(try inner.marshal(.sealed), Padding.altChannel)).0
    }
}

// swiftlint:enable line_length
#endif
