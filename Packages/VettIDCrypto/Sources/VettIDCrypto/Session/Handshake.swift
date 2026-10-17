import Foundation

/// Configuration of an hs.init (§6.1, §6.2). Mirrors vettid-android `InitiatorConfig`.
public struct InitiatorConfig {
    public let purpose: Purpose
    /// Invite id, pairing id, vault_id (first app), or empty for rekey (set from [current]).
    public let ctx: String
    public let identity: Ed25519PrivateKey
    /// from.kem: the initiator's static ek.
    public let staticKem: KemPublicKey
    public let relay: RelayAddr
    public let token: String?
    public let reconnectToken: String?
    public let suites: [Int]
    public let profile: [UInt8]?
    public let rotations: [Rotation]
    public let deviceAttest: DeviceAttest?
    /// A transfer's app key (§6.2, 0.15.0): SPKI DER, only with purpose app.
    public let apiKey: [UInt8]?
    /// (0.33.0, release R) A transfer's unlock secret (§6.2, §11.14.10): 32 bytes, only with [apiKey].
    public let unlockSecret: [UInt8]?
    /// hs.init sender_kid all-zero instead of kid(staticKem).
    public let anonymousSender: Bool
    /// The pinned ik_R (or the stored ik for rekey/reconnect).
    public let responderIk: [UInt8]
    /// ek_R; not used for rekey.
    public let responderEk: KemPublicKey?
    /// R's relay key on record: the expected collect sender of hs.resp.
    public let responderRelayKey: [UInt8]
    /// Rekey only: the epoch hs.init travels in; K_s = its rk.
    public let current: Epoch?
    public let pinnedSuite: Int
    public let policy: Policy
    /// Inner ids and time; generated when nil.
    public let id: String?
    public let finID: String?
    public let now: Date?

    public init(
        purpose: Purpose,
        ctx: String,
        identity: Ed25519PrivateKey,
        staticKem: KemPublicKey,
        relay: RelayAddr,
        token: String? = nil,
        reconnectToken: String? = nil,
        suites: [Int] = [Suite.suite2],
        profile: [UInt8]? = nil,
        rotations: [Rotation] = [],
        deviceAttest: DeviceAttest? = nil,
        apiKey: [UInt8]? = nil,
        unlockSecret: [UInt8]? = nil,
        anonymousSender: Bool = false,
        responderIk: [UInt8],
        responderEk: KemPublicKey?,
        responderRelayKey: [UInt8],
        current: Epoch? = nil,
        pinnedSuite: Int = 0,
        policy: Policy,
        id: String? = nil,
        finID: String? = nil,
        now: Date? = nil
    ) {
        self.purpose = purpose
        self.ctx = ctx
        self.identity = identity
        self.staticKem = staticKem
        self.relay = relay
        self.token = token
        self.reconnectToken = reconnectToken
        self.suites = suites
        self.profile = profile
        self.rotations = rotations
        self.deviceAttest = deviceAttest
        self.apiKey = apiKey
        self.unlockSecret = unlockSecret
        self.anonymousSender = anonymousSender
        self.responderIk = responderIk
        self.responderEk = responderEk
        self.responderRelayKey = responderRelayKey
        self.current = current
        self.pinnedSuite = pinnedSuite
        self.policy = policy
        self.id = id
        self.finID = finID
        self.now = now
    }
}

/// The initiator's result: the active epoch and hs.fin to deposit. Mirrors vettid-android `InitiatorResult`.
public struct InitiatorResult {
    public let epoch: Epoch
    public let fin: [UInt8]
    public let resp: HsResp
    /// The key sig_R verified under (pinned, or the end of a reconnect's chain). Store it.
    public let responderIk: [UInt8]
    /// The KEM key the last rotation announced, if any.
    public let responderKem: KemPublicKey?
    public let inner: Inner
    /// The short authentication string for a purpose with a SAS (§6.3, 0.10.3), nil otherwise. It exists only now,
    /// after sig_R verified; hs.fin reveals n_I.
    public let sas: String?
}

