import Foundation
import VettIDCrypto

/// A relay error response (RELAY-PROTOCOL §7.1). [code] is `http_<status>` when the body carried none.
public struct RelayError: Error, Equatable, Sendable, CustomStringConvertible {
    public static let badRequest = "bad_request"
    public static let signatureInvalid = "signature_invalid"
    public static let timestampStale = "timestamp_stale"
    public static let replayDetected = "replay_detected"
    public static let tokenInvalid = "token_invalid"
    public static let tokenExpired = "token_expired"
    public static let tokenRevoked = "token_revoked"
    public static let tokenUsed = "token_used"
    public static let mailboxUnknown = "mailbox_unknown"
    public static let blobUnknown = "blob_unknown"
    public static let claimUnknown = "claim_unknown"
    public static let notFound = "not_found"
    public static let payloadTooLarge = "payload_too_large"
    public static let quotaExceeded = "quota_exceeded"
    public static let rateLimited = "rate_limited"
    public static let internalError = "internal"
    /// A larger `retry_after` / `Retry-After` is clamped to this (a day).
    public static let maxRetryAfterSeconds = 86_400

    public let status: Int
    public let code: String
    public let message: String
    public let retryAfterSeconds: Int
    /// `quota_exceeded`'s `quota` (0.9.2): `token`, `mailbox`, `mailbox_blobs` or `sender_blobs`; nil otherwise.
    public let quota: String?

    public init(status: Int, code: String, message: String = "", retryAfterSeconds: Int = 0, quota: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
        self.quota = quota
    }

    /// `429 rate_limited` and 5xx are retried with backoff (§7.2), and so is a signature the relay found stale or
    /// already seen (``staleSignature``); other client errors never are, `429 quota_exceeded` included (§7.1: not
    /// transient, never retried unchanged).
    public var retryable: Bool { (status == 429 && code != Self.quotaExceeded) || status >= 500 || staleSignature }

    /// `timestamp_stale` or `replay_detected` (§4.1): the signature was made too long before it reached the relay (a
    /// phone frozen in the background with the request in hand) or was sent twice. Nothing was applied; the same
    /// request signed afresh is accepted.
    public var staleSignature: Bool { status == 401 && (code == Self.timestampStale || code == Self.replayDetected) }

    public var description: String { "relay: \(status) \(code)" + (message.isEmpty ? "" : ": \(message)") }
}

/// The relay limits returned at registration (§6.1).
public struct RelayLimits: Equatable, Sendable {
    public let maxPayloadBytes: UInt64
    public let messageTTLSeconds: UInt64
    public let visibilityTimeoutSeconds: UInt64
    public let maxTokenLifetimeSeconds: UInt64
    public let openTokenMaxLifetimeSeconds: UInt64
    public let maxClaimBytes: UInt64
    public let claimTTLSeconds: UInt64
    public let maxBlobBytes: UInt64?
    public let blobTTLSeconds: UInt64?
}

/// The register response. [created] is false when the key was already registered (200).
public struct Registration: Equatable, Sendable {
    public let mailboxID: String
    public let limits: RelayLimits
    public let created: Bool
}

/// A collected message (§6.3, §6.4). [sender] is the relay key that signed the deposit; [jti] may be absent.
public struct RelayMessage: Sendable, CustomStringConvertible {
    public let msgID: String
    public let depositedAt: String
    public let sender: String
    public let jti: String?
    public let payload: [UInt8]

    public init(msgID: String, depositedAt: String, sender: String, jti: String?, payload: [UInt8]) {
        self.msgID = msgID
        self.depositedAt = depositedAt
        self.sender = sender
        self.jti = jti
        self.payload = payload
    }

    /// The sender's raw relay key, or nil if malformed.
    public var senderKey: [UInt8]? { RelayAuth.decodeKey(sender) }

    public var description: String { "RelayMessage(\(msgID))" }

    static func parse(_ o: JsonObject) throws -> RelayMessage {
        RelayMessage(
            msgID: try o.string("msg_id"),
            depositedAt: try o.optString("deposited_at") ?? "",
            sender: try o.optString("sender") ?? "",
            jti: try o.optString("jti"),
            payload: try o.base64("payload")
        )
    }
}

/// A denylist entry (§5.5): `jti` revokes one token, `sub` everything a sender holds.
public struct Revocation: Equatable, Sendable {
    public let kind: String
    public let value: String

    public static func jti(_ jti: String) -> Revocation { Revocation(kind: "jti", value: jti) }
    public static func sub(_ senderB64: String) -> Revocation { Revocation(kind: "sub", value: senderB64) }
}

/// A stored blob or claim and when it expires.
public struct StoredRef: Equatable, Sendable {
    public let id: String
    public let expiresAt: Date?
}

