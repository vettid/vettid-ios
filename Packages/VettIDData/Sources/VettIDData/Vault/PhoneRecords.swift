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
///   (VAULT-MESSAGING §11.14.9 "A lost answer"), written in the same atomic write as the PIN change's candidate.
///
/// Stored form (chosen; not in the spec): `{"v":1,"current":E,"pendings":[E],"candidates":[{"operation",E…}],
/// "replaced":[{"since","operation"?,"by_unlock"?,E…}],"unresolved"?:U}` where `E` is `"key_id","record"`, `U` is
/// ``UnresolvedChange``'s form, compact JSON, records in ``PhoneSecretRecord``'s form, `since` in Unix ms. A file without
/// `unresolved` (written before it existed) has none.
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

        public init(entry: Entry, operation: String?, byUnlock: Bool = false, since: Int64) {
            self.entry = entry
            self.operation = operation
            self.byUnlock = byUnlock
            self.since = since
        }
    }

    public var current: Entry?
    public var pendings: [Entry] = []
    public var candidates: [Candidate] = []
    public var replaced: [Replaced] = []
    public var unresolved: UnresolvedChange?

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

    /// A record was confirmed: no replaced record can come back through its operation's late answer any more.
    mutating func confirmed() {
        for i in replaced.indices { replaced[i].byUnlock = false }
    }

    /// Every entry: the current one, the pending one, the candidates and the replaced ones.
    public var all: [Entry] {
        [current].compactMap { $0 } + pendings + candidates.map(\.entry) + replaced.map(\.entry)
    }

    public func marshal() -> [UInt8] {
        let candidates = candidates.map { $0.entry.json(JsonBuilder().string("operation", $0.operation)).build() }
        let replaced = replaced.map { r in
            let b = JsonBuilder().uint("since", UInt64(max(0, r.since)))
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
            return Candidate(operation: try c.string("operation"), entry: try Entry.parse(c))
        }
        let replaced = try o.array("replaced").map { v in
            let r = try v.asObject()
            let since = try r.uint("since", min: 0, max: StrictJson.maxSafeInteger)
            let byUnlock = r.has("by_unlock") ? try r.bool("by_unlock") : false
            return Replaced(
                entry: try Entry.parse(r), operation: try r.optString("operation"), byUnlock: byUnlock, since: Int64(since)
            )
        }
        let pendings = try o.array("pendings").map { try Entry.parse(try $0.asObject()) }
        guard candidates.count <= PhoneSecrets.maxCandidates, pendings.count <= PhoneSecrets.maxPendings else {
            throw CryptoError.format("phone records")
        }
        return PhoneRecords(
            current: try o.optObj("current").map(Entry.parse), pendings: pendings, candidates: candidates, replaced: replaced,
            unresolved: try o.optObj("unresolved").map(UnresolvedChange.parse)
        )
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
