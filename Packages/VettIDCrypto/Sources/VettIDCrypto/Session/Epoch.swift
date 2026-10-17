import Foundation

/// This side's role in the handshake that created an epoch.
public enum Role: Int, Sendable {
    case initiator = 1
    case responder = 2
}

/// Epoch limits (§6.5): rekey after [maxAge] or [maxMessages] in either direction (0: no bound).
public struct Policy: Equatable, Sendable {
    public let maxAge: TimeInterval
    public let maxMessages: UInt64

    public init(maxAge: TimeInterval, maxMessages: UInt64 = 0) {
        self.maxAge = maxAge
        self.maxMessages = maxMessages
    }

    /// Vault ↔ vault: 24 h or 10,000 messages.
    public static let vaultToVault = Policy(maxAge: 24 * 3600, maxMessages: 10_000)
    /// Vault ↔ device: 7 days (and on every unlock, which the runtime triggers).
    public static let vaultToDevice = Policy(maxAge: 7 * 86_400)
}

/// Whole milliseconds since the epoch, as the persistent forms store times.
private func epochMillis(_ d: Date) -> UInt64 { UInt64(max(0, (d.timeIntervalSince1970 * 1000).rounded(.down))) }

/// One session epoch (§6.3, §6.5): a send and a receive direction with their keys and kids, plus the rekey secret
/// `rk`. Direction i2r uses k_i2r with recipient_kid = kid_i2r and sender_kid = kid_r2i; r2i mirrors it. Thread-safe;
/// secret. Mirrors vettid-android `Epoch`.
public final class Epoch: @unchecked Sendable, CustomStringConvertible {
    public let id: [UInt8]
    public let role: Role
    public let suite: Int
    public let policy: Policy
    public let created: Date
    /// The recipient_kid that messages to this side carry.
    public let recvKid: Kid
    private let sendSenderKid: Kid
    private let sendRecipientKid: Kid
    private let recvSenderKid: Kid
    private let lock = NSLock()
    private var sendKey: [UInt8]?
    private var recvKey: [UInt8]?
    private var rk: [UInt8]?
    private var lastSeq: UInt64
    private var sent: UInt64
    private var received: UInt64

    /// How long receive keys of previous epochs are kept (§6.5).
    public static let receiveKeyRetention: TimeInterval = 16 * 86_400

    private init(
        id: [UInt8], role: Role, suite: Int, policy: Policy, created: Date,
        sendKey: [UInt8]?, sendSenderKid: Kid, sendRecipientKid: Kid,
        recvKey: [UInt8]?, recvKid: Kid, recvSenderKid: Kid,
        rk: [UInt8]?, lastSeq: UInt64, sent: UInt64, received: UInt64
    ) {
        self.id = id
        self.role = role
        self.suite = suite
        self.policy = policy
        self.created = created
        self.sendKey = sendKey
        self.sendSenderKid = sendSenderKid
        self.sendRecipientKid = sendRecipientKid
        self.recvKey = recvKey
        self.recvKid = recvKid
        self.recvSenderKid = recvSenderKid
        self.rk = rk
        self.lastSeq = lastSeq
        self.sent = sent
        self.received = received
    }

    deinit { destroy() }

    /// Standard base64 of the epoch id: hs.init `ctx` for rekey and reconnect.
    public var ctx: String { Base64s.encodeStd(id) }

    public func counts() -> (sent: UInt64, received: UInt64) { lock.withLock { (sent, received) } }

    /// Whether the epoch reached its limit; the side that hits it initiates the rekey (§6.5).
    public func needsRekey(now: Date) -> Bool {
        lock.withLock {
            if policy.maxAge > 0, now.timeIntervalSince(created) >= policy.maxAge { return true }
            let m = policy.maxMessages
            return m > 0 && (sent >= m || received >= m)
        }
    }

    public func canSend() -> Bool { lock.withLock { sendKey != nil } }

    /// A copy of rk, the K_s of the next rekey.
    func rkCopy() throws -> [UInt8] {
        try lock.withLock {
            guard let rk else { throw CryptoError.protocolViolation("epoch retired") }
            return rk
        }
    }

    /// Seals [inner] in session mode, assigning `seq` (per epoch and direction, from 1). The same id may be sealed
    /// again for a retransmission; every call yields a new envelope with a fresh nonce.
    public func seal(_ inner: Inner) throws -> [UInt8] {
        try lock.withLock {
            guard let key = sendKey else { throw CryptoError.protocolViolation("epoch retired") }
            var padded = try Inner.encode(inner.withSeq(lastSeq + 1), .session)
            defer { Bytes.wipe(&padded) }
            let env = try Envelope.sealSession(key: key, senderKid: sendSenderKid, recipientKid: sendRecipientKid, padded: padded)
            lastSeq += 1
            sent += 1
            return env
        }
    }

