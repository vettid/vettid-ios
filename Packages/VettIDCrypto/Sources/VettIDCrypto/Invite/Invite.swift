import Foundation

/// QR `t` kinds (§6.4): connection, app transfer, desktop, agent. Mirrors vettid-android `InviteKind`.
public enum InviteKind: CaseIterable, Sendable {
    case connection, app, desktop, agent

    public var qr: String {
        switch self {
        case .connection: "c"
        case .app: "p"
        case .desktop: "d"
        case .agent: "a"
        }
    }

    public var bundle: String {
        switch self {
        case .connection: "connection"
        case .app: "app"
        case .desktop: "desktop"
        case .agent: "agent"
        }
    }

    public static func ofQR(_ t: String) throws -> InviteKind {
        guard let k = allCases.first(where: { $0.qr == t }) else { throw CryptoError.format("qr kind") }
        return k
    }
}

/// The QR / link payload (§6.4), compact JSON with members in spec order; `h` and `k` and the link itself are
/// unpadded base64url. Mirrors vettid-android `InviteQr`.
public struct InviteQr: Sendable {
    public let kind: InviteKind
    public let relay: String
    public let claimID: String
    public let hash: [UInt8]
    public let key: [UInt8]
    public let exp: UInt64

    public static let version: UInt64 = 2
    public static let claimIDLength = 26
    private static let maxLink = 1024

    public init(kind: InviteKind, relay: String, claimID: String, hash: [UInt8], key: [UInt8], exp: UInt64) {
        self.kind = kind
        self.relay = relay
        self.claimID = claimID
        self.hash = hash
        self.key = key
        self.exp = exp
    }

    private static func validClaimID(_ s: String) -> Bool {
        s.utf8.count == claimIDLength && s.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x32...0x37).contains($0) }
    }

    private func validate() throws {
        try Relay.validateURL(relay)
        guard Self.validClaimID(claimID), hash.count == 32, key.count == Suite.keySize, exp > 0 else { throw CryptoError.format("qr") }
    }

    public func marshal() throws -> [UInt8] {
        try validate()
        return JsonBuilder()
            .uint("v", Self.version)
            .string("t", kind.qr)
            .string("r", relay)
            .string("c", claimID)
            .string("h", Base64s.encodeRawUrl(hash))
            .string("k", Base64s.encodeRawUrl(key))
            .uint("e", exp)
            .bytes()
    }

    public func link() throws -> String { Base64s.encodeRawUrl(try marshal()) }

    public static func parse(_ b: [UInt8]) throws -> InviteQr {
        let o = try StrictJson.parseObject(b)
        _ = try o.uint("v", min: version, max: version)
        let q = InviteQr(
            kind: try InviteKind.ofQR(try o.string("t")),
            relay: try o.string("r"),
            claimID: try o.string("c"),
            hash: try Base64s.decodeRawUrl(try o.string("h"), 32),
            key: try Base64s.decodeRawUrl(try o.string("k"), Suite.keySize),
            exp: try o.uint("e", min: 1, max: StrictJson.maxSafeInteger)
        )
        try q.validate()
        return q
    }

    public static func parseLink(_ s: String) throws -> InviteQr {
        let b = try Base64s.decodeRawUrl(s)
        guard b.count <= maxLink else { throw CryptoError.format("qr") }
        return try parse(b)
    }
}

/// The claim bundle (§6.4). Mirrors vettid-android `InviteBundle`.
public struct InviteBundle: Sendable {
    public let kind: InviteKind
    public let inviteID: String
    public let remote: Bool
    public let vault: Principal
    public let token: String
    /// Whole seconds.
    public let exp: Date
    public let hintName: String?
    /// (0.34.0, release R) A transfer bundle's (`app`) release capabilities (§6.4, §11.10.9), bound by the QR's `h`;
    /// nil when absent (a release before R). No other kind carries it.
    public let capabilities: [String]?

    public static let version: UInt64 = 1
    public static let maxHintName = 128

    public init(
        kind: InviteKind,
        inviteID: String,
        remote: Bool,
        vault: Principal,
        token: String,
        exp: Date,
        hintName: String? = nil,
        capabilities: [String]? = nil
    ) {
        self.kind = kind
        self.inviteID = inviteID
        self.remote = remote
        self.vault = vault
        self.token = token
        self.exp = exp
        self.hintName = hintName
        self.capabilities = capabilities
    }

