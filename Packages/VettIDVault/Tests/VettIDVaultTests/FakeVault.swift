import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake relay) stay on one line each.
// swiftlint:disable line_length

/// The fake relay: records deposits, serves queued messages to collects, refuses on demand.
final class FakeRelay: @unchecked Sendable {
    let server = FakeHTTPServer()
    private let lock = NSLock()
    private var deposits: [(mailbox: String, payload: [UInt8])] = []
    private var depositWaiters: [CheckedContinuation<Void, Never>] = []
    var refuseDeposits: String? { get { lock.withLock { refuse } } set { lock.withLock { refuse = newValue } } }
    var refuseStatus: Int { get { lock.withLock { status } } set { lock.withLock { status = newValue } } }
    var refuseCollect: String? { get { lock.withLock { collectRefusal } } set { lock.withLock { collectRefusal = newValue } } }
    var serveMailbox: Bool { get { lock.withLock { serve } } set { lock.withLock { serve = newValue } } }
    /// Runs at each accepted deposit, before the relay answers it (so before the depositing device goes on).
    var onDeposit: (@Sendable () -> Void)? { get { lock.withLock { depositHook } } set { lock.withLock { depositHook = newValue } } }
    private var depositHook: (@Sendable () -> Void)?
    /// Refused deposits are stored all the same (``refuseDeposits``).
    var recordRefused: Bool { get { lock.withLock { recordsRefused } } set { lock.withLock { recordsRefused = newValue } } }
    private var recordsRefused = false
    /// Accepted deposits are answered only when the gate opens (a relay that stalls). The wait is on a dispatch thread of its
    /// own, not on the relay's lock or the cooperative pool.
    var holdDeposits: FakeHTTPServer.Gate? { get { lock.withLock { heldGate } } set { lock.withLock { heldGate = newValue } } }
    private var heldGate: FakeHTTPServer.Gate?
    /// Every deposit fails in transport with this code (no answer at all).
    var failDeposits: URLError.Code? { get { lock.withLock { transportFailure } } set { lock.withLock { transportFailure = newValue } } }
    private var transportFailure: URLError.Code?
    private var refuse: String?
    /// The next [n] deposits are refused with [refuseDeposits]'s code, then the relay accepts again (0: all of them).
    var refuseOnly: Int { get { lock.withLock { refuseCount } } set { lock.withLock { refuseCount = newValue } } }
    private var refuseCount = 0
    /// The refusal that follows the counted ones (``refuseOnly``), instead of the relay accepting again.
    var thenRefuse: (status: Int, code: String)? { get { lock.withLock { followUp } } set { lock.withLock { followUp = newValue } } }
    private var followUp: (status: Int, code: String)?
    private var status = 403
    private var collectRefusal: String?
    private var serve = false
    private var queued: [RelayMessage] = []
    private(set) var refused = 0
    private(set) var acked: [String] = []
    /// Blobs by id (RELAY-PROTOCOL §6.8), with the mailbox each was put to; [refuseBlobs] refuses every put with its code.
    private(set) var blobs: [String: (mailbox: String, bytes: [UInt8])] = [:]
    var refuseBlobs: String? { get { lock.withLock { blobRefusal } } set { lock.withLock { blobRefusal = newValue } } }
    private var blobRefusal: String?

    /// Claims by id (RELAY-PROTOCOL §6.9): fetched once, then gone (`claim_unknown`).
    private var claims: [String: [UInt8]] = [:]

    func putClaim(_ id: String, _ bytes: [UInt8]) { lock.withLock { claims[id] = bytes } }

    /// Puts a blob as another depositor would (the vault uploading to this device's mailbox).
    func putBlob(_ id: String, _ bytes: [UInt8], mailbox: String) { lock.withLock { blobs[id] = (mailbox, bytes) } }

    func blob(_ id: String) -> [UInt8]? { lock.withLock { blobs[id]?.bytes } }

    init() {
        server.handle { [weak self] r in self?.answer(r) ?? .empty(500) }
    }

    var baseURL: String { server.baseURL }

    func queue(_ m: RelayMessage) { lock.withLock { queued.append(m) } }

