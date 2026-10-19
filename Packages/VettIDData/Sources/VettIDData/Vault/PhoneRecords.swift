import Foundation
import VettIDCrypto

/// The records of the iPhone's unlock secret (VAULT-MESSAGING §11.14.1 "On an iPhone", IOS-PLAN §6.3), kept as one file
/// of the encrypted file store. Each record names the exact phone key it needs (`key_id`, beside its `key_vault`):
///
/// - **current**: the record the app believes the vault holds;
/// - **pendings** (at most ``PhoneSecrets/maxPendings``, oldest first): epoch-1 records of enrollments, transfers'
///   `hs.init` or recoveries' registers whose success has not arrived; kept beside the others, which stay until one of
///   them is confirmed (chosen; not in the spec);
/// - **candidates** (at most four, oldest first): next-epoch records sent in a `pin.change` or `vault.secret.renew`
///   whose answer did not arrive, each with the operation that made it, so that a retry of that operation reuses it;
/// - **replaced** (oldest first): records a confirmed later one replaced, each with when its 7 days started (and the
///   operation that made it, if any, and whether only an unlock's `ok` put it there); deleted 7 days after that, or at a
///   wipe, with any key no kept record names;
/// - **unresolved** (at most one): a `pin.change` or `credential.password.change` sent and not yet decided
///   (VAULT-MESSAGING §11.14.9 "A lost answer"), written in the same atomic write as the PIN change's candidate;
/// - **uncertain PIN** (0.45.0 step 3): the operation of a PIN change whose check ended without a decision, while its
///   candidate is still a candidate; an unlock that confirms or replaces that candidate settles it.
///
/// Stored form (chosen; not in the spec): `{"v":1,"current":E,"pendings":[E],"candidates":[{"operation","exp"?,"sent_id"?,
/// "sent_version"?,E…}],
/// "replaced":[{"since","keep_ms"?,"operation"?,"by_unlock"?,E…}],"unresolved"?:U,"uncertain_pin"?:O}` where `E` is
/// `"key_id","record"`, `U` is ``UnresolvedChange``'s form, compact JSON, records in ``PhoneSecretRecord``'s form, `since`
/// and `exp` in Unix ms. A file without `unresolved` or `uncertain_pin` (written before they existed) has none, and a
/// candidate without `exp` has none. `keep_ms` is a replaced record's keep period when it is not the real 7 days
/// (STAGING-TIME-SCALE S9: divided by the vault's time scale when the 7 days start); without it, 7 days.
public struct PhoneRecords: Equatable, Sendable {
    public static let format: UInt64 = 1

    /// A record and the id of the phone key it needs.
    public struct Entry: Equatable, Sendable {
        public let keyID: String
        public let record: PhoneSecretRecord

        public init(keyID: String, record: PhoneSecretRecord) {
            self.keyID = keyID
            self.record = record
        }

        func json(_ b: JsonBuilder = JsonBuilder()) -> JsonBuilder {
            b.string("key_id", keyID).raw("record", record.marshal())
        }

        static func parse(_ o: JsonObject) throws -> Entry {
            Entry(keyID: try o.string("key_id"), record: try PhoneSecretRecord.parse(try o.obj("record")))
        }
    }

    public struct Candidate: Equatable, Sendable {
        /// The operation that made it (the request id of its `pin.change` or `vault.secret.renew`).
        public let operation: String
        public let entry: Entry
        /// (A renew's, chosen; not in the spec) The `exp` of the latest request that carried it, by the vault's clock: until
        /// a minute after it a copy waiting in the vault's mailbox may still apply, so an unlock's `ok` with another record
        /// does not make it a replaced record. Nil: none (a PIN change's, whose unresolved change keeps it).
        public var exp: Date?
        /// (A renew's, VAULT-MESSAGING 0.46.0 §11.14.9 step 1) The latest request that carried it and whose answer has not
        /// come: its inner id and the blob version it went with, for `credential.version` to decide before a PIN change.
        /// Nil: none, or decided.
        public var sent: SentRequest?

