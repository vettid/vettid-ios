import Foundation
import VettIDCrypto

/// A token's optional deposit cap (RELAY-PROTOCOL §5.2).
public struct Quota: Equatable, Sendable {
    public let msgs: UInt64?
    public let bytes: UInt64?

    public init(msgs: UInt64? = nil, bytes: UInt64? = nil) {
        self.msgs = msgs
        self.bytes = bytes
    }
}

/// Deposit-token claims (RELAY-PROTOCOL §5.2). Mirrors vettid-android `TokenClaims`.
public struct TokenClaims: Equatable, Sendable {
    public static let scopeDeposit = "deposit"
    public static let scopeDepositOpen = "deposit_open"
    public static let openSub = "*"
    public static let maxJtiLength = 128

    /// The issuing (recipient) mailbox id.
    public let iss: String
    /// The sender's base64 relay key, or `*` for an open token.
    public let sub: String
    /// The relay base URL, matched exactly.
    public let aud: String
    public let iat: Date
    public let exp: Date
    public let jti: String
    public let scope: String
    public let quota: Quota?

    public init(iss: String, sub: String, aud: String, iat: Date, exp: Date, jti: String, scope: String, quota: Quota? = nil) {
        self.iss = iss
        self.sub = sub
        self.aud = aud
        self.iat = iat
        self.exp = exp
        self.jti = jti
        self.scope = scope
        self.quota = quota
    }

    public var isOpen: Bool { scope == Self.scopeDepositOpen }

    /// The sender's key for a sender-bound token.
    public var subKey: [UInt8]? { isOpen ? nil : RelayAuth.decodeKey(sub) }

    /// Compact JSON in spec key order (iss, sub, aud, iat, exp, jti, scope[, quota]), as the relay's minter writes it.
    public func json() -> String {
        let b = JsonBuilder().string("iss", iss).string("sub", sub).string("aud", aud)
            .string("iat", Timestamps.formatSeconds(iat)).string("exp", Timestamps.formatSeconds(exp))
            .string("jti", jti).string("scope", scope)
        if let quota {
            let q = JsonBuilder()
            if let m = quota.msgs { q.uint("msgs", m) }
            if let n = quota.bytes { q.uint("bytes", n) }
            b.raw("quota", q.build())
        }
        return b.build()
    }

    /// Decodes and structurally validates claim JSON (unknown claims are ignored).
    public static func parse(_ m: [UInt8]) throws -> TokenClaims {
        guard let o = try? StrictJson.parseObject(m) else { throw TokenError.invalid }
        func str(_ n: String) throws -> String {
            guard case .string(_, let v)? = o[n] else { throw TokenError.invalid }
            return v
        }
        let c = TokenClaims(
            iss: try str("iss"), sub: try str("sub"), aud: try str("aud"), iat: try time(try str("iat")), exp: try time(try str("exp")),
            jti: try str("jti"), scope: try str("scope"), quota: try quota(o["quota"])
        )
        switch c.scope {
        case scopeDeposit: guard RelayAuth.decodeKey(c.sub) != nil else { throw TokenError.invalid }
        case scopeDepositOpen: guard c.sub == openSub else { throw TokenError.invalid }
        default: throw TokenError.invalid
        }
        guard !c.jti.isEmpty, c.jti.count <= maxJtiLength, RelayAuth.isValidMailboxID(c.iss) else { throw TokenError.invalid }
        return c
    }

    /// The optional quota object; a member that is not a whole number is left out, a negative one refused.
    private static func quota(_ v: JsonValue?) throws -> Quota? {
        guard let v else { return nil }
        guard case .object(let q) = v else { throw TokenError.invalid }
        func n(_ k: String) throws -> UInt64? {
            guard case .number(let raw)? = q[k], let x = Int64(raw) else { return nil }
            guard x >= 0 else { throw TokenError.invalid }
            return UInt64(x)
        }
        return Quota(msgs: try n("msgs"), bytes: try n("bytes"))
    }

    /// RFC 3339 with any offset and optional fractional seconds, as the relay accepts it.
    private static func time(_ s: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        throw TokenError.invalid
    }
}

/// Minting and checking deposit tokens (RELAY-PROTOCOL §5). The recipient mints with its own relay key; `iat` is
/// backdated by up to 60 s (§5.2, 0.4.0) so that a clock running ahead of the relay's does not make fresh tokens
/// `token_expired`; lifetimes run from the backdated `iat`. Mirrors vettid-android `DepositTokens`.
public enum DepositTokens {
    /// §5.2: issuers backdate `iat` by up to 60 s.
    public static let backdate: TimeInterval = 60
    /// Standing tokens: about 30 days (§5.2).
    public static let standingTTL: TimeInterval = 30 * 86400

    public static func mint(_ key: Ed25519PrivateKey, _ claims: TokenClaims) throws -> String {
        try Paseto.sign(key, Array(claims.json().utf8))
    }

    /// A sender-bound token for [senderB64] to deposit into [key]'s mailbox on the relay [audience].
    public static func mintStanding(
        _ key: Ed25519PrivateKey,
        sender senderB64: String,
        audience: String,
        now: Date,
        ttl: TimeInterval = standingTTL,
        jti: String? = nil,
        quota: Quota? = nil
    ) throws -> String {
        let iat = wholeSeconds(now).addingTimeInterval(-backdate)
        return try mint(key, TokenClaims(
            iss: RelayAuth.mailboxID(key.publicKey), sub: senderB64, aud: audience, iat: iat, exp: iat.addingTimeInterval(ttl),
            jti: jti ?? Ulid.new(now), scope: TokenClaims.scopeDeposit, quota: quota
        ))
    }

    /// A one-shot open token (§5.6): one deposit, signed with any key, which becomes the message's sender. `iat` is
    /// backdated by at most half the lifetime.
    public static func mintOpen(
        _ key: Ed25519PrivateKey, audience: String, now: Date, ttl: TimeInterval = 300, jti: String? = nil
    ) throws -> String {
        let iat = wholeSeconds(now).addingTimeInterval(-min(backdate, ttl / 2))
        return try mint(key, TokenClaims(
            iss: RelayAuth.mailboxID(key.publicKey), sub: TokenClaims.openSub, aud: audience, iat: iat, exp: iat.addingTimeInterval(ttl),
            jti: jti ?? Ulid.new(now), scope: TokenClaims.scopeDepositOpen
        ))
    }

    /// Verifies [token] against its issuer's relay key and parses its claims (§5.3 step 2).
    public static func verify(_ token: String, issuer: [UInt8]) throws -> TokenClaims {
        try TokenClaims.parse(try Paseto.verify(token, pub: issuer))
    }

    private static func wholeSeconds(_ t: Date) -> Date { Date(timeIntervalSince1970: t.timeIntervalSince1970.rounded(.down)) }
}
