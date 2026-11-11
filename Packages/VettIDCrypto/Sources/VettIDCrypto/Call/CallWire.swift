import Foundation

/// The wire crypto of call signalling (VAULT-MESSAGING §10.10), the Swift counterpart of vettid-vault's
/// `vms/callwire`, checked against its vectors (`calls.json`). Mirrors vettid-android `CallWire`.
///
/// The media key never passes through a vault: the calling device makes an ephemeral KEM key and keeps its private
/// half, the answering device encapsulates to it, and the vaults only pass `ek` and `enc` along. Each share is signed
/// by the device that made it and vouched for by that device's vault; the other device checks both signatures under
/// the connection's identity key before it uses the share.
public enum CallWire {
    public static let labelCall = "vettid/vms/2/call"
    public static let labelCallKey = "vettid/vms/2/call-key"
    public static let labelIce = "vettid/vms/2/ice"
    public static let labelShare = "vettid/vms/2/call-share"
    public static let labelVouch = "vettid/vms/2/call-vouch"
    public static let mediaSalt = "vettid-call-v1"
    public static let roleOffer = "offer"
    public static let roleAnswer = "answer"
    public static let mediaAudio = "audio"
    public static let mediaVideo = "video"

    /// `k_call`.
    public static let keySize = 32
    public static let maxIceServers = 8
    public static let maxUrls = 4
    public static let maxUrl = 512
    public static let maxIceField = 512
    public static let maxIceConfig = 8192
    public static let maxCallId = 64
    private static let iceConfigFormat: UInt64 = 1
    private static let maxExp: UInt64 = 1 << 40
    private static let schemes = ["stun:", "stuns:", "turn:", "turns:"]

    private static func callInfo(_ callId: String) throws -> [UInt8] {
        guard !callId.isEmpty else { throw CryptoError.key("call id") }
        return Array((labelCall + callId).utf8)
    }

    /// The calling device's ephemeral KEM key: its public half (`ek`, 1,216 bytes) goes into `call.start`.
    public static func newOfferKey() throws -> KemPrivateKey { try KemPrivateKey.generate() }

    /// `k_call = HKDF-SHA-256(ikm = K, salt = "vettid-call-v1", info = call_id, L = 32)`; [k] is wiped in place
    /// (the caller's own buffer: a wipe of a copy would leave the key where it was).
    static func mediaKey(_ k: inout [UInt8], _ callId: String) throws -> [UInt8] {
        defer { Bytes.wipe(&k) }
        return try Hkdf.derive(ikm: k, salt: Array(mediaSalt.utf8), info: Array(callId.utf8), length: keySize)
    }

    /// What the answering device gets: [enc] for `call.answer` and [kCall], which stays on the device.
    public struct Answered: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let enc: [UInt8]
        /// `var` so that its owner can wipe it in place (``Bytes/wipe(_:)``).
        public var kCall: [UInt8]