/// The relay client for one principal (one relay key pair), as vettid-relay's `relayclient` and vettid-android
/// `RelayClient`. Every request is signed afresh per attempt (§4.1), including the attempts the transport retry makes
/// after waiting for the network. `429 rate_limited`, 5xx, `timestamp_stale`, `replay_detected` and transport errors are
/// retried with exponential backoff and jitter, honouring `retry_after` (§7.2); other client errors are not retried,
/// and a claim GET is never retried (it may already have consumed the claim).
///
/// [baseURL] is the relay's base URL as tokens name it (`aud`).
public final class RelayClient: Sendable {
    public static let defaultAttempts = 3
    public static let defaultWait: TimeInterval = 25
    public static let defaultMax = 32
    static let maxWait = 25
    public static let maxCollect = 100
    static let pollTimeout: TimeInterval = 60
    static let backoffBase: TimeInterval = 0.25
    static let backoffMaxShift = 6
    static let jitter: TimeInterval = 0.25
    static let errorBodyLimit = 4096
    static let maxMessage = 256
    static let maxClaimRead = 1 << 20
    static let maxJSONRead = 32 << 20
    /// The reference relay's `max_blob_bytes` (§6.8): no blob a relay keeps is larger.
    public static let maxBlobRead = 8_388_608

    public let baseURL: String
    private let signer: Ed25519PrivateKey
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let maxAttempts: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let random: @Sendable (TimeInterval) -> TimeInterval