/// The initiator side of one handshake. ``create(_:)`` builds and seals hs.init with a fresh ephemeral KEM key and, for
/// a purpose with a SAS, commits to the nonce n_I (0.10.3); ``handleResp(_:collectSender:now:)`` verifies hs.resp
/// (sig_R before any epoch key is used) and returns the new epoch, the SAS and hs.fin, which reveals n_I. One hs.resp
/// per hs.init (§6.3): after it the state is gone. Mirrors vettid-android `Initiator`.
public final class Initiator: @unchecked Sendable {
    private let cfg: InitiatorConfig
    public let body: HsInit
    private let env: [UInt8]
    public let th1: [UInt8]
    private let lock = NSLock()
    private var eph: KemPrivateKey?
    private var ks: [UInt8]?
    private var nI: [UInt8]?
    private var done = false

    private init(cfg: InitiatorConfig, body: HsInit, eph: KemPrivateKey, env: [UInt8], ks: [UInt8], nI: [UInt8]?) {
        self.cfg = cfg
        self.body = body
        self.eph = eph
        self.env = env
        self.ks = ks
        self.nI = nI
        th1 = Schedule.th1(env)
    }

    /// hs.init, ready to deposit.
    public var envelope: [UInt8] { env }

    /// The kid hs.resp carries as recipient_kid.
    public var ephKid: Kid { body.eph.kid }

    public func abort() { lock.withLock { abortLocked() } }

    private func abortLocked() {
        done = true
        eph?.destroy()
        eph = nil
        if var k = ks { Bytes.wipe(&k) }
        if var n = nI { Bytes.wipe(&n) }
        ks = nil
        nI = nil
    }

    /// Processes hs.resp. [collectSender] is the relay `sender` of the deposit. A message that does not decrypt under
    /// eph leaves the handshake pending; once one has decrypted, any failure aborts it (§6.3 "MUST abort").
    public func handleResp(_ raw: [UInt8], collectSender: [UInt8], now: Date) throws -> InitiatorResult {
        try lock.withLock {
            if done { throw CryptoError.used("handshake") }
            guard Ed25519.equalPublic(collectSender, cfg.responderRelayKey) else { throw CryptoError.protocolViolation("relay sender") }
            let e = try Envelope.parse(raw)
            guard e.mode == .sealed else { throw CryptoError.protocolViolation("wrong mode") }
            guard e.senderKid.isAnonymous else { throw CryptoError.protocolViolation("sender kid") }
            guard let eph else { throw CryptoError.used("handshake") }
            var (padded, exporter) = try Envelope.openSealed(e, key: eph)
            defer {
                Bytes.wipe(&padded)
                abortLocked() // success or failure after decryption both end the state
            }
            var ke = try exporter.export(Labels.hsKE, Suite.keySize)
            defer { Bytes.wipe(&ke) }
            return try complete(e, padded: padded, ke: ke, now: now)
        }
    }