        public init(operation: String, entry: Entry, exp: Date? = nil, sent: SentRequest? = nil) {
            self.operation = operation
            self.entry = entry
            self.exp = exp.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 * 1000).rounded(.down) / 1000) }
            self.sent = sent
        }
    }

    /// A renew's request sent and not yet answered: its inner id and the blob version it carries.
    public struct SentRequest: Equatable, Sendable {
        public let id: String
        public let version: Int64

        public init(id: String, version: Int64) {
            self.id = id
            self.version = version
        }
    }

    public struct Replaced: Equatable, Sendable {
        public let entry: Entry
        /// The change that made it, if it was a candidate.
        public let operation: String?
        /// Put here only by an unlock's `ok` with the current record, and no record confirmed since: its operation's
        /// late answer still makes it current. A record a confirmed change displaced never comes back that way.
        public var byUnlock: Bool
        /// When its 7 days started (Unix ms): the confirmation, or a later moment when the clock was found behind it.
        public var since: Int64
        /// How long it is kept from [since] (ms): ``PhoneSecrets/keepMs`` divided by the vault's time scale when it became
        /// a replaced record, and kept so afterwards. Nil until the write that stores it gives it the scale of that moment.
        public var keepMs: Int64?

        public init(entry: Entry, operation: String?, byUnlock: Bool = false, since: Int64, keepMs: Int64? = nil) {
            self.entry = entry
            self.operation = operation
            self.byUnlock = byUnlock
            self.since = since
            self.keepMs = keepMs
        }
    }

    public var current: Entry?
    public var pendings: [Entry] = []
    public var candidates: [Candidate] = []
    public var replaced: [Replaced] = []
    public var unresolved: UnresolvedChange?
    /// The operation of the PIN change whose check ended without a decision (VAULT-MESSAGING 0.45.0 §11.14.9 step 3);
    /// read through ``uncertainPin``, which drops it once its candidate is no longer one.
    var uncertainPinOperation: String?

    public init(
        current: Entry? = nil, pendings: [Entry] = [], candidates: [Candidate] = [], replaced: [Replaced] = [],
        unresolved: UnresolvedChange? = nil
    ) {
        self.current = current
        self.pendings = pendings
        self.candidates = candidates
        self.replaced = replaced
        self.unresolved = unresolved
    }

    /// The operation of a PIN change whose PIN is uncertain (§11.14.9 step 3): set when its check ended without a
    /// decision, and settled once an unlock confirmed its candidate or made it a replaced record (the vault then held the
    /// new or the previous PIN).
    public var uncertainPin: String? {
        uncertainPinOperation.flatMap { op in candidates.contains { $0.operation == op } ? op : nil }
    }

    /// A record was confirmed: no replaced record can come back through its operation's late answer any more.
    mutating func confirmed() {
        for i in replaced.indices { replaced[i].byUnlock = false }
    }

    /// Every entry: the current one, the pending one, the candidates and the replaced ones.
    public var all: [Entry] {
        [current].compactMap { $0 } + pendings + candidates.map(\.entry) + replaced.map(\.entry)
    }

    public func marshal() -> [UInt8] {
        let candidates = candidates.map { c in
            let b = JsonBuilder().string("operation", c.operation)
            if let exp = c.exp { b.uint("exp", UInt64(max(0, (exp.timeIntervalSince1970 * 1000).rounded(.down)))) }
            if let sent = c.sent { b.string("sent_id", sent.id).uint("sent_version", UInt64(max(0, sent.version))) }
            return c.entry.json(b).build()
        }
        let replaced = replaced.map { r in
            let b = JsonBuilder().uint("since", UInt64(max(0, r.since)))
            if let keep = r.keepMs, keep != PhoneSecrets.keepMs { b.uint("keep_ms", UInt64(max(0, keep))) }
            if let op = r.operation { b.string("operation", op) }
            if r.byUnlock { b.bool("by_unlock", true) }
            return r.entry.json(b).build()
        }
        let b = JsonBuilder().uint("v", Self.format)
        if let current { b.raw("current", current.json().bytes()) }
        b.raw("pendings", JsonBuilder.array(pendings.map { $0.json().build() }))
            .raw("candidates", JsonBuilder.array(candidates))
            .raw("replaced", JsonBuilder.array(replaced))
        if let unresolved { b.raw("unresolved", unresolved.json()) }
        if let uncertainPin { b.string("uncertain_pin", uncertainPin) }
        return b.bytes()
    }

    /// The format number of [b], without parsing the rest: an app that meets a format it does not know refuses to use
    /// the file rather than compute a secret by another rule (VAULT-MESSAGING §11.14.1 rule 9).
    static func format(_ b: [UInt8]) throws -> UInt64 {
        try StrictJson.parseObject(b).uint("v", min: 0, max: StrictJson.maxSafeInteger)
    }

    public static func parse(_ b: [UInt8]) throws -> PhoneRecords {
        let o = try StrictJson.parseObject(b)
        _ = try o.uint("v", min: format, max: format)
        let candidates = try o.array("candidates").map { v in
            let c = try v.asObject()
            let exp = try c.optUint("exp", min: 0, max: StrictJson.maxSafeInteger).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            let sentID = try c.optString("sent_id")
            let sentVersion = try c.optUint("sent_version", min: 0, max: StrictJson.maxSafeInteger)
            let sent = sentID.flatMap { id in sentVersion.map { SentRequest(id: id, version: Int64($0)) } }
            return Candidate(operation: try c.string("operation"), entry: try Entry.parse(c), exp: exp, sent: sent)
        }
        let replaced = try o.array("replaced").map { v in
            let r = try v.asObject()
            let since = try r.uint("since", min: 0, max: StrictJson.maxSafeInteger)
            let byUnlock = r.has("by_unlock") ? try r.bool("by_unlock") : false
            let keep = try r.optUint("keep_ms", min: 1_000, max: StrictJson.maxSafeInteger).map { Int64($0) } ?? PhoneSecrets.keepMs
            return Replaced(
                entry: try Entry.parse(r), operation: try r.optString("operation"), byUnlock: byUnlock, since: Int64(since),
                keepMs: keep
            )
        }
        let pendings = try o.array("pendings").map { try Entry.parse(try $0.asObject()) }
        guard candidates.count <= PhoneSecrets.maxCandidates, pendings.count <= PhoneSecrets.maxPendings else {
            throw CryptoError.format("phone records")
        }
        var recs = PhoneRecords(
            current: try o.optObj("current").map(Entry.parse), pendings: pendings, candidates: candidates, replaced: replaced,
            unresolved: try o.optObj("unresolved").map(UnresolvedChange.parse)
        )
        recs.uncertainPinOperation = try o.optString("uncertain_pin")
        return recs
    }
}