        public var description: String { "Answered([redacted])" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    /// Run by the answering device: `(enc, ctx) = SetupBaseS(ek, "vettid/vms/2/call" || call_id)`,
    /// `K = ctx.Export("vettid/vms/2/call-key", 32)`, and `k_call` from K.
    public static func answer(ek: [UInt8], callId: String) throws -> Answered {
        guard ek.count == Suite.ekSize else { throw CryptoError.key("call ek size") }
        let sender = try HpkeSender.setup(KemPublicKey.parse(ek), info: callInfo(callId))
        // The exporter secret `k_call` comes from does not outlive this call.
        defer { sender.destroy() }
        var k = try sender.export(labelCallKey, keySize)
        return Answered(enc: sender.enc, kCall: try mediaKey(&k, callId))
    }

    /// Run by the calling device on the answer's `enc` (1,120 bytes): the same `k_call`.
    public static func accept(offerKey: KemPrivateKey, enc: [UInt8], callId: String) throws -> [UInt8] {
        guard enc.count == Suite.encSize else { throw CryptoError.key("call enc size") }
        let r = try HpkeRecipient.setup(enc: enc, key: offerKey, info: callInfo(callId))
        defer { r.destroy() }
        var k = try r.export(labelCallKey, keySize)
        return try mediaKey(&k, callId)
    }

    /// The signed bytes of a share: `role || 0x00 || call_id || 0x00 || media || 0x00 || share`. For ``roleOffer`` the
    /// share is `ek` and [media] is `audio` or `video`; for ``roleAnswer`` it is `enc` and [media] is empty.
    public static func shareMessage(role: String, callId: String, media: String, share: [UInt8]) -> [UInt8] {
        Array(role.utf8) + [0] + Array(callId.utf8) + [0] + Array(media.utf8) + [0] + share
    }

    /// The device's signature over a share (`ek_sig`, `enc_sig`): Ed25519(device ik, "vettid/vms/2/call-share" || m).
    public static func signShare(deviceIk: Ed25519PrivateKey, message: [UInt8]) throws -> [UInt8] {
        try deviceIk.sign(label: labelShare, message)
    }

    /// What the signing device's vault signs: `device_ik (32) || m`.
    public static func vouchMessage(deviceIk: [UInt8], message: [UInt8]) -> [UInt8] { deviceIk + message }

    /// Checks a vouched share from the other side of a call: the device's signature under [deviceIk] and its vault's
    /// under [vaultIk] (the connection's identity key, `peer_ik`). A share that fails MUST NOT be used.
    public static func verifyShare(
        vaultIk: [UInt8], deviceIk: [UInt8], message: [UInt8], deviceSig: [UInt8], vaultSig: [UInt8]
    ) throws {
        // Both are checked whatever the first says, so that what fails is not told by the time it takes.
        let deviceOk = Ed25519.verify(deviceIk, label: labelShare, message, deviceSig)
        let vaultOk = Ed25519.verify(vaultIk, label: labelVouch, vouchMessage(deviceIk: deviceIk, message: message), vaultSig)
        guard deviceOk, vaultOk else { throw CryptoError.signature("call share") }
    }

    /// One entry of an ICE configuration; [username] and [credential] are both set or both nil.
    public struct IceServer: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let urls: [String]
        public let username: String?
        public let credential: String?

        public init(urls: [String], username: String? = nil, credential: String? = nil) {
            self.urls = urls
            self.username = username
            self.credential = credential
        }

        public var description: String { "IceServer(urls=\(urls), \(credential == nil ? "no credential" : "[redacted]"))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    /// The vault-signed ICE configuration of one call.
    public struct IceConfig: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let callId: String
        public let exp: Date
        public let servers: [IceServer]

        public init(callId: String, exp: Date, servers: [IceServer]) {
            self.callId = callId
            self.exp = exp
            self.servers = servers
        }

        public var description: String { "IceConfig(\(callId), \(servers.count) servers)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }

        var expSeconds: Int64 { Int64(exp.timeIntervalSince1970.rounded(.down)) }
    }

    private static func validUrl(_ u: String) -> Bool {
        u.utf8.count <= maxUrl && u.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
            && schemes.contains { u.hasPrefix($0) && u.count > $0.count }
    }

    private static func validField(_ s: String?) -> Bool {
        guard let s else { return true }
        return !s.isEmpty && s.utf8.count <= maxIceField && s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// The configuration's canonical bytes (members in the order shown in §10.10, no whitespace).
    public static func marshalIce(_ c: IceConfig) throws -> [UInt8] {
        let exp = c.expSeconds
        let bad = c.callId.isEmpty || c.callId.utf8.count > maxCallId || exp < 1 || UInt64(exp) > maxExp
            || c.servers.count > maxIceServers
            || c.servers.contains { s in
                s.urls.isEmpty || s.urls.count > maxUrls || !s.urls.allSatisfy(validUrl) || !validField(s.username)
                    || !validField(s.credential) || (s.username == nil) != (s.credential == nil)
            }
        if bad { throw CryptoError.format("ice config") }
        let servers = c.servers.map { s -> String in
            let b = JsonBuilder().raw("urls", JsonBuilder.array(s.urls.map(JsonBuilder.quote)))
            if let u = s.username, let cr = s.credential { b.string("username", u).string("credential", cr) }
            return b.build()
        }
        return JsonBuilder().uint("v", iceConfigFormat).string("call_id", c.callId).uint("exp", UInt64(exp))
            .raw("ice_servers", JsonBuilder.array(servers)).bytes()
    }

    /// Parses configuration bytes strictly: they must be in canonical form.
    public static func parseIce(_ config: [UInt8]) throws -> IceConfig {
        guard config.count <= maxIceConfig else { throw CryptoError.format("ice config size") }
        let o = try StrictJson.parseObject(config)
        _ = try o.uint("v", min: iceConfigFormat, max: iceConfigFormat)
        let servers = try o.array("ice_servers").map { raw -> IceServer in
            let s = try raw.asObject()
            let urls = try s.array("urls").map { try $0.asString() }
            let user = try s.optString("username")
            let cred = try s.optString("credential")
            return IceServer(
                urls: urls, username: user.flatMap { $0.isEmpty ? nil : $0 }, credential: cred.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        let exp = try o.uint("exp", min: 1, max: maxExp)
        let c = IceConfig(callId: try o.string("call_id"), exp: Date(timeIntervalSince1970: Double(exp)), servers: servers)
        guard try marshalIce(c) == config else { throw CryptoError.format("ice config not canonical") }
        return c
    }

    /// Run by an owner device on the ICE configuration its vault sent with a call: the signature under the vault's
    /// current identity key, the strict format, the call id and the expiry. A device MUST NOT use servers from any
    /// other source.
    public static func verifyIce(vaultIk: [UInt8], config: [UInt8], sig: [UInt8], callId: String, now: Date) throws -> IceConfig {
        try Ed25519.requireValid(vaultIk, label: labelIce, config, sig, what: "ice config")
        let c = try parseIce(config)
        guard c.callId == callId else { throw CryptoError.protocolViolation("ice config of another call") }
        guard now.timeIntervalSince1970 < Double(c.expSeconds) else { throw CryptoError.time("ice config expired") }
        return c
    }
}