    /// Opens a session-mode envelope addressed to this epoch: both kids must be this epoch's receive kids, the AEAD
    /// must verify and the inner must parse.
    public func open(_ env: Envelope) throws -> Inner {
        try lock.withLock {
            guard env.mode == .session else { throw CryptoError.protocolViolation("wrong mode") }
            guard let key = recvKey else { throw CryptoError.protocolViolation("epoch retired") }
            guard env.recipientKid == recvKid, env.senderKid == recvSenderKid else { throw CryptoError.protocolViolation("kid") }
            var padded = try Envelope.openSession(env, key: key)
            defer { Bytes.wipe(&padded) }
            let inner = try Inner.decode(padded, .session)
            received += 1
            return inner
        }
    }

    /// Deletes the send key and rk when a newer epoch activates (§6.5).
    func retireSend() {
        lock.withLock {
            if var k = sendKey { Bytes.wipe(&k) }
            if var r = rk { Bytes.wipe(&r) }
            sendKey = nil
            rk = nil
        }
    }

    public func destroy() {
        lock.withLock {
            if var k = sendKey { Bytes.wipe(&k) }
            if var k = recvKey { Bytes.wipe(&k) }
            if var r = rk { Bytes.wipe(&r) }
            sendKey = nil
            recvKey = nil
            rk = nil
        }
    }

    /// The persistent form (device storage, encrypted under a device key). Contains secrets.
    public func export() throws -> [UInt8] {
        try lock.withLock {
            let b = JsonBuilder()
                .base64("id", id)
                .uint("role", UInt64(role.rawValue))
                .uint("suite", UInt64(suite))
                .uint("max_age_s", UInt64(policy.maxAge))
                .uint("max_messages", policy.maxMessages)
                .uint("created_ms", epochMillis(created))
            if let sendKey { b.base64("send_key", sendKey) }
            guard let recvKey else { throw CryptoError.protocolViolation("epoch destroyed") }
            b.base64("send_sender_kid", sendSenderKid.bytes)
                .base64("send_recipient_kid", sendRecipientKid.bytes)
                .base64("recv_key", recvKey)
                .base64("recv_kid", recvKid.bytes)
                .base64("recv_sender_kid", recvSenderKid.bytes)
            if let rk { b.base64("rk", rk) }
            return b.uint("last_seq", lastSeq).uint("sent", sent).uint("received", received).bytes()
        }
    }

    public var description: String { "Epoch[redacted]" }

    static func from(_ s: Schedule, role: Role, suite: Int, policy: Policy, now: Date) -> Epoch {
        let ini = role == .initiator
        // Initiator: sends i2r (recipient kid_i2r, sender kid_r2i), receives r2i; the responder mirrors it.
        return Epoch(
            id: s.epochID, role: role, suite: suite, policy: policy, created: now,
            sendKey: ini ? s.kI2R : s.kR2I,
            sendSenderKid: ini ? s.kidR2I : s.kidI2R,
            sendRecipientKid: ini ? s.kidI2R : s.kidR2I,
            recvKey: ini ? s.kR2I : s.kI2R,
            recvKid: ini ? s.kidR2I : s.kidI2R,
            recvSenderKid: ini ? s.kidI2R : s.kidR2I,
            rk: s.rk, lastSeq: 0, sent: 0, received: 0
        )
    }