/// A change of PIN or password sent and not yet decided (VAULT-MESSAGING §11.14.9 "A lost answer" step 1): its type,
/// inner id, the blob version the request carries and its `exp`, and for a PIN change the operation of its candidate
/// record. It holds no PIN, password or secret. Stored form (chosen; not in the spec):
/// `{"type","id","version","exp","operation"?}`, `exp` in Unix ms.
public struct UnresolvedChange: Equatable, Sendable {
    public let type: ChangeType
    public let id: String
    public let version: Int64
    public let exp: Date
    /// The operation of the PIN change's candidate record (``PhoneRecords/Candidate/operation``).
    public let operation: String?

    public init(type: ChangeType, id: String, version: Int64, exp: Date, operation: String? = nil) {
        self.type = type
        self.id = id
        self.version = version
        // Stored in ms.
        self.exp = Date(timeIntervalSince1970: (exp.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        self.operation = operation
    }

    /// The same change, for the PIN change's candidate [operation].
    public func with(operation: String) -> UnresolvedChange {
        UnresolvedChange(type: type, id: id, version: version, exp: exp, operation: operation)
    }

    func json() -> [UInt8] {
        let b = JsonBuilder().string("type", type.rawValue).string("id", id).uint("version", UInt64(max(0, version)))
            .uint("exp", UInt64(max(0, (exp.timeIntervalSince1970 * 1000).rounded(.down))))
        if let operation { b.string("operation", operation) }
        return b.bytes()
    }

    static func parse(_ o: JsonObject) throws -> UnresolvedChange {
        guard let type = ChangeType(rawValue: try o.string("type")) else { throw CryptoError.format("unresolved change type") }
        let exp = try o.uint("exp", min: 0, max: StrictJson.maxSafeInteger)
        return UnresolvedChange(
            type: type, id: try o.string("id"), version: Int64(try o.uint("version", min: 0, max: StrictJson.maxSafeInteger)),
            exp: Date(timeIntervalSince1970: Double(exp) / 1000), operation: try o.optString("operation")
        )
    }
}

/// The two changes whose lost answer is decided rather than repeated (VAULT-MESSAGING §11.14.9 "A lost answer").
public enum ChangeType: String, Equatable, Sendable {
    case pin = "pin.change"
    case password = "credential.password.change"
}

/// An answer of the vault that the phone's records react to: `vault.unlock`'s result (VAULT-MESSAGING §11.4), or a
/// recovery open's.
public protocol SecretCheckedAnswer {
    var ok: Bool { get }
    /// The refusal's code (nil when ``ok``).
    var code: String? { get }
    /// When the vault answered, by its clock (the result's `ts`); nil when not known.
    var at: Date? { get }
}

public extension SecretCheckedAnswer {
    var at: Date? { nil }
}

/// A plain answer (tests, and callers that keep nothing else).
public struct UnlockAnswer: SecretCheckedAnswer, Equatable, Sendable {
    public let ok: Bool
    public let code: String?

    public init(ok: Bool, code: String? = nil) {
        self.ok = ok
        self.code = code
    }

    public static let opened = UnlockAnswer(ok: true)

    public static func refused(_ code: String) -> UnlockAnswer { UnlockAnswer(ok: false, code: code) }
}

/// Which unlock answers prove a record (release R, VAULT-MESSAGING §11.14.1, §11.14.2). Mirrors vettid-android
/// `UnlockEpoch`.
public enum UnlockEpoch {
    /// The code the vault gives when the secret matches neither `secret_check` nor `secret_check_next`, decided before
    /// the PIN.
    public static let deviceSecret = "device_secret"
    public static let transferIncomplete = "transfer_incomplete"

    /// After `device_secret` with the current record, a candidate's try: it is the vault's secret when the answer is one
    /// the vault gives only after the secret matched (`ok`, `bad_pin`, `transfer_incomplete`). Answers decided before the
    /// secret check (`backoff`, `manifest`, `retry`, …) prove nothing.
    public static func confirmsNext(ok: Bool, code: String?) -> Bool {
        ok || code == "bad_pin" || code == transferIncomplete
    }

    /// The earlier-secret step (§11.14.1 rule 7): only `ok`, or `transfer_incomplete` for an unfinished transfer, makes
    /// a replaced record current again; `bad_pin` moves nothing.
    public static func restoresEarlier(ok: Bool, code: String?) -> Bool { ok || code == transferIncomplete }
}
