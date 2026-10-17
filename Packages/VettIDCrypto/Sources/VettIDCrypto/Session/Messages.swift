import Foundation

/// hs.init purposes (§6.2).
public enum Purpose: String, CaseIterable, Sendable {
    case app, desktop, agent, connection, rekey, reconnect

    public var isPairing: Bool { self == .app || self == .desktop || self == .agent }

    /// Whether a handshake of this purpose has a SAS, and so the commitment fields (§6.2, 0.10.3): app, desktop,
    /// agent and connection. Rekeys and reconnects carry none.
    public var hasSas: Bool { isPairing || self == .connection }

    public static func of(_ s: String) throws -> Purpose {
        guard let p = Purpose(rawValue: s) else { throw CryptoError.format("purpose") }
        return p
    }
}

/// A relay address `{url, mailbox, pk}` (§6.2). Mirrors vettid-android `RelayAddr`.
public struct RelayAddr: Sendable {
    public let url: String
    public let mailbox: String
    public let pk: [UInt8]

    public init(url: String, mailbox: String, pk: [UInt8]) {
        self.url = url
        self.mailbox = mailbox
        self.pk = pk
    }

    /// Validates: https base URL (http only for loopback), 32-byte key, mailbox derived from it.
    public func validate() throws {
        guard pk.count == Suite.ed25519PublicSize, mailbox == Mailbox.id(pk) else { throw CryptoError.format("relay address") }
        try Relay.validateURL(url)
    }

    func marshal() -> String {
        JsonBuilder().string("url", url).string("mailbox", mailbox).base64("pk", pk).build()
    }

    static func parse(_ o: JsonObject) throws -> RelayAddr {
        let r = RelayAddr(url: try o.string("url"), mailbox: try o.string("mailbox"), pk: try o.base64("pk", Suite.ed25519PublicSize))
        try r.validate()
        return r
    }
}

/// A principal `{ik, kem, relay}`: hs.init `from`, a bundle's `vault`. Mirrors vettid-android `Principal`.
public struct Principal: Sendable {
    public let ik: [UInt8]
    public let kem: KemPublicKey
    public let relay: RelayAddr

    public init(ik: [UInt8], kem: KemPublicKey, relay: RelayAddr) {
        self.ik = ik
        self.kem = kem
        self.relay = relay
    }

    func validate() throws {
        guard ik.count == Suite.ed25519PublicSize else { throw CryptoError.format("principal ik") }
        try relay.validate()
    }

    public func marshal() -> String {
        JsonBuilder().base64("ik", ik).base64("kem", kem.bytes).raw("relay", relay.marshal()).build()
    }

    public static func parse(_ o: JsonObject) throws -> Principal {
        Principal(
            ik: try o.base64("ik", Suite.ed25519PublicSize),
            kem: try KemPublicKey.parse(try o.base64("kem", Suite.ekSize)),
            relay: try RelayAddr.parse(try o.obj("relay"))
        )
    }
}

/// Relay mailbox ids (RELAY-PROTOCOL §3.2). Mirrors vettid-android `Mailbox`.
public enum Mailbox {
    public static let length = 26
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// lowercase base32(SHA-256(pk))[0:26].
    public static func id(_ pk: [UInt8]) -> String {
        var out = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for x in Bytes.sha256(pk) {
            buffer = buffer << 8 | UInt32(x)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        return String(out.prefix(length).map { Character(Unicode.Scalar($0)) })
    }
}

/// Relay URL and token shapes (§6.2). Mirrors vettid-android `Relay`.
public enum Relay {
    public static let maxURLLength = 256
    public static let maxTokenLength = 4096
    private static let tokenPrefix = "v4.public."

