import Foundation
import VettIDCrypto
import VettIDRelay

/// How requests to the member API are authenticated. Mirrors vettid-android `MemberAuth`.
///
/// - ``appKey(_:vaultID:)``: the production model since MEMBER-API 2.0.0 (VAULT-MESSAGING §11.12.2): the app never
///   signs in; every request carries `X-VettID-App`, signed by the app key, and names the vault (empty before one is
///   known: a redeem). No cookies, no CSRF header. Each attempt is signed anew (a nonce is accepted once).
/// - ``bearer(_:)``: the local dev stack's member API stand-in, which names the member by
///   `Authorization: Bearer <user_guid>`. Development and tests only.
public enum MemberAuth: Sendable {
    case appKey(AppKeySigner, vaultID: @Sendable () -> String?)
    case bearer(String)

    var signedPerRequest: Bool {
        if case .appKey = self { return true }
        return false
    }

    func apply(_ r: inout URLRequest, method: String, url: URL, body: [UInt8], vaultOverride: String?) throws {
        switch self {
        case .appKey(let signer, let vaultID):
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let value = try AppRequestSigning.headerValue(
                signer: signer, method: method, path: c?.percentEncodedPath ?? url.path, query: c?.percentEncodedQuery,
                vaultID: vaultOverride ?? vaultID(), body: body
            )
            r.setValue(value, forHTTPHeaderField: AppRequestSigning.header)
        case .bearer(let guid):
            r.setValue("Bearer \(guid)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// The member API (MEMBER-API 2.0.0) as the app uses it: the setup-code redeem, the vault routes of the alternate
/// channel and the recovery claim and register, every request signed by the app key. It only ever sees opaque
/// envelopes. [apiBase] is the account origin and [manifestURL] where the release manifest is served (its path is
/// ``manifestPath``), both from the build's environment (the app's Info.plist), never from this package, so that a
/// build carries no other environment's hosts (release check). Mirrors vettid-android `MemberApiClient`.
public final class MemberApiClient: Sendable {
    public static let defaultPollInterval: TimeInterval = 0.6
    public static let manifestPath = "/.well-known/vettid/pcr-manifest.json"
    static let redeemPath = "/api/vault/enroll/redeem"
    static let claimPath = "/api/vault/recovery/claim"
    static let maxBody = 1 << 20
    static let maxStartWait: TimeInterval = 2
    /// How long ``enclaveWait(release:onStarting:)`` waits for a release to start before it gives up.
    public static let maxStartTotal: TimeInterval = 10 * 60
    /// A larger `retry_after` / `Retry-After` is clamped to this (a day).
    public static let maxRetryAfterSeconds = 86_400

    public let manifestURL: String
    private let base: String
    private let transport: HTTPTransport
    private let auth: MemberAuth
    private let pollInterval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        apiBase: String,
        manifestURL: String,
        transport: HTTPTransport,
        auth: MemberAuth,
        pollInterval: TimeInterval = defaultPollInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        base = apiBase.hasSuffix("/") ? String(apiBase.dropLast()) : apiBase
        self.manifestURL = manifestURL
        self.transport = transport
        self.auth = auth
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
    }

    /// One signed request; [vault] names the vault in the signature header instead of the client's (a redeem: "").
    private func call(_ method: String, _ path: String, body: String? = nil, vault: String? = nil) async throws -> JsonObject? {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        let bytes = body.map { Array($0.utf8) } ?? []
        let policy: HTTPTransport.Policy = method == "GET" ? .idempotent : .unsentOnly
        let send = {
            try await self.transport.send(policy: policy, maxBody: Self.maxBody) {
                var r = URLRequest(url: url)
                r.httpMethod = method
                try self.auth.apply(&r, method: method, url: url, body: bytes, vaultOverride: vault)
                if body != nil {
                    r.httpBody = Data(bytes)
                    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                } else if method == "POST" {
                    r.httpBody = Data()
                }
                return r
            }
        }
        var a = try await answer(send)
        // A 401 has no detail (MEMBER-API "App request signing"); one of its causes is a nonce the API has seen, which is
        // what a request re-sent below this client looks like. The API checks the signature before it does anything, so
        // a refused request did nothing: ask once more with a signature made now. Only a 401 to that second request is
        // reported.
        if a.status == 401, auth.signedPerRequest { a = try await answer(send) }
        if a.status == 401 { throw unauthorized(a) }
        guard a.status / 100 == 2 else { throw Self.error(a) }
        if a.body.isEmpty { return nil }
        guard let o = try? StrictJson.parseObject(a.body) else { throw MemberApiMalformed(what: "response") }
        return o
    }

    private func answer(_ send: () async throws -> HTTPAnswer) async throws -> HTTPAnswer {
        do {
            return try await send()
        } catch is BodyTooLarge {
            throw MemberApiMalformed(what: "response too large")
        }
    }

    /// A `401` after a freshly signed request: when the answer's `Date` shows the phone's clock to be off, it is
    /// reported as ``MemberApiError/clockSkew``; otherwise as the API's `unauthorized`.
    private func unauthorized(_ a: HTTPAnswer) -> MemberApiError {
        let e = Self.error(a)
        guard let date = a.header("Date").flatMap(Self.httpDate) else { return e }
        guard abs(now().timeIntervalSince(date)) > MemberApiError.clockSkewSeconds else { return e }
        return MemberApiError(status: 401, code: MemberApiError.clockSkew)
    }

    static func error(_ a: HTTPAnswer) -> MemberApiError {
        let headerRetry = retryAfterHeader(a.header("Retry-After"))
        guard let o = try? StrictJson.parseObject(a.body) else {
            return MemberApiError(status: a.status, code: "http_\(a.status)", retryAfterSeconds: headerRetry)
        }
        func s(_ k: String) -> String? {
            if case .string(_, let v)? = o[k] { return v }
            return nil
        }
        var retry = headerRetry
        if case .number(let raw)? = o["retry_after"], let n = Int(raw), n >= 0 { retry = n }
        // `message` is the API's text for developers; `reason` (the operator's, MEMBER-API 1.2.0) is never read.
        return MemberApiError(
            status: a.status, code: s("code") ?? s("error") ?? "http_\(a.status)", message: s("message") ?? "",
            release: s("release"), retryAfterSeconds: min(retry, maxRetryAfterSeconds), service: s("service")
        )
    }

    /// `Retry-After` in delta-seconds; an HTTP date or anything else counts as absent (0).
    static func retryAfterHeader(_ v: String?) -> Int {
        guard let n = v.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), n >= 0 else { return 0 }
        return min(n, maxRetryAfterSeconds)
    }

    /// An IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), read in the POSIX locale whatever the phone's.
    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    private func required(_ o: JsonObject?) throws -> JsonObject {
        guard let o else { throw MemberApiMalformed(what: "empty") }
        return o
    }

    // MARK: - Setup codes (MEMBER-API 2.0.0 "Setup codes", VAULT-MESSAGING §11.12.1)

    /// Redeems a scanned setup QR's secret with this app's key ([appKey], SPKI DER), signed by that key with an empty
    /// `vault`. Any failure of the code itself is `404 invalid_code`.
    public func redeemSecret(_ secret: String, appKey: [UInt8]) async throws -> Redeemed {
        let body = JsonBuilder().string("secret", secret).base64("app_key", appKey).build()
        return try redeemed(try await call("POST", Self.redeemPath, body: body, vault: ""))
    }

    /// Redeems a typed setup code with the member's email ([code] normalised: 8 symbols, no hyphen).
    public func redeemTyped(email: String, code: String, appKey: [UInt8]) async throws -> Redeemed {
        let body = JsonBuilder().string("email", email).string("code", code).base64("app_key", appKey).build()
        return try redeemed(try await call("POST", Self.redeemPath, body: body, vault: ""))
    }

    private func redeemed(_ o: JsonObject?) throws -> Redeemed {
        let r = try required(o)
        return Redeemed(
            vaultID: try r.string("vault_id"), userGuid: try r.string("user_guid"), emailHint: try r.optString("email_hint") ?? ""
        )
    }

    // MARK: - Vault (alternate channel)

    public func vaultStatus() async throws -> VaultStatus? { try await vaultStatusAnswer().vault }

    /// `GET /api/vault/status` with the top-level `service` (MEMBER-API 1.2.0); still served while paused. "No vault" is
    /// only the API's explicit `"vault": null`: an empty body, a body without `vault` or with anything else there is a
    /// malformed answer, never "this account has no vault".
    public func vaultStatusAnswer() async throws -> VaultStatusAnswer {
        guard let o = try await call("GET", "/api/vault/status") else { throw MemberApiMalformed(what: "empty status") }
        var paused = false
        if case .string(_, let s)? = o["service"] { paused = s == MemberApiError.servicePausedValue }
        switch o["vault"] {
        case .object(let v)?:
            do {
                return VaultStatusAnswer(vault: try Self.parseVault(v), servicePaused: paused)
            } catch is CryptoError {
                throw MemberApiMalformed(what: "status")
            }
        case .null?:
            return VaultStatusAnswer(vault: nil, servicePaused: paused)
        default:
            throw MemberApiMalformed(what: "status")
        }
    }

    private static func parseVault(_ v: JsonObject) throws -> VaultStatus {
        func s(_ o: JsonObject?, _ k: String) -> String? {
            if case .string(_, let x)? = o?[k] { return x }
            return nil
        }
        func n(_ o: JsonObject?, _ k: String) -> Int64? {
            if case .number(let raw)? = o?[k] { return Int64(raw) }
            return nil
        }
        func b(_ o: JsonObject?, _ k: String) -> Bool? {
            if case .bool(_, let x)? = o?[k] { return x }
            return nil
        }
        func obj(_ k: String) -> JsonObject? {
            if case .object(let x)? = v[k] { return x }
            return nil
        }
        let rel = obj("release")
        let rec = obj("recovery")
        let del = obj("deletion")
        return VaultStatus(
            vaultID: try v.string("vault_id"), state: try v.optString("state") ?? "", sealedRelease: s(v, "sealed_release"),
            leased: b(v, "leased") ?? false, alarmKind: s(obj("alarm"), "kind"),
            recoveryState: s(rec, "state"), recoveryAvailableAt: s(rec, "available_at"),
            release: rel.map {
                ReleaseInfo(
                    number: n($0, "number"), status: s($0, "status") ?? "unknown", endsAt: s($0, "ends_at"),
                    newestActive: n($0, "newest_active"), notice: s($0, "notice")
                )
            },
            credentialBackup: b(v, "credential_backup"),
            deletion: s(del, "deletes_at").map {
                PendingDeletion(state: s(del, "state") ?? "pending", deletesAt: $0, deletionID: s(del, "deletion_id"))
            }
        )
    }

    /// The instance to seal to; [release] (a PCR0) only to abandon an unconfirmed move (§11.10.4).
    public func enclave(release: String? = nil) async throws -> EnclaveInfo {
        let q = release.map { "?release=" + Self.queryEscape($0) } ?? ""
        let o = try required(try await call("GET", "/api/vault/enclave" + q))
        do {
            return EnclaveInfo(
                instanceID: try o.string("instance_id"), release: try o.optString("release") ?? "",
                descriptor: try Base64s.decodeStd(try o.string("descriptor")),
                attestation: try Base64s.decodeStd(try o.string("attestation"))
            )
        } catch is CryptoError {
            throw MemberApiMalformed(what: "enclave answer")
        }
    }

    /// ``enclave(release:)``, waiting while the release starts (503 `release_starting`, §11.10.5), for at most
    /// ``maxStartTotal`` in all; then the last `release_starting` is thrown. Any other error, `503 vault_unavailable`
    /// included, is thrown at once. [onStarting] hears each `release_starting` (its `retry_after` in seconds).
    public func enclaveWait(release: String? = nil, onStarting: (@Sendable (Int) -> Void)? = nil) async throws -> EnclaveInfo {
        var waited: TimeInterval = 0
        while true {
            do {
                return try await enclave(release: release)
            } catch let e as MemberApiError {
                guard e.code == MemberApiError.releaseStarting, waited < Self.maxStartTotal else { throw e }
                onStarting?(e.retryAfterSeconds)
                let wait = min(Double(max(e.retryAfterSeconds, 1)), Self.maxStartWait)
                try await sleep(wait)
                waited += wait
            }
        }
    }

    private func posted(_ r: SealedRequest, _ extra: [(String, String)]) -> String {
        let b = JsonBuilder()
        for (k, v) in extra { b.string(k, v) }
        b.string("request_id", r.requestID).string("etk_kid", r.etkKid).string("envelope", Base64s.encodeStd(r.envelope))
        if let m = r.manifestSHA256 { b.string("manifest_sha256", m) }
        return b.build()
    }

    /// Posts a sealed vault.enroll for [vaultID] (the redeem's, MEMBER-API 2.0.0); returns the vault id.
    public func enroll(vaultID: String, instanceID: String, _ r: SealedRequest) async throws -> String {
        let body = JsonBuilder().string("vault_id", vaultID).string("request_id", r.requestID).string("instance_id", instanceID)
            .string("etk_kid", r.etkKid).string("envelope", Base64s.encodeStd(r.envelope))
            .string("manifest_sha256", r.manifestSHA256 ?? "").build()
        return try required(try await call("POST", "/api/vault/enroll", body: body)).string("vault_id")
    }

    /// Posts a sealed vault.unlock.
    public func unlock(vaultID: String, instanceID: String, _ r: SealedRequest) async throws {
        let body = JsonBuilder().string("vault_id", vaultID).string("request_id", r.requestID).string("instance_id", instanceID)
            .string("etk_kid", r.etkKid).string("envelope", Base64s.encodeStd(r.envelope))
            .string("manifest_sha256", r.manifestSHA256 ?? "").build()
        _ = try await call("POST", "/api/vault/unlock", body: body)
    }

    /// Asks for a lock (no envelope).
    public func lock(vaultID: String, requestID: String) async throws {
        let body = JsonBuilder().string("vault_id", vaultID).string("request_id", requestID).build()
        _ = try await call("POST", "/api/vault/lock", body: body)
    }

    /// One look at a response slot.
    public func slot(_ requestID: String) async throws -> Slot {
        let o = try required(try await call("GET", "/api/vault/requests/" + Self.pathEscape(requestID)))
        var envelope: [UInt8]?
        if let e = try o.optString("envelope"), !e.isEmpty {
            guard let b = try? Base64s.decodeStd(e) else { throw MemberApiMalformed(what: "slot envelope") }
            envelope = b
        }
        return Slot(status: try o.string("status"), envelope: envelope, code: try o.optString("code"))
    }

    /// Polls a slot until it is no longer queued (the API allows 2 polls per second), or, with [atMost], until that much
    /// time was spent waiting between polls: the slot is then returned still queued.
    public func poll(_ requestID: String, atMost: TimeInterval? = nil) async throws -> Slot {
        var waited: TimeInterval = 0
        while true {
            let s = try await slot(requestID)
            if s.status != Slot.queued { return s }
            if let atMost, waited >= atMost { return s }
            try await sleep(pollInterval)
            waited += pollInterval
        }
    }

    /// The served release manifest (§11.10.1).
    public func manifest() async throws -> [UInt8] {
        guard let url = URL(string: manifestURL) else { throw URLError(.badURL) }
        let a = try await answer { try await transport.send(policy: .idempotent, maxBody: Self.maxBody) { URLRequest(url: url) } }
        guard a.status == 200 else { throw MemberApiError(status: a.status, code: MemberApiError.manifestUnavailable) }
        return a.body
    }

    // MARK: - Recovery (MEMBER-API "Vault recovery", VAULT-MESSAGING §11.11)

    /// Claims the recovery of the scanned QR with this app's key (§11.11.7), signed by that key with the QR's `vault`.
    public func recoveryClaim(vaultID: String, recoveryID: String, appKey: [UInt8]) async throws -> Claimed {
        let body = JsonBuilder().string("vault_id", vaultID).string("recovery_id", recoveryID).base64("app_key", appKey).build()
        let o = try required(try await call("POST", Self.claimPath, body: body, vault: vaultID))
        return Claimed(
            userGuid: try o.string("user_guid"), emailHint: try o.optString("email_hint") ?? "",
            vaultID: try o.optString("vault_id"), recoveryID: try o.optString("recovery_id")
        )
    }

    /// Claims the recovery a typed code's [locator] names (MEMBER-API 2.4.0, §11.11.10): the body is exactly
    /// `{locator, app_key}`, signed with an empty `vault`. The answer names the vault and the recovery.
    public func recoveryClaim(locator: String, appKey: [UInt8]) async throws -> Claimed {
        guard RecoveryCodes.isLocator(locator) else { throw CryptoError.format("locator") }
        let body = JsonBuilder().string("locator", locator).base64("app_key", appKey).build()
        let o = try required(try await call("POST", Self.claimPath, body: body, vault: ""))
        return Claimed(
            userGuid: try o.string("user_guid"), emailHint: try o.optString("email_hint") ?? "",
            vaultID: try o.string("vault_id"), recoveryID: try o.string("recovery_id")
        )
    }

    /// Cancels a pending start-over (MEMBER-API 2.1.0), signed by the vault's app key. True when it was cancelled; false
    /// once it is executing.
    public func deletionCancel(_ deletionID: String) async throws -> Bool {
        let o = try await call("POST", "/api/vault/deletion/cancel", body: JsonBuilder().string("deletion_id", deletionID).build())
        if case .bool(_, let v)? = o?["cancelled"] { return v }
        return false
    }

    /// Posts a sealed vault.recovery.register (no manifest_sha256).
    public func recoveryRegister(vaultID: String, instanceID: String, _ r: SealedRequest) async throws {
        let body = posted(r, [("vault_id", vaultID), ("instance_id", instanceID)])
        _ = try await call("POST", "/api/vault/recovery/register", body: body, vault: vaultID)
    }

    /// `vault.recovery.open` (VAULT-MESSAGING 0.33.0 §11.14.6, release R): routed to the vault's leased instance.
    public func recoveryOpen(vaultID: String, instanceID: String, _ r: SealedRequest) async throws {
        let body = posted(r, [("vault_id", vaultID), ("instance_id", instanceID)])
        _ = try await call("POST", "/api/vault/recovery/open", body: body, vault: vaultID)
    }

    /// Percent-encodes a query value as `application/x-www-form-urlencoded` (what Java's URLEncoder writes).
    static func queryEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: "%20", with: "+")
    }

    static func pathEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