    private func complete(_ e: Envelope, padded: [UInt8], ke: [UInt8], now: Date) throws -> InitiatorResult {
        let inner = try Inner.decode(padded, .sealed)
        guard inner.type == HsTypes.resp else { throw CryptoError.protocolViolation("type") }
        try inner.checkTime(now: now, durable: true)
        let resp = try HsResp.parse(inner.body, cfg.purpose)
        try Suite.checkChosen(resp.suite, offered: cfg.suites, pinned: cfg.pinnedSuite)
        var verifyIk = cfg.responderIk
        var newKem: KemPublicKey?
        if cfg.purpose == .reconnect {
            (verifyIk, newKem) = try Rotation.resolveChain(cfg.responderIk, resp.rotations)
        }
        guard let ks else { throw CryptoError.used("handshake") }
        let th = Schedule.th(env, e.header)
        let sched = try Schedule.derive(ks: ks, ke: ke, th1: th1, th: th)
        defer { sched.destroy() }
        // §6.3: I MUST verify sig_R before using any epoch key.
        guard Schedule.verifyResp(verifyIk, th: th, sig: resp.sig) else { throw CryptoError.signature("sig_R") }
        var sas: String?
        if cfg.purpose.hasSas {
            guard let nI, let nR = resp.sasNonce else { throw CryptoError.format("sas_nonce") }
            sas = try Schedule.sas(prk: sched.prk, th: th, nI: nI, nR: nR)
        }
        let epoch = Epoch.from(sched, role: .initiator, suite: resp.suite, policy: cfg.policy, now: now)
        let fin = try epoch.seal(
            Inner(
                id: cfg.finID ?? Ulid.new(now),
                type: HsTypes.fin,
                ts: now,
                body: try HsFin(sig: try Schedule.signFin(cfg.identity, th: th), sasNonce: nI).marshal(cfg.purpose)
            )
        )
        return InitiatorResult(epoch: epoch, fin: fin, resp: resp, responderIk: verifyIk, responderKem: newKem, inner: inner, sas: sas)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func create(_ cfg: InitiatorConfig) throws -> Initiator {
        guard cfg.responderIk.count == Suite.ed25519PublicSize, cfg.responderRelayKey.count == Suite.ed25519PublicSize else {
            throw CryptoError.protocolViolation("config")
        }
        let rekey = cfg.purpose == .rekey
        var ctx = cfg.ctx
        if rekey {
            guard let cur = cfg.current else { throw CryptoError.protocolViolation("config") }
            if ctx.isEmpty {
                ctx = cur.ctx
            } else if ctx != cur.ctx {
                throw CryptoError.protocolViolation("ctx")
            }
        } else if cfg.responderEk == nil || cfg.current != nil {
            throw CryptoError.protocolViolation("config")
        }
        let now = cfg.now ?? Date()
        let id = cfg.id ?? Ulid.new(now)
        let eph = try KemPrivateKey.generate()
        // n_I is fixed before hs.init is built (§6.2), after the ephemeral key (§16's order of draws).
        var nI = cfg.purpose.hasSas ? Randomness.bytes(HsLimits.sasNonceSize) : nil
        do {
            let body = HsInit(
                purpose: cfg.purpose,
                ctx: ctx,
                from: Principal(ik: cfg.identity.publicKey, kem: cfg.staticKem, relay: cfg.relay),
                eph: eph.publicKey,
                token: cfg.token,
                reconnectToken: cfg.reconnectToken,
                suites: cfg.suites,
                profile: cfg.profile,
                rotations: cfg.rotations,
                deviceAttest: cfg.deviceAttest,
                apiKey: cfg.apiKey,
                sasCommit: nI.map(Schedule.sasCommit),
                unlockSecret: cfg.unlockSecret
            )
            var bodyBytes = try body.marshal()
            // (Release R) A transfer's unlock secret: the message's copy and the marshalled body are zeroed once sealed.
            body.wipeUnlockSecret()
            defer { if cfg.unlockSecret != nil { Bytes.wipe(&bodyBytes) } }
            let inner = Inner(id: id, type: HsTypes.initType, ts: now, body: bodyBytes)
            if rekey {
                // §6.2: a rekey hs.init travels in session mode under the current epoch, and K_s is that epoch's rk.
                guard let cur = cfg.current else { throw CryptoError.protocolViolation("config") }
                let ks = try cur.rkCopy()
                return Initiator(cfg: cfg, body: body, eph: eph, env: try cur.seal(inner), ks: ks, nI: nI)
            }
            guard let responderEk = cfg.responderEk else { throw CryptoError.protocolViolation("config") }
            var padded = try Inner.encode(inner, .sealed)
            defer { Bytes.wipe(&padded) }
            let senderKid = cfg.anonymousSender ? Kid.anonymous : cfg.staticKem.kid
            let sealer = try Sealer(responderEk, senderKid: senderKid)
            let env = try sealer.seal(padded)
            return Initiator(cfg: cfg, body: body, eph: eph, env: env, ks: try sealer.export(Labels.hsKS, Suite.keySize), nI: nI)
        } catch {
            eph.destroy()
            if nI != nil { Bytes.wipe(&nI!) }
            throw error
        }
    }
}

/// Looks up the one static KEM key (current or retired) whose kid is the given one, or nil (§4.4).
public typealias KeyLookup = (Kid) -> KemPrivateKey?

/// Configuration of hs.resp. Since 0.10.3 ``PendingInit/respond(_:)`` is not the approval: where approval is needed
/// hs.resp carries only a request token (§6.4, §6.7, §7.1), and the epoch is activated at approval. Mirrors
/// vettid-android `ResponderConfig`.
public struct ResponderConfig {
    public let identity: Ed25519PrivateKey
    public let token: String?
    public let reconnectToken: String?
    public let rotations: [Rotation]
    public let pinnedSuite: Int
    public let policy: Policy
    /// The relay `sender` of the hs.init deposit; MUST equal from.relay.pk.
    public let collectSender: [UInt8]
    /// Relay key on record (rekey, reconnect).
    public let recordRelayKey: [UInt8]?
    /// Stored ik of the peer (rekey, reconnect).
    public let knownInitiatorIk: [UInt8]?
    /// If set, must equal hs.init ctx (required for reconnect).
    public let expectedCtx: String?
    public let id: String?
    public let now: Date?

