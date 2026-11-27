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
    /// (C2) Form 2's roles: the suites are signed with the share, and both members are named (VAULT-MESSAGING 0.88.16).
    public static let roleOffer2 = "offer2"
    public static let roleAnswer2 = "answer2"
    /// (C2) The salt of `k_confirm`.
    public static let labelConfirm = "vettid/vms/2/call-confirm"
    /// (C2) `confirm`'s length.
    public static let confirmSize = 32
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
        try mediaKey(&k, info: Array(callId.utf8))
    }

    /// `k_call` with the given HKDF [info]: `call_id` in form 1, `call_id || caller_ik || callee_ik` in form 2; [k] is
    /// wiped in place.
    private static func mediaKey(_ k: inout [UInt8], info: [UInt8]) throws -> [UInt8] {
        defer { Bytes.wipe(&k) }
        return try Hkdf.derive(ikm: k, salt: Array(mediaSalt.utf8), info: info, length: keySize)
    }

    /// (C2, VAULT-MESSAGING 0.88.16) The two members of a call as form 2 names them: the calling and the called member's
    /// vault identity keys (32 bytes each). They travel in no message. This device fills them in from its own records:
    /// its own vault's key (the one its ICE configurations verify under) and the connection's key as its vault gives it
    /// (`peer_ik`, checked against the connection, rule 6). The calling device fixes them when it places the call and
    /// uses the same for the answer.
    public struct Parties: Equatable, Sendable, CustomStringConvertible {
        public let caller: [UInt8]
        public let callee: [UInt8]

        public init(caller: [UInt8], callee: [UInt8]) throws {
            guard caller.count == Suite.ed25519PublicSize, callee.count == Suite.ed25519PublicSize else {
                throw CryptoError.key("call parties")
            }
            self.caller = caller
            self.callee = callee
        }

        public var description: String { "Parties" }
    }

    private static func partiesInfo(_ callId: String, _ p: Parties) -> [UInt8] { Array(callId.utf8) + p.caller + p.callee }

    /// (C2) ``answer(ek:callId:)`` for a form 2 call: `k_call` names both members, `info = call_id || caller_ik ||
    /// callee_ik`, so the two sides of a call that a third vault passes on derive different keys (the second lock).
    public static func answer2(ek: [UInt8], callId: String, parties: Parties) throws -> Answered {
        guard ek.count == Suite.ekSize else { throw CryptoError.key("call ek size") }
        let sender = try HpkeSender.setup(KemPublicKey.parse(ek), info: callInfo(callId))
        defer { sender.destroy() }
        var k = try sender.export(labelCallKey, keySize)
        return Answered(enc: sender.enc, kCall: try mediaKey(&k, info: partiesInfo(callId, parties)))
    }

    /// (C2) ``accept(offerKey:enc:callId:)`` for a form 2 call: the `k_call` of ``answer2(ek:callId:parties:)``, with
    /// the parties fixed when the call was placed.
    public static func accept2(offerKey: KemPrivateKey, enc: [UInt8], callId: String, parties: Parties) throws -> [UInt8] {
        guard enc.count == Suite.encSize else { throw CryptoError.key("call enc size") }
        let r = try HpkeRecipient.setup(enc: enc, key: offerKey, info: callInfo(callId))
        defer { r.destroy() }
        var k = try r.export(labelCallKey, keySize)
        return try mediaKey(&k, info: partiesInfo(callId, parties))
    }

    /// (C2) `list(x)`: the numbers in decimal without leading zeros, joined by one space.
    public static func suiteList(_ list: [Int]) -> String { list.map(String.init).joined(separator: " ") }

    // The six inputs of `m2` as VAULT-MESSAGING §10.10 lists them.
    // swiftlint:disable:next function_parameter_count
    private static func m2(
        _ role: String, _ callId: String, _ media: String, _ suites: String, _ parties: Parties, _ share: [UInt8]
    ) -> [UInt8] {
        Array(role.utf8) + [0] + Array(callId.utf8) + [0] + Array(media.utf8) + [0] + Array(suites.utf8) + [0]
            + parties.caller + parties.callee + share
    }

    /// (C2) A form 2 offer's signed bytes:
    /// `"offer2" || 0 || call_id || 0 || media || 0 || list(offered) || 0 || caller_ik || callee_ik || ek`.
    public static func offerMessage2(callId: String, media: String, offered: [Int], parties: Parties, ek: [UInt8]) -> [UInt8] {
        m2(roleOffer2, callId, media, suiteList(offered), parties, ek)
    }

    /// (C2) A form 2 answer's signed bytes: `"answer2" || 0 || call_id || 0 || "" || 0 || chosen || 0 || list(offered)
    /// || 0 || caller_ik || callee_ik || enc`; [offered] is the caller's list as the answering device read it.
    public static func answerMessage2(callId: String, chosen: Int, offered: [Int], parties: Parties, enc: [UInt8]) -> [UInt8] {
        m2(roleAnswer2, callId, "", "\(chosen)\u{0}\(suiteList(offered))", parties, enc)
    }

    /// (C2) `k_confirm = HKDF-SHA-256(ikm = k_call, salt = "vettid/vms/2/call-confirm", info = call_id, L = 32)`.
    public static func confirmKey(kCall: [UInt8], callId: String) throws -> [UInt8] {
        guard kCall.count == keySize else { throw CryptoError.key("k_call size") }
        guard !callId.isEmpty else { throw CryptoError.key("call id") }
        return try Hkdf.derive(ikm: kCall, salt: Array(labelConfirm.utf8), info: Array(callId.utf8), length: keySize)
    }

    /// (C2) `confirm = HMAC-SHA-256(k_confirm, chosen || 0x00 || list(offered) || 0x00 || call_id || caller_ik ||
    /// callee_ik)`, computed by the answering device.
    public static func confirm(kConfirm: [UInt8], chosen: Int, offered: [Int], callId: String, parties: Parties) -> [UInt8] {
        hmacSHA256(
            key: kConfirm, Array("\(chosen)\u{0}\(suiteList(offered))\u{0}\(callId)".utf8), parties.caller, parties.callee
        )
    }

    /// (C2) The calling device's check of `confirm`, in constant time, before it sets any key: the inputs of
    /// ``confirm(kConfirm:chosen:offered:callId:parties:)`` and the `confirm` received.
    public static func verifyConfirm( // swiftlint:disable:this function_parameter_count
        kConfirm: [UInt8], chosen: Int, offered: [Int], callId: String, parties: Parties, confirm got: [UInt8]?
    ) -> Bool {
        guard let got, got.count == confirmSize else { return false }
        let expected = confirm(kConfirm: kConfirm, chosen: chosen, offered: offered, callId: callId, parties: parties)
        return Bytes.constantTimeEquals(expected, got)
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