    public init(
        baseURL: String,
        key: Ed25519PrivateKey,
        transport: HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() },
        maxAttempts: Int = defaultAttempts,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
        random: @escaping @Sendable (TimeInterval) -> TimeInterval = { TimeInterval.random(in: 0..<max($0, .leastNonzeroMagnitude)) }
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.signer = key
        self.transport = transport
        self.now = now
        self.maxAttempts = maxAttempts
        self.sleep = sleep
        self.random = random
    }

    /// The raw public key.
    public var publicKey: [UInt8] { signer.publicKey }
    /// Canonical base64 of the public key (a token's `sub`).
    public var publicKeyB64: String { RelayAuth.encodeKey(signer.publicKey) }
    /// This principal's mailbox id.
    public var mailboxID: String { RelayAuth.mailboxID(signer.publicKey) }

    struct Call {
        var method: String
        var path: String
        var query: String?
        var body: [UInt8]?
        var token: String?
        var contentType: String?
        var unsigned = false
        var longPoll = false
        var policy: HTTPTransport.Policy = .unsentOnly
        var maxBody = RelayClient.maxJSONRead
    }

    private func backoff(_ attempt: Int) -> TimeInterval {
        let d = Self.backoffBase * Double(1 << min(attempt, Self.backoffMaxShift))
        return d / 2 + random(d / 2)
    }

    func execute(_ c: Call) async throws -> HTTPAnswer {
        var last: Error?
        for i in 0..<max(maxAttempts, 1) {
            if i > 0 {
                if let e = last as? RelayError, e.retryAfterSeconds > 0 {
                    try await sleep(Double(e.retryAfterSeconds) + random(Self.jitter))
                } else {
                    try await sleep(backoff(i))
                }
            }
            do {
                return try await once(c)
            } catch let e as RelayError {
                guard e.retryable else { throw e }
                last = e
            } catch let e as URLError {
                // A certificate or pin that does not match, or a cancelled call, is not a passing state of the network.
                try Task.checkCancellation()
                guard !HTTPTransport.fatal.contains(e.code) else { throw e }
                last = e
            }
        }
        throw last ?? URLError(.unknown)
    }

    func once(_ c: Call) async throws -> HTTPAnswer {
        let a: HTTPAnswer
        do {
            a = try await transport.send(policy: c.policy, maxBody: c.maxBody, timeout: c.longPoll ? Self.pollTimeout : nil) {
                try request(c)
            }
        } catch let e as BodyTooLarge {
            throw RelayError(status: e.status, code: RelayError.payloadTooLarge, message: "response")
        }
        if a.status >= 400 { throw Self.error(a) }
        return a
    }

    private func request(_ c: Call) throws -> URLRequest {
        guard let url = URL(string: baseURL + c.path + (c.query.map { "?\($0)" } ?? "")) else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.httpMethod = c.method
        if !c.unsigned {
            for (k, v) in try RelayAuth.headers(signer, method: c.method, path: c.path, at: now(), bodyHash: RelayAuth.bodyHash(c.body)) {
                r.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let t = c.token { r.setValue("VettID-Deposit \(t)", forHTTPHeaderField: "Authorization") }
        if let b = c.body {
            r.httpBody = Data(b)
            r.setValue(c.contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        } else if c.method == "POST" || c.method == "PUT" {
            r.httpBody = Data()
        }
        return r
    }

    static func error(_ a: HTTPAnswer) -> RelayError {
        let text = Array(a.body.prefix(errorBodyLimit))
        let headerValue = a.header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let headerRetry = min(max(headerValue, 0), RelayError.maxRetryAfterSeconds)
        guard let o = try? StrictJson.parseObject(text), case .string(_, let code)? = o["code"], !code.isEmpty else {
            let raw = String(bytes: text, encoding: .utf8) ?? ""
            let msg = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxMessage))
            return RelayError(status: a.status, code: "http_\(a.status)", message: msg, retryAfterSeconds: headerRetry)
        }
        var retry = headerRetry
        if case .number(let raw)? = o["retry_after"], let n = Int(raw), n >= 0 { retry = n }
        retry = min(retry, RelayError.maxRetryAfterSeconds)
        var message = ""
        if case .string(_, let m)? = o["message"] { message = m }
        var quota: String?
        if case .string(_, let q)? = o["quota"] { quota = q }
        return RelayError(status: a.status, code: code, message: message, retryAfterSeconds: retry, quota: quota)
    }

    private func json(_ c: Call) async throws -> JsonObject? {
        let a = try await execute(c)
        if a.status == 204 || a.body.isEmpty { return nil }
        return try StrictJson.parseObject(a.body)
    }

    private func requireJSON(_ c: Call) async throws -> JsonObject {
        guard let o = try await json(c) else { throw RelayError(status: 200, code: "empty_response") }
        return o
    }

    /// Registers this principal's mailbox (idempotent, §6.1).
    public func register() async throws -> Registration {
        let a = try await execute(Call(method: "POST", path: "/v1/register", body: JsonBuilder().string("pubkey", publicKeyB64).bytes()))
        let o = try StrictJson.parseObject(a.body)
        let l = try o.obj("limits")
        func n(_ k: String) throws -> UInt64 { try l.uint(k, min: 0, max: StrictJson.maxSafeInteger) }
        func opt(_ k: String) throws -> UInt64? { try l.optUint(k, min: 0, max: StrictJson.maxSafeInteger) }
        return Registration(
            mailboxID: try o.string("mailbox_id"),
            limits: RelayLimits(
                maxPayloadBytes: try n("max_payload_bytes"), messageTTLSeconds: try n("message_ttl_seconds"),
                visibilityTimeoutSeconds: try n("visibility_timeout_seconds"), maxTokenLifetimeSeconds: try n("max_token_lifetime_seconds"),
                openTokenMaxLifetimeSeconds: try n("open_token_max_lifetime_seconds"), maxClaimBytes: try n("max_claim_bytes"),
                claimTTLSeconds: try n("claim_ttl_seconds"), maxBlobBytes: try opt("max_blob_bytes"),
                blobTTLSeconds: try opt("blob_ttl_seconds")
            ),
            created: a.status == 201
        )
    }

    /// A standing, sender-bound token for [senderB64] to deposit into this mailbox on [audience] (default this relay).
    public func mintToken(
        sender senderB64: String,
        audience: String? = nil,
        ttl: TimeInterval = DepositTokens.standingTTL,
        jti: String? = nil,
        quota: Quota? = nil
    ) throws -> String {
        try DepositTokens.mintStanding(
            signer, sender: senderB64, audience: audience ?? baseURL, now: now(), ttl: ttl, jti: jti, quota: quota
        )
    }

    /// A one-shot open token (§5.6) for this mailbox. Keep [ttl] as short as the use allows.
    public func mintOpenToken(audience: String? = nil, ttl: TimeInterval = 300, jti: String? = nil) throws -> String {
        try DepositTokens.mintOpen(signer, audience: audience ?? baseURL, now: now(), ttl: ttl, jti: jti)
    }

    /// Deposits [payload] into [mailboxID] with [token] (§6.2) and returns the relay's msg_id. A retried deposit whose
    /// first attempt succeeded leaves two messages: receivers dedupe at the E2E layer too.
    public func deposit(mailboxID: String, token: String, payload: [UInt8]) async throws -> String {
        let body = JsonBuilder().base64("payload", payload).bytes()
        return try await requireJSON(Call(method: "POST", path: "/v1/mailbox/\(mailboxID)", body: body, token: token)).string("msg_id")
    }

    /// Long-polls this mailbox (§6.3): [wait] ≤ 25 s, [max] ≤ 100.
    public func collect(wait: TimeInterval = defaultWait, max: Int = defaultMax) async throws -> [RelayMessage] {
        let w = Swift.min(Swift.max(Int(wait), 0), Self.maxWait)
        let m = Swift.min(Swift.max(max, 1), Self.maxCollect)
        let c = Call(method: "GET", path: "/v1/mailbox", query: "wait=\(w)&max=\(m)", longPoll: true)
        guard let o = try await json(c) else { return [] }
        return try o.array("messages").map { try RelayMessage.parse(try $0.asObject()) }
    }

    /// Acks (deletes) a collected message (§6.5; always 204).
    public func ack(_ msgID: String) async throws {
        _ = try await json(Call(method: "DELETE", path: "/v1/mailbox/\(msgID)"))
    }

    /// Deletes this mailbox and everything in it (§6.10; idempotent).
    public func deleteMailbox() async throws {
        _ = try await json(Call(method: "DELETE", path: "/v1/mailbox"))
    }

    /// Adds entries to this mailbox's denylist (§5.5).
    public func revoke(_ entries: [Revocation]) async throws {
        let arr = JsonBuilder.array(entries.map { JsonBuilder().string("kind", $0.kind).string("value", $0.value).build() })
        _ = try await json(Call(method: "POST", path: "/v1/mailbox/denylist", body: JsonBuilder().raw("revoke", arr).bytes()))
    }

    /// Moves this mailbox to [newKey] (§6.7) and returns the new mailbox id. This client keeps signing with the old key;
    /// make a new client for the new one.
    public func rotate(to newKey: Ed25519PrivateKey) async throws -> String {
        let proof = try newKey.signRaw(Array(mailboxID.utf8))
        let body = JsonBuilder().string("new_pubkey", RelayAuth.encodeKey(newKey.publicKey)).base64("new_key_proof", proof).bytes()
        return try await requireJSON(Call(method: "POST", path: "/v1/mailbox/rotate", body: body)).string("mailbox_id")
    }

    /// Uploads ciphertext to [mailboxID] (claim-check, §6.8).
    public func putBlob(mailboxID: String, token: String, ciphertext: [UInt8]) async throws -> StoredRef {
        let o = try await requireJSON(
            Call(method: "PUT", path: "/v1/blob/\(mailboxID)", body: ciphertext, token: token, contentType: "application/octet-stream")
        )
        return StoredRef(id: try o.string("blob_id"), expiresAt: Self.time(try o.optString("expires_at")))
    }

    /// Fetches a blob deposited to this mailbox (§6.8). At most [maxBytes] are ever held: a declared length over it is
    /// refused before reading, and so is a body that grows beyond it.
    public func getBlob(_ blobID: String, maxBytes: Int = maxBlobRead) async throws -> [UInt8] {
        try await execute(Call(method: "GET", path: "/v1/blob/\(blobID)", maxBody: maxBytes)).body
    }

    /// Deletes a blob (idempotent).
    public func deleteBlob(_ blobID: String) async throws {
        _ = try await json(Call(method: "DELETE", path: "/v1/blob/\(blobID)"))
    }

    /// Leaves a single-fetch claim owned by this mailbox (§6.9); [ttl] nil uses the relay default.
    public func putClaim(_ data: [UInt8], ttl: TimeInterval? = nil) async throws -> StoredRef {
        let path = ttl.map { "/v1/claim/ttl/\(Int($0))" } ?? "/v1/claim"
        let o = try await requireJSON(Call(method: "PUT", path: path, body: data, contentType: "application/octet-stream"))
        return StoredRef(id: try o.string("claim_id"), expiresAt: Self.time(try o.optString("expires_at")))
    }

    /// Fetches (and thereby deletes) a claim on this relay (§6.9). Unauthenticated and NEVER retried: after a lost
    /// response the claim is gone (`claim_unknown`).
    public func getClaim(_ claimID: String) async throws -> [UInt8] {
        try await once(Call(method: "GET", path: "/v1/claim/\(claimID)", unsigned: true, policy: .never, maxBody: Self.maxClaimRead)).body
    }

    /// Deletes a claim this mailbox created (idempotent).
    public func deleteClaim(_ claimID: String) async throws {
        _ = try await json(Call(method: "DELETE", path: "/v1/claim/\(claimID)"))
    }

    /// The owner-signed upgrade request of a WebSocket collect session (§6.4), with its http(s) URL: the caller applies
    /// the dev stack's origin map, then ``webSocket(_:)``.
    public func streamRequest() throws -> URLRequest {
        let path = "/v1/mailbox/ws"
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        for (k, v) in try RelayAuth.headers(signer, method: "GET", path: path, at: now(), bodyHash: RelayAuth.bodyHash(nil)) {
            r.setValue(v, forHTTPHeaderField: k)
        }
        return r
    }

    /// [r] with its scheme changed from http(s) to ws(s).
    public static func webSocket(_ r: URLRequest) -> URLRequest {
        guard let url = r.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return r }
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        var out = r
        out.url = c.url
        return out
    }

    static func time(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