    public init(
        identity: Ed25519PrivateKey,
        token: String? = nil,
        reconnectToken: String? = nil,
        rotations: [Rotation] = [],
        pinnedSuite: Int = 0,
        policy: Policy,
        collectSender: [UInt8],
        recordRelayKey: [UInt8]? = nil,
        knownInitiatorIk: [UInt8]? = nil,
        expectedCtx: String? = nil,
        id: String? = nil,
        now: Date? = nil
    ) {
        self.identity = identity
        self.token = token
        self.reconnectToken = reconnectToken
        self.rotations = rotations
        self.pinnedSuite = pinnedSuite
        self.policy = policy
        self.collectSender = collectSender
        self.recordRelayKey = recordRelayKey
        self.knownInitiatorIk = knownInitiatorIk
        self.expectedCtx = expectedCtx
        self.id = id
        self.now = now
    }
}

/// A decrypted, validated hs.init awaiting the responder's decision. Mirrors vettid-android `PendingInit`.
public final class PendingInit: @unchecked Sendable {
    private let env: [UInt8]
    public let inner: Inner
    public let body: HsInit
    public let th1: [UInt8]
    private let lock = NSLock()
    private var ks: [UInt8]?
    private var used = false

    private init(env: [UInt8], inner: Inner, body: HsInit, ks: [UInt8]) {
        self.env = env
        self.inner = inner
        self.body = body
        self.ks = ks
        th1 = Schedule.th1(env)
    }

    public func discard() { lock.withLock { discardLocked() } }

    private func discardLocked() {
        used = true
        if var k = ks { Bytes.wipe(&k) }
        ks = nil
    }