    /// Restores an epoch from ``export()``.
    public static func `import`(_ state: [UInt8]) throws -> Epoch {
        let o = try StrictJson.parseObject(state)
        let role: Role = try o.uint("role", min: 1, max: 2) == 1 ? .initiator : .responder
        let suite = Int(try o.uint("suite", min: 0, max: 255))
        try Suite.check(suite, pinned: 0)
        let max = StrictJson.maxSafeInteger
        return Epoch(
            id: try o.base64("id", Suite.epochIDSize),
            role: role,
            suite: suite,
            policy: Policy(
                maxAge: TimeInterval(try o.uint("max_age_s", min: 0, max: max)),
                maxMessages: try o.uint("max_messages", min: 0, max: max)
            ),
            created: Date(timeIntervalSince1970: Double(try o.uint("created_ms", min: 0, max: max)) / 1000),
            sendKey: o.has("send_key") ? try o.base64("send_key", Suite.keySize) : nil,
            sendSenderKid: try Kid(try o.base64("send_sender_kid", Suite.kidSize)),
            sendRecipientKid: try Kid(try o.base64("send_recipient_kid", Suite.kidSize)),
            recvKey: try o.base64("recv_key", Suite.keySize),
            recvKid: try Kid(try o.base64("recv_kid", Suite.kidSize)),
            recvSenderKid: try Kid(try o.base64("recv_sender_kid", Suite.kidSize)),
            rk: o.has("rk") ? try o.base64("rk", Suite.keySize) : nil,
            lastSeq: try o.uint("last_seq", min: 0, max: max),
            sent: try o.uint("sent", min: 0, max: max),
            received: try o.uint("received", min: 0, max: max)
        )
    }

    /// §6.5: of two crossing rekey hs.inits the one with the lower th1 (big-endian) wins.
    public static func ourRekeyWins(_ ourTh1: [UInt8], _ theirTh1: [UInt8]) -> Bool {
        for (a, b) in zip(ourTh1, theirTh1) where a != b {
            return a < b
        }
        return ourTh1.count < theirTh1.count
    }
}

/// A session's current epoch plus the receive keys of previous epochs, kept for ``Epoch/receiveKeyRetention``.
/// Thread-safe. Mirrors vettid-android `Keyring`.
public final class Keyring: @unchecked Sendable {
    private let lock = NSLock()
    private var currentEpoch: Epoch?
    private var retired: [(epoch: Epoch, until: Date)] = []

    public init() {}

    /// Makes [e] current; the previous epoch's send key and rk are deleted at once.
    public func activate(_ e: Epoch, now: Date) {
        lock.withLock {
            if let c = currentEpoch {
                c.retireSend()
                retired.append((c, now.addingTimeInterval(Epoch.receiveKeyRetention)))
            }
            currentEpoch = e
            pruneLocked(now)
        }
    }

    public func current() -> Epoch? { lock.withLock { currentEpoch } }

    public func prune(now: Date) { lock.withLock { pruneLocked(now) } }

    private func pruneLocked(_ now: Date) {
        retired.removeAll { r in
            guard now > r.until else { return false }
            r.epoch.destroy()
            return true
        }
    }

    /// Routes a session envelope by recipient_kid to the current or a retained epoch and opens it there; no other
    /// epoch is tried (§4.4). Every candidate is compared, so the lookup does not reveal which one matched.
    public func open(_ env: Envelope, now: Date) throws -> (inner: Inner, epoch: Epoch) {
        let found: Epoch? = lock.withLock {
            var found: Epoch?
            if let c = currentEpoch, env.recipientKid == c.recvKid { found = c }
            for r in retired where now <= r.until && env.recipientKid == r.epoch.recvKid && found == nil {
                found = r.epoch
            }
            return found
        }
        guard let e = found else { throw CryptoError.protocolViolation("kid") }
        return (try e.open(env), e)
    }

    public func destroy() {
        lock.withLock {
            currentEpoch?.destroy()
            currentEpoch = nil
            retired.forEach { $0.epoch.destroy() }
            retired.removeAll()
        }
    }

    /// The persistent form: the current epoch and the retained receive keys of previous epochs with their expiry
    /// (device storage, encrypted under a device key). Contains secrets.
    public func export() throws -> [UInt8] {
        try lock.withLock {
            let b = JsonBuilder()
            if let c = currentEpoch { b.raw("current", try c.export()) }
            let r = try retired.map { JsonBuilder().uint("until_ms", epochMillis($0.until)).raw("epoch", try $0.epoch.export()).build() }
            b.raw("retired", JsonBuilder.array(r))
            return b.bytes()
        }
    }

    /// Restores a keyring from ``export()``.
    public static func `import`(_ state: [UInt8]) throws -> Keyring {
        let o = try StrictJson.parseObject(state)
        let k = Keyring()
        if let c = try o.optObj("current") { k.currentEpoch = try Epoch.import(Array(c.raw.utf8)) }
        for r in try o.array("retired") {
            let ro = try r.asObject()
            let e = try Epoch.import(Array(try ro.obj("epoch").raw.utf8))
            let until = Date(timeIntervalSince1970: Double(try ro.uint("until_ms", min: 0, max: StrictJson.maxSafeInteger)) / 1000)
            k.retired.append((e, until))
        }
        return k
    }
}