    private func validate() throws {
        if remote, kind != .connection { throw CryptoError.format("bundle remote") }
        if capabilities != nil, kind != .app { throw CryptoError.format("bundle capabilities") }
        let wholeSeconds = exp.timeIntervalSince1970.rounded(.down) == exp.timeIntervalSince1970
        guard Ulid.isValid(inviteID), Relay.isValidToken(token), wholeSeconds else {
            throw CryptoError.format("bundle")
        }
        if let hintName, hintName.utf8.count > Self.maxHintName { throw CryptoError.format("bundle hint") }
        guard vault.ik.count == Suite.ed25519PublicSize else { throw CryptoError.format("bundle") }
        try vault.relay.validate()
    }

    public func marshal() throws -> [UInt8] {
        try validate()
        let b = JsonBuilder()
            .uint("v", Self.version)
            .uint("suite", UInt64(Suite.suite2))
            .string("kind", kind.bundle)
            .string("invite_id", inviteID)
            .bool("remote", remote)
            .raw("vault", vault.marshal())
            .string("token", token)
            .string("exp", Timestamps.formatSeconds(exp))
        if let capabilities { Capabilities.write(b, capabilities) }
        if let hintName, !hintName.isEmpty { b.raw("hint", JsonBuilder().string("name", hintName).build()) }
        return b.bytes()
    }

    public static func parse(_ raw: [UInt8]) throws -> InviteBundle {
        let o = try StrictJson.parseObject(raw)
        _ = try o.uint("v", min: version, max: version)
        try Suite.check(Int(try o.uint("suite", min: 0, max: 255)), pinned: 0)
        let kindWire = try o.string("kind")
        guard let kind = InviteKind.allCases.first(where: { $0.bundle == kindWire }) else { throw CryptoError.format("bundle kind") }
        let b = InviteBundle(
            kind: kind,
            inviteID: try o.string("invite_id"),
            remote: try o.bool("remote"),
            vault: try Principal.parse(try o.obj("vault")),
            token: try o.string("token"),
            exp: try Timestamps.parseSeconds(try o.string("exp")),
            hintName: try o.optObj("hint")?.optString("name"),
            capabilities: o.has(Capabilities.member) ? try Capabilities.parse(o) : nil
        )
        try b.validate()
        return b
    }

    /// A sealed bundle: the blob to upload, its key k_b and SHA-256(blob), the QR's `h`.
    public struct Sealed: Sendable {
        public let blob: [UInt8]
        public let key: [UInt8]
        public let hash: [UInt8]
    }

    /// Encrypts bundle JSON under a fresh k_b: `blob = nonce(24) || XChaCha20-Poly1305(k_b, nonce,
    /// "vettid/vms/2/bundle", json)`.
    public static func seal(_ json: [UInt8]) throws -> Sealed {
        let kb = Randomness.bytes(Suite.keySize)
        let nonce = XChaCha20Poly1305.newNonce()
        let blob = nonce + (try XChaCha20Poly1305.seal(key: kb, nonce: nonce, aad: Array(Labels.bundle.utf8), plaintext: json))
        return Sealed(blob: blob, key: kb, hash: Bytes.sha256(blob))
    }

    /// Verifies a fetched claim blob against the QR: SHA-256(blob) = `h` in constant time before anything is
    /// decrypted; decrypts under `k`; the bundle's kind matches `t`, its exp equals `e`, and it has not expired.
    public static func open(_ blob: [UInt8], qr q: InviteQr, now: Date) throws -> InviteBundle {
        guard Bytes.constantTimeEquals(Bytes.sha256(blob), q.hash) else { throw CryptoError.protocolViolation("bundle commitment") }
        guard blob.count >= Suite.xNonceSize + Suite.tagSize else { throw CryptoError.decrypt }
        let pt = try XChaCha20Poly1305.open(
            key: q.key,
            nonce: Array(blob[0..<Suite.xNonceSize]),
            aad: Array(Labels.bundle.utf8),
            ciphertext: Array(blob[Suite.xNonceSize...])
        )
        let b = try parse(pt)
        guard b.kind == q.kind else { throw CryptoError.protocolViolation("bundle kind") }
        guard UInt64(b.exp.timeIntervalSince1970) == q.exp else { throw CryptoError.format("bundle exp") }
        guard now < b.exp else { throw CryptoError.time("invite expired") }
        return b
    }
}