    /// Builds hs.resp sealed to the initiator's ephemeral key, with sig_R over th.
    public func respond(_ cfg: ResponderConfig) throws -> (Responder, [UInt8]) {
        try lock.withLock {
            if used { throw CryptoError.used("handshake") }
            guard let ks else { throw CryptoError.used("handshake") }
            let verifyIk = try checkInitiator(cfg)
            let chosen = try Suite.negotiate(body.suites, pinned: cfg.pinnedSuite)
            // n_R is chosen only now, after hs.init has been opened (§6.2), before the hs.resp encapsulation (§16).
            let nR = body.purpose.hasSas ? Randomness.bytes(HsLimits.sasNonceSize) : nil
            let now = cfg.now ?? Date()
            let sealer = try Sealer(body.eph, senderKid: Kid.anonymous)
            var ke = try sealer.export(Labels.hsKE, Suite.keySize)
            let th = Schedule.th(env, sealer.header)
            let sched: Schedule
            do {
                defer { Bytes.wipe(&ke) }
                sched = try Schedule.derive(ks: ks, ke: ke, th1: th1, th: th)
            }
            do {
                let resp = HsResp(
                    token: cfg.token, reconnectToken: cfg.reconnectToken, suite: chosen, rotations: cfg.rotations,
                    sig: try Schedule.signResp(cfg.identity, th: th), sasNonce: nR
                )
                let inner = Inner(id: cfg.id ?? Ulid.new(now), type: HsTypes.resp, ts: now, body: try resp.marshal(body.purpose))
                var padded = try Inner.encode(inner, .sealed)
                defer { Bytes.wipe(&padded) }
                let out = try sealer.seal(padded)
                discardLocked()
                let responder = Responder(
                    sched: sched, verifyIk: verifyIk, sender: body.from.relay.pk, suite: chosen, policy: cfg.policy,
                    purpose: body.purpose, commit: body.sasCommit, nR: nR
                )
                return (responder, out)
            } catch {
                sched.destroy()
                throw error
            }
        }
    }

    /// §6.3 and §6.6: returns the key sig_I must verify under. One branch per rule of the spec.
    private func checkInitiator(_ cfg: ResponderConfig) throws -> [UInt8] { // swiftlint:disable:this cyclomatic_complexity
        let from = body.from
        guard Ed25519.equalPublic(cfg.collectSender, from.relay.pk) else { throw CryptoError.protocolViolation("relay sender") }
        if let expected = cfg.expectedCtx, expected != body.ctx { throw CryptoError.protocolViolation("ctx") }
        switch body.purpose {
        case .rekey:
            guard Ed25519.equalPublic(cfg.collectSender, cfg.recordRelayKey) else { throw CryptoError.protocolViolation("relay sender") }
            guard Ed25519.equalPublic(from.ik, cfg.knownInitiatorIk) else { throw CryptoError.protocolViolation("identity") }
        case .reconnect:
            guard cfg.expectedCtx != nil else { throw CryptoError.protocolViolation("config") }
            guard Ed25519.equalPublic(cfg.collectSender, cfg.recordRelayKey) else { throw CryptoError.protocolViolation("relay sender") }
            guard let known = cfg.knownInitiatorIk else { throw CryptoError.protocolViolation("config") }
            let (finalIk, kem) = try Rotation.resolveChain(known, body.rotations)
            guard Ed25519.equalPublic(finalIk, from.ik) else { throw CryptoError.protocolViolation("identity") }
            if let kem, kem != from.kem { throw CryptoError.protocolViolation("identity") }
        default:
            break // A new peer or device: trust on first use, under approval and SAS.
        }
        return from.ik
    }

    /// Decrypts a sealed-mode hs.init (every purpose except rekey).
    public static func open(_ raw: [UInt8], lookup: KeyLookup, now: Date) throws -> PendingInit {
        let e = try Envelope.parse(raw)
        guard e.mode == .sealed else { throw CryptoError.protocolViolation("wrong mode") }
        guard let sk = lookup(e.recipientKid) else { throw CryptoError.protocolViolation("no key for kid") }
        var (padded, exporter) = try Envelope.openSealed(e, key: sk)
        defer { Bytes.wipe(&padded) }
        let inner = try Inner.decode(padded, .sealed)
        guard inner.type == HsTypes.initType else { throw CryptoError.protocolViolation("type") }
        try inner.checkTime(now: now, durable: true)
        let body = try HsInit.parse(inner.body)
        guard body.purpose != .rekey else { throw CryptoError.protocolViolation("purpose") }
        guard e.senderKid.isAnonymous || e.senderKid == body.from.kem.kid else { throw CryptoError.protocolViolation("sender kid") }
        return PendingInit(env: raw, inner: inner, body: body, ks: try exporter.export(Labels.hsKS, Suite.keySize))
    }