    private func answer(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer { // swiftlint:disable:this cyclomatic_complexity
        lock.withLock {
            let path = r.path
            if path == "/v1/register" {
                return .json(201, #"{"mailbox_id":"x","limits":{"max_payload_bytes":262144,"message_ttl_seconds":1,"visibility_timeout_seconds":60,"max_token_lifetime_seconds":1,"open_token_max_lifetime_seconds":1,"max_claim_bytes":1,"claim_ttl_seconds":1}}"#)
            }
            if path.hasPrefix("/v1/mailbox/"), r.method == "POST" {
                if let code = transportFailure { return .failure(code) }
                let refusal = depositRefusal()
                // A refusal the relay gave after it had stored the message (its answer to the first attempt was lost, and the
                // retry was refused): the message is there, the depositor is told otherwise.
                if let refusal, !recordsRefused { return refusal }
                let payload = (try? StrictJson.parseObject(r.body).base64("payload")) ?? []
                deposits.append((String(path.dropFirst("/v1/mailbox/".count)), payload))
                depositHook?()
                let ws = depositWaiters
                depositWaiters.removeAll()
                for w in ws { w.resume() }
                if let refusal { return refusal }
                let ok = FakeHTTPServer.Answer.json(201, #"{"msg_id":"\#(Ulid.new())"}"#)
                if let gate = heldGate { return .held(gate, ok) } // (the lock is held: the stored properties)
                return ok
            }
            if path == "/v1/mailbox", r.method == "GET" {
                if let code = collectRefusal { return .json(403, #"{"code":"\#(code)","message":""}"#) }
                guard serve else { return .json(404, #"{"code":"not_found","message":""}"#) }
                guard !queued.isEmpty else { return .json(200, #"{"messages":[]}"#) }
                let m = queued.removeFirst()
                let msg = JsonBuilder().string("msg_id", m.msgID).string("sender", m.sender).base64("payload", m.payload).build()
                return .json(200, #"{"messages":[\#(msg)]}"#)
            }
            if let b = claimAnswer(r) ?? blobAnswer(r) { return b }
            if path.hasPrefix("/v1/mailbox/"), r.method == "DELETE" {
                acked.append(String(path.dropFirst("/v1/mailbox/".count)))
                return .empty(204)
            }
            return .json(404, #"{"code":"not_found","message":""}"#)
        }
    }

    /// The refusal of a deposit, when one is set (the next ``refuseOnly`` of them, or all). Callers hold ``lock``.
    private func depositRefusal() -> FakeHTTPServer.Answer? {
        guard let code = refuse else { return nil }
        let answerStatus = status
        refused += 1
        if refuseCount > 0 {
            refuseCount -= 1
            if refuseCount == 0 {
                refuse = nil
                if let f = followUp { (refuse, status) = (f.code, f.status) }
            }
        }
        return .json(answerStatus, #"{"code":"\#(code)","message":""}"#)
    }

    /// `GET /v1/claim/{id}` (fetched once, then `claim_unknown`); nil for any other path. Callers hold ``lock``.
    private func claimAnswer(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer? {
        guard r.path.hasPrefix("/v1/claim/"), r.method == "GET" else { return nil }
        guard let c = claims.removeValue(forKey: String(r.path.dropFirst("/v1/claim/".count))) else {
            return .json(404, #"{"code":"claim_unknown","message":""}"#)
        }
        return .bytes(200, c)
    }

    /// `PUT /v1/blob/{mailbox}`, `GET` and `DELETE /v1/blob/{id}`; nil for any other path. Callers hold ``lock``.
    private func blobAnswer(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer? {
        guard r.path.hasPrefix("/v1/blob/") else { return nil }
        let rest = String(r.path.dropFirst("/v1/blob/".count))
        switch r.method {
        case "PUT":
            if let code = blobRefusal { return .json(409, #"{"code":"\#(code)","message":"","quota":"mailbox_blobs"}"#) }
            let id = Ulid.new()
            blobs[id] = (rest, r.body)
            return .json(201, #"{"blob_id":"\#(id)","expires_at":"2026-10-28T00:00:00Z"}"#)
        case "GET":
            guard let b = blobs[rest] else { return .json(404, #"{"code":"blob_unknown","message":""}"#) }
            return .bytes(200, b.bytes)
        default:
            blobs[rest] = nil
            return .json(200, "{}")
        }
    }

    /// The next deposit, waiting up to [timeout] seconds.
    func nextDeposit(timeout: TimeInterval = 10) async throws -> (mailbox: String, payload: [UInt8]) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let d = lock.withLock({ deposits.isEmpty ? nil : deposits.removeFirst() }) { return d }
            guard Date() < deadline else { throw VaultStateError(message: "no deposit") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Drops the deposits waiting, without waiting for more; returns their count.
    @discardableResult
    func dropDeposits() -> Int {
        lock.withLock {
            defer { deposits.removeAll() }
            return deposits.count
        }
    }

    func noDeposit(within: TimeInterval) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(within * 1e9))
        return lock.withLock { deposits.isEmpty }
    }

    func waitAcked(_ id: String, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ acked.contains(id) }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

/// A value shared with @Sendable closures.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T

    init(_ v: T) { self.v = v }

    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

/// The fake vault's keys and session with the device (the responder side of the handshake, epochs, tokens).
final class FakeVault: @unchecked Sendable {
    let ik = Ed25519PrivateKey.generate()
    let kem: KemPrivateKey
    let relayKey = Ed25519PrivateKey.generate()
    let relayURL: String
    let mailbox: String
    let vaultID = "0123456789abcdef0123456789abcdef"
    let keyring = Keyring()
    var responder: Responder?
    var sender: String { RelayAuth.encodeKey(relayKey.publicKey) }

    init(relayURL: String) throws {
        kem = try KemPrivateKey.generate()
        self.relayURL = relayURL
        mailbox = Mailbox.id(relayKey.publicKey)
    }

    var principal: Principal { Principal(ik: ik.publicKey, kem: kem.publicKey, relay: RelayAddr(url: relayURL, mailbox: mailbox, pk: relayKey.publicKey)) }

    /// The lifetime of the request token that `hs.resp` carries, when a test needs the short one of a pairing (§6.7).
    var requestTokenTTL: TimeInterval?

    func token(for d: VaultDevice) throws -> String {
        try DepositTokens.mintStanding(
            relayKey, sender: RelayAuth.encodeKey(d.relayAddr.pk), audience: d.relayAddr.url, now: Date(),
            ttl: requestTokenTTL ?? DepositTokens.standingTTL
        )
    }

    func msg(_ payload: [UInt8], from: String? = nil) -> RelayMessage {
        RelayMessage(msgID: Ulid.new(), depositedAt: "", sender: from ?? sender, jti: nil, payload: payload)
    }

    /// vault.enrolled (§11.3), sealed to the device's KEM key.
    func enrolled(_ d: VaultDevice) throws -> RelayMessage {
        let bundle = JsonBuilder().uint("v", 1).uint("suite", 2).string("ik", Base64s.encodeStd(ik.publicKey))
            .string("kem", Base64s.encodeStd(kem.publicKey.bytes))
            .raw("relay", JsonBuilder().string("url", relayURL).string("mailbox", mailbox).base64("pk", relayKey.publicKey).build()).bytes()
        let body = JsonBuilder().string("vault_id", vaultID).base64("vault_bundle", bundle).string("token", try token(for: d)).uint("state_seq", 2).bytes()
        let inner = Inner(id: Ulid.new(), type: "vault.enrolled", ts: Date(), body: body)
        return msg(try Envelope.sealSealed(d.kemKey, senderKid: Kid.anonymous, padded: try Inner.encode(inner, .sealed)).0)
    }

    /// Answers the device's hs.init (purpose app).
    func respond(_ raw: [UInt8], _ d: VaultDevice, ctx: String? = nil) throws -> RelayMessage {
        try respondOpening(raw, d, ctx: ctx).message
    }

    /// ``respond(_:_:ctx:)`` with the opened `hs.init` body, for the checks of a transfer's.
    func respondOpening(_ raw: [UInt8], _ d: VaultDevice, ctx: String? = nil) throws -> (message: RelayMessage, body: HsInit) {
        let kem = kem
        let p = try PendingInit.open(raw, lookup: { k in k == kem.publicKey.kid ? kem : nil }, now: Date())
        #expect(p.body.purpose == .app && p.body.ctx == (ctx ?? vaultID))
        #expect(p.inner.features == ["hs_confirm"]) // §5.3, §10.8 (0.87.0): every message the device deposits
        let (r, env) = try p.respond(ResponderConfig(identity: ik, token: try token(for: d), policy: .vaultToDevice, collectSender: d.relayAddr.pk))
        responder = r
        return (msg(env), p.body)
    }

    func fin(_ raw: [UInt8], _ d: VaultDevice) throws {
        let fr = try #require(responder).handleFin(raw, collectSender: d.relayAddr.pk, now: Date())
        #expect(fr.inner.features == ["hs_confirm"])
        keyring.activate(fr.epoch, now: Date())
    }

    func seal(_ type: String, _ body: String, re: String? = nil, status: String? = nil, id: String = Ulid.new(), ts: Date = Date()) throws -> RelayMessage {
        msg(try #require(keyring.current()).seal(Inner(id: id, type: type, ts: ts, re: re, status: status, body: Array(body.utf8))))
    }

    func open(_ raw: [UInt8]) throws -> Inner { try keyring.open(try Envelope.parse(raw), now: Date()).inner }

    /// A vault-initiated rekey's initiator (§6.5).
    func rekey(_ d: VaultDevice) throws -> Initiator {
        try Initiator.create(InitiatorConfig(
            purpose: .rekey, ctx: "", identity: ik, staticKem: kem.publicKey, relay: principal.relay,
            responderIk: d.identityKey, responderEk: nil, responderRelayKey: d.relayAddr.pk, current: keyring.current(), policy: .vaultToDevice
        ))
    }
}

// swiftlint:enable line_length

extension FakeRelay {
    /// Takes the `device.features` the device deposits after each epoch it activates (VAULT-MESSAGING §10.2, 0.87.0) and
    /// checks it: this app's list, in the body and as the inner `features`.
    @discardableResult
    func takeFeatures(_ v: FakeVault) async throws -> Inner {
        let m = try v.open(try await nextDeposit().payload)
        #expect(m.type == "device.features")
        #expect(String(bytes: m.body, encoding: .utf8) == #"{"features":["hs_confirm"]}"#)
        #expect(m.features == ["hs_confirm"])
        return m
    }
}