    /// An absolute `https` base URL without user info, query or fragment; `http` only for loopback hosts (development).
    public static func validateURL(_ s: String) throws {
        guard !s.isEmpty, s.utf8.count <= maxURLLength, !s.utf8.contains(where: { [0x20, 0x09, 0x0D, 0x0A].contains($0) }),
              let u = URLComponents(string: s),
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              let host = u.host, !host.isEmpty
        else { throw CryptoError.format("relay url") }
        switch u.scheme {
        case "https": break
        case "http": guard isLoopback(host) else { throw CryptoError.format("relay url") }
        default: throw CryptoError.format("relay url")
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" &&
            parts.allSatisfy { p in p.allSatisfy(\.isASCII) && Int(p).map { (0...255).contains($0) } == true }
    }

    /// The shape of a PASETO v4.public token (the relay verifies it).
    public static func isValidToken(_ s: String) -> Bool {
        s.utf8.count > tokenPrefix.utf8.count && s.utf8.count <= maxTokenLength && s.hasPrefix(tokenPrefix) &&
            s.utf8.dropFirst(tokenPrefix.utf8.count).allSatisfy(isTokenChar)
    }

    private static func isTokenChar(_ c: UInt8) -> Bool {
        (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || c == 0x2D || c == 0x5F || c == 0x2E
    }
}

/// Field limits of the handshake bodies.
enum HsLimits {
    static let maxCtxLength = 128
    static let maxRotations = 32
    static let maxOpaqueJSON = 16 * 1024
    /// n_I, n_R and sas_commit are 32 bytes (§6.2).
    static let sasNonceSize = 32
}

/// Token rules per purpose: required, optional or forbidden (§6.2). A connection handshake carries a request token and
/// no reconnect_token, which follows in connection.approved (0.10.3).
private enum TokenRule { case required, optional, forbidden }

private func tokenRules(_ p: Purpose) -> (TokenRule, TokenRule) {
    switch p {
    case .app, .desktop, .agent, .connection: (.required, .forbidden)
    case .reconnect: (.required, .required)
    case .rekey: (.optional, .optional)
    }
}

/// The commitment rule of §6.2 (0.10.3): a 32-byte value exactly for purposes with a SAS, absent otherwise.
private func checkSasField(_ p: Purpose, _ v: [UInt8]?, _ what: String) throws {
    if p.hasSas != (v != nil) || (v.map { $0.count != HsLimits.sasNonceSize } ?? false) { throw CryptoError.format(what) }
}

private func optSasField(_ o: JsonObject, _ name: String) throws -> [UInt8]? {
    o.has(name) ? try o.base64(name, HsLimits.sasNonceSize) : nil
}

private func checkTokenRule(_ rule: TokenRule, _ v: String?) throws {
    if v == nil, rule == .required { throw CryptoError.format("token required") }
    if v != nil, rule == .forbidden { throw CryptoError.format("token forbidden") }
    if let v, !Relay.isValidToken(v) { throw CryptoError.format("token") }
}

private func validCtx(_ s: String) -> Bool {
    !s.isEmpty && s.utf8.count <= HsLimits.maxCtxLength && s.utf8.allSatisfy { (0x21...0x7E).contains($0) }
}

private func optToken(_ o: JsonObject, _ name: String) throws -> String? {
    let t = try o.optString(name)
    if let t, t.isEmpty { throw CryptoError.format("token") }
    return t
}

private func parseRotations(_ o: JsonObject) throws -> [Rotation]? {
    guard let arr = try o.optArray("rotations") else { return nil }
    guard arr.count <= HsLimits.maxRotations else { throw CryptoError.format("rotations") }
    return try arr.map { try Rotation.parse(try $0.asObject()) }
}

private func marshalRotations(_ rs: [Rotation]) -> String { JsonBuilder.array(rs.map { $0.marshal() }) }

/// The hs.init body (§6.2). Mirrors vettid-android `HsInit`.
public final class HsInit: @unchecked Sendable {
    public let purpose: Purpose
    public let ctx: String
    public let from: Principal
    public let eph: KemPublicKey
    public let token: String?
    public let reconnectToken: String?
    public let suites: [Int]
    /// Self-asserted profile object JSON (§6.4), compacted.
    public let profile: [UInt8]?
    public let rotations: [Rotation]
    public let deviceAttest: DeviceAttest?
    /// The new app's app key (§6.2, §11.12, 0.15.0): the SPKI DER of a P-256 key, only in a transfer's `hs.init`
    /// (purpose app); absent otherwise.
    public let apiKey: [UInt8]?
    /// SHA-256("vettid/vms/2/sas-commit" || n_I), exactly for purposes with a SAS (§6.2, §6.3, 0.10.3).
    public let sasCommit: [UInt8]?
    private let lock = NSLock()
    private var unlockSecretBytes: [UInt8]?

    /// An SPKI DER of a P-256 key is 91 bytes; anything far larger is not one.
    private static let maxAPIKey = 512
    private static let unlockSecretSize = 32

    public init(
        purpose: Purpose,
        ctx: String,
        from: Principal,
        eph: KemPublicKey,
        token: String? = nil,
        reconnectToken: String? = nil,
        suites: [Int] = [Suite.suite2],
        profile: [UInt8]? = nil,
        rotations: [Rotation] = [],
        deviceAttest: DeviceAttest? = nil,
        apiKey: [UInt8]? = nil,
        sasCommit: [UInt8]? = nil,
        unlockSecret: [UInt8]? = nil
    ) {
        self.purpose = purpose
        self.ctx = ctx
        self.from = from
        self.eph = eph
        self.token = token
        self.reconnectToken = reconnectToken
        self.suites = suites
        self.profile = profile
        self.rotations = rotations
        self.deviceAttest = deviceAttest
        self.apiKey = apiKey
        self.sasCommit = sasCommit
        unlockSecretBytes = unlockSecret
    }

    /// (0.33.0, release R) The new phone's unlock secret, 32 bytes, only in a transfer's `hs.init` (§6.2, §11.14.10).
    public var unlockSecret: [UInt8]? { lock.withLock { unlockSecretBytes } }

    /// Zeroes this message's copy of the unlock secret (the initiator, after ``marshal()``).
    public func wipeUnlockSecret() {
        lock.withLock {
            if var s = unlockSecretBytes { Bytes.wipe(&s) }
            unlockSecretBytes = nil
        }
    }

    func validate() throws {
        guard validCtx(ctx) else { throw CryptoError.format("ctx") }
        try from.validate()
        if eph == from.kem { throw CryptoError.format("eph equals static kem") }
        let (tr, rr) = tokenRules(purpose)
        try checkTokenRule(tr, token)
        try checkTokenRule(rr, reconnectToken)
        try Suite.validateOffer(suites)
        if profile != nil, !(purpose.isPairing || purpose == .connection) { throw CryptoError.format("profile") }
        if !rotations.isEmpty, purpose != .reconnect { throw CryptoError.format("rotations") }
        if rotations.count > HsLimits.maxRotations { throw CryptoError.format("rotations") }
        if deviceAttest != nil, purpose != .app { throw CryptoError.format("device_attest") }
        if let apiKey, purpose != .app || apiKey.isEmpty || apiKey.count > Self.maxAPIKey { throw CryptoError.format("api_key") }
        try checkSasField(purpose, sasCommit, "sas_commit")
        if let s = unlockSecret, purpose != .app || apiKey == nil || s.count != Self.unlockSecretSize {
            throw CryptoError.format("unlock_secret")
        }
    }

    public func marshal() throws -> [UInt8] {
        try validate()
        let b = JsonBuilder()
            .string("purpose", purpose.rawValue)
            .string("ctx", ctx)
            .raw("from", from.marshal())
            .base64("eph", eph.bytes)
        if let token { b.string("token", token) }
        if let reconnectToken { b.string("reconnect_token", reconnectToken) }
        b.raw("suites", "[" + suites.map(String.init).joined(separator: ",") + "]")
        if let profile {
            let c = try StrictJson.compactObject(profile)
            guard c.count <= HsLimits.maxOpaqueJSON else { throw CryptoError.format("profile") }
            b.raw("profile", c)
        }
        if !rotations.isEmpty { b.raw("rotations", marshalRotations(rotations)) }
        if let deviceAttest { b.raw("device_attest", deviceAttest.marshal()) }
        if let apiKey { b.base64("api_key", apiKey) }
        if let s = unlockSecret { b.base64("unlock_secret", s) }
        if let sasCommit { b.base64("sas_commit", sasCommit) }
        return b.bytes()
    }

    public static func parse(_ body: [UInt8]) throws -> HsInit {
        let o = try StrictJson.parseObject(body)
        let purpose = try Purpose.of(try o.string("purpose"))
        let arr = try o.array("suites")
        guard !arr.isEmpty, arr.count <= Suite.maxOffer else { throw CryptoError.format("suites") }
        let profile = try o.optObj("profile").map { p -> [UInt8] in
            let raw = Array(p.raw.utf8)
            guard raw.count <= HsLimits.maxOpaqueJSON else { throw CryptoError.format("profile") }
            return try StrictJson.compactObject(raw)
        }
        let rotations = try parseRotations(o)
        if rotations != nil, purpose != .reconnect { throw CryptoError.format("rotations") }
        let parsed = HsInit(
            purpose: purpose,
            ctx: try o.string("ctx"),
            from: try Principal.parse(try o.obj("from")),
            eph: try KemPublicKey.parse(try o.base64("eph", Suite.ekSize)),
            token: try optToken(o, "token"),
            reconnectToken: try optToken(o, "reconnect_token"),
            suites: try arr.map { Int(try $0.asUint(min: 0, max: 255)) },
            profile: profile,
            rotations: rotations ?? [],
            deviceAttest: try o.optObj("device_attest").map(DeviceAttest.parse),
            apiKey: o.has("api_key") ? try o.base64("api_key") : nil,
            sasCommit: try optSasField(o, "sas_commit"),
            unlockSecret: o.has("unlock_secret") ? try o.base64("unlock_secret", unlockSecretSize) : nil
        )
        try parsed.validate()
        return parsed
    }
}

/// The hs.resp body (§6.2). Mirrors vettid-android `HsResp`.
public struct HsResp: Sendable {
    public let token: String?
    public let reconnectToken: String?
    public let suite: Int
    public let rotations: [Rotation]
    public let sig: [UInt8]
    /// n_R, exactly for purposes with a SAS (0.10.3).
    public let sasNonce: [UInt8]?

    public init(token: String?, reconnectToken: String?, suite: Int, rotations: [Rotation], sig: [UInt8], sasNonce: [UInt8]? = nil) {
        self.token = token
        self.reconnectToken = reconnectToken
        self.suite = suite
        self.rotations = rotations
        self.sig = sig
        self.sasNonce = sasNonce
    }

    func validate(_ p: Purpose) throws {
        let (tr, rr) = tokenRules(p)
        try checkTokenRule(tr, token)
        try checkTokenRule(rr, reconnectToken)
        guard (0...255).contains(suite), sig.count == Suite.ed25519SignatureSize else { throw CryptoError.format("hs.resp") }
        if !rotations.isEmpty, p != .reconnect { throw CryptoError.format("rotations") }
        if rotations.count > HsLimits.maxRotations { throw CryptoError.format("rotations") }
        try checkSasField(p, sasNonce, "sas_nonce")
    }

    public func marshal(_ p: Purpose) throws -> [UInt8] {
        try validate(p)
        let b = JsonBuilder()
        if let token { b.string("token", token) }
        if let reconnectToken { b.string("reconnect_token", reconnectToken) }
        b.uint("suite", UInt64(suite))
        if !rotations.isEmpty { b.raw("rotations", marshalRotations(rotations)) }
        if let sasNonce { b.base64("sas_nonce", sasNonce) }
        b.base64("sig", sig)
        return b.bytes()
    }

    public static func parse(_ body: [UInt8], _ p: Purpose) throws -> HsResp {
        let o = try StrictJson.parseObject(body)
        let rotations = try parseRotations(o)
        if rotations != nil, p != .reconnect { throw CryptoError.format("rotations") }
        let r = HsResp(
            token: try optToken(o, "token"),
            reconnectToken: try optToken(o, "reconnect_token"),
            suite: Int(try o.uint("suite", min: 0, max: 255)),
            rotations: rotations ?? [],
            sig: try o.base64("sig", Suite.ed25519SignatureSize),
            sasNonce: try optSasField(o, "sas_nonce")
        )
        try r.validate(p)
        return r
    }
}

/// The hs.fin body `{sig, sas_nonce?}` (§6.2): `sas_nonce` reveals n_I for purposes with a SAS (0.10.3).
/// Mirrors vettid-android `HsFin`.
public struct HsFin: Sendable {
    public let sig: [UInt8]
    public let sasNonce: [UInt8]?

    public init(sig: [UInt8], sasNonce: [UInt8]? = nil) {
        self.sig = sig
        self.sasNonce = sasNonce
    }

    public func marshal(_ p: Purpose) throws -> [UInt8] {
        guard sig.count == Suite.ed25519SignatureSize else { throw CryptoError.format("hs.fin") }
        try checkSasField(p, sasNonce, "sas_nonce")
        let b = JsonBuilder().base64("sig", sig)
        if let sasNonce { b.base64("sas_nonce", sasNonce) }
        return b.bytes()
    }

    public static func parse(_ body: [UInt8], _ p: Purpose) throws -> HsFin {
        let o = try StrictJson.parseObject(body)
        let f = HsFin(sig: try o.base64("sig", Suite.ed25519SignatureSize), sasNonce: try optSasField(o, "sas_nonce"))
        try checkSasField(p, f.sasNonce, "sas_nonce")
        return f
    }
}

/// hs.* inner types.
public enum HsTypes {
    public static let initType = "hs.init"
    public static let resp = "hs.resp"
    public static let fin = "hs.fin"
}

/// Constant-time check that a relay key equals the one on record (§6.3).
public func checkSender(_ collectSender: [UInt8], _ recordRelayKey: [UInt8]) throws {
    guard Ed25519.equalPublic(collectSender, recordRelayKey) else { throw CryptoError.protocolViolation("relay sender") }
}