    /// Decrypts a session-mode rekey hs.init under the current epoch; K_s = its rk (§6.2).
    public static func openRekey(_ raw: [UInt8], current: Epoch, now: Date) throws -> PendingInit {
        let e = try Envelope.parse(raw)
        guard e.mode == .session else { throw CryptoError.protocolViolation("wrong mode") }
        let inner = try current.open(e)
        guard inner.type == HsTypes.initType else { throw CryptoError.protocolViolation("type") }
        try inner.checkTime(now: now, durable: true)
        let body = try HsInit.parse(inner.body)
        guard body.purpose == .rekey else { throw CryptoError.protocolViolation("purpose") }
        guard body.ctx == current.ctx else { throw CryptoError.protocolViolation("ctx") }
        return PendingInit(env: raw, inner: inner, body: body, ks: try current.rkCopy())
    }
}

/// The outcome of a valid hs.fin on the responder side (§6.3). Mirrors vettid-android `FinResult`.
public struct FinResult {
    /// The established epoch. It is active at once for rekeys, reconnects and handshakes answered without approval;
    /// otherwise the owner activates it at approval.
    public let epoch: Epoch
    public let inner: Inner
    /// The short authentication string for a purpose with a SAS (0.10.3), nil otherwise.
    public let sas: String?
}

/// The responder after hs.resp, awaiting hs.fin. Mirrors vettid-android `Responder`.
public final class Responder: @unchecked Sendable {
    private let sched: Schedule
    private let verifyIk: [UInt8]
    private let sender: [UInt8]
    private let suite: Int
    private let policy: Policy
    private let purpose: Purpose
    private let commit: [UInt8]?
    private let lock = NSLock()
    private var nR: [UInt8]?
    private var done = false

    init(
        sched: Schedule, verifyIk: [UInt8], sender: [UInt8], suite: Int, policy: Policy, purpose: Purpose, commit: [UInt8]?, nR: [UInt8]?
    ) {
        self.sched = sched
        self.verifyIk = verifyIk
        self.sender = sender
        self.suite = suite
        self.policy = policy
        self.purpose = purpose
        self.commit = commit
        self.nR = nR
    }

    /// (recipient_kid, sender_kid) that hs.fin carries, for routing.
    public var kids: (recipient: Kid, sender: Kid) { (sched.kidI2R, sched.kidR2I) }

    public func abort() { lock.withLock { abortLocked() } }

    private func abortLocked() {
        done = true
        sched.destroy()
        if var n = nR { Bytes.wipe(&n) }
        nR = nil
    }

    /// The persistent form, so that a restart between hs.resp and hs.fin does not lose the handshake (as the vault
    /// keeps `st.Awaiting`, vettid-vault `ResponderState`). Contains secrets: store it only where the session keys are
    /// stored (device storage, encrypted under a device key).
    public func export() throws -> [UInt8] {
        try lock.withLock {
            if done { throw CryptoError.used("handshake") }
            let b = sched.export(JsonBuilder())
                .base64("verify_ik", verifyIk)
                .base64("sender", sender)
                .uint("suite", UInt64(suite))
                .uint("max_age_s", UInt64(policy.maxAge))
                .uint("max_messages", policy.maxMessages)
                .string("purpose", purpose.rawValue)
            if let commit { b.base64("sas_commit", commit) }
            if let nR { b.base64("n_r", nR) }
            return b.bytes()
        }
    }

    /// Opens hs.fin with the pending epoch's i2r key, verifies sig_I and, for a purpose with a SAS, the commitment to
    /// n_I; only then is the epoch established (§6.3). A message that does not decrypt, is malformed or whose sig_I
    /// does not verify leaves the pending state as it is, so a forged message cannot cancel a genuine handshake. An
    /// hs.fin whose sig_I verifies but whose n_I does not open sas_commit can only come from the initiator: the
    /// handshake is aborted (``CryptoError/protocolViolation(_:)`` "sas_commit").
    public func handleFin(_ raw: [UInt8], collectSender: [UInt8], now: Date) throws -> FinResult {
        try lock.withLock {
            if done { throw CryptoError.used("handshake") }
            guard Ed25519.equalPublic(collectSender, sender) else { throw CryptoError.protocolViolation("relay sender") }
            let e = try Envelope.parse(raw)
            guard e.mode == .session else { throw CryptoError.protocolViolation("wrong mode") }
            let pending = Epoch.from(sched, role: .responder, suite: suite, policy: policy, now: now)
            do {
                let inner = try pending.open(e)
                // It opened under the pending epoch, so the initiator sent it after its hs.fin: keep it for later (§6.3).
                guard inner.type == HsTypes.fin else { throw CryptoError.early("hs.fin") }
                try inner.checkTime(now: now, durable: true)
                let fin = try HsFin.parse(inner.body, purpose)
                guard Schedule.verifyFin(verifyIk, th: sched.th, sig: fin.sig) else { throw CryptoError.signature("sig_I") }
                var sas: String?
                if purpose.hasSas {
                    guard let nI = fin.sasNonce, let commit, let nR else { throw CryptoError.format("sas_nonce") }
                    guard Schedule.checkSasCommit(commit, nI) else {
                        // Signed by the initiator: abort and destroy the state (§6.3).
                        abortLocked()
                        throw CryptoError.protocolViolation("sas_commit")
                    }
                    sas = try Schedule.sas(prk: sched.prk, th: sched.th, nI: nI, nR: nR)
                }
                done = true
                sched.destroy()
                return FinResult(epoch: pending, inner: inner, sas: sas)
            } catch {
                pending.destroy()
                throw error
            }
        }
    }

    /// Restores a responder from ``export()``.
    public static func `import`(_ state: [UInt8]) throws -> Responder {
        let o = try StrictJson.parseObject(state)
        let purpose = try Purpose.of(try o.string("purpose"))
        let commit = o.has("sas_commit") ? try o.base64("sas_commit", Suite.hashSize) : nil
        let nR = o.has("n_r") ? try o.base64("n_r", HsLimits.sasNonceSize) : nil
        if purpose.hasSas, commit == nil || nR == nil { throw CryptoError.format("responder state") }
        let suite = Int(try o.uint("suite", min: 0, max: 255))
        try Suite.check(suite, pinned: 0)
        let max = StrictJson.maxSafeInteger
        return Responder(
            sched: try schedule(o),
            verifyIk: try o.base64("verify_ik", Suite.ed25519PublicSize),
            sender: try o.base64("sender", Suite.ed25519PublicSize),
            suite: suite,
            policy: Policy(
                maxAge: TimeInterval(try o.uint("max_age_s", min: 0, max: max)),
                maxMessages: try o.uint("max_messages", min: 0, max: max)
            ),
            purpose: purpose,
            commit: commit,
            nR: nR
        )
    }

    /// The schedule from the fields of ``Schedule/export(_:)``.
    private static func schedule(_ o: JsonObject) throws -> Schedule {
        Schedule(
            th1: try o.base64("th1", Suite.hashSize),
            th: try o.base64("th", Suite.hashSize),
            prk: try o.base64("prk", Suite.keySize),
            kI2R: try o.base64("k_i2r", Suite.keySize),
            kR2I: try o.base64("k_r2i", Suite.keySize),
            kidI2R: try Kid(try o.base64("kid_i2r", Suite.kidSize)),
            kidR2I: try Kid(try o.base64("kid_r2i", Suite.kidSize)),
            rk: try o.base64("rk", Suite.keySize),
            epochID: try o.base64("epoch_id", Suite.epochIDSize)
        )
    }
}
