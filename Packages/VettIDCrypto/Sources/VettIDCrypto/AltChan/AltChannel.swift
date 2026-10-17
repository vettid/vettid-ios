import Foundation

/// The pure crypto and wire helpers of the alternate channel (§11) that the §16 vectors pin: attestation user_data, the
/// device-attestation challenge, the unlock and release-approval signing strings, and sealed requests. Mirrors
/// vettid-android `AltChannel`.
public enum AltChannel {
    public static let typeEnroll = "vault.enroll"
    public static let typeUnlock = "vault.unlock"

    /// Every sealed result: a 4,096-byte padded inner in a sealed envelope (5,252 bytes).
    public static let resultEnvelopeSize = Envelope.overheadSealed + Padding.altChannel
    /// A sealed enroll or unlock request (13,444 bytes).
    public static let requestEnvelopeSize = Envelope.overheadSealed + Padding.altChannelRequest
    /// (0.33.0, release R) The phone's unlock secret (§11.14).
    public static let unlockSecretSize = 32

    /// user_data of an ETK descriptor's attestation: SHA-256("vettid/vms/2/etk" || descriptor) (§11.2).
    public static func etkUserData(_ descriptor: [UInt8]) -> [UInt8] { Bytes.labeledHash(Labels.etk, descriptor) }

    /// user_data of vault.enrolled's attestation: SHA-256("vettid/vms/2/vault" || vault_bundle) (§11.3).
    public static func vaultUserData(_ vaultBundle: [UInt8]) -> [UInt8] { Bytes.labeledHash(Labels.vault, vaultBundle) }

    /// The device-attestation challenge (§11.7): SHA-256("vettid/vms/2/devatt" || request_id || vault_id_or_empty || ts).
    /// The same challenge on Android and iOS (`clientDataHash` of an App Attest assertion).
    public static func devattChallenge(requestID: String, vaultID: String, ts: String) throws -> [UInt8] {
        guard Ulid.isValid(requestID), validVaultID(vaultID, allowEmpty: true) else { throw CryptoError.format("devatt field") }
        _ = try Timestamps.parseMillis(ts)
        return Bytes.labeledHash(Labels.devatt, Array(requestID.utf8), Array(vaultID.utf8), Array(ts.utf8))
    }

    /// 6–32 ASCII digits (VAULT-MESSAGING 0.10.1 §11.3).
    public static func isValidPin(_ p: String) -> Bool {
        (6...32).contains(p.utf8.count) && p.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }

    static func validVaultID(_ s: String, allowEmpty: Bool) -> Bool {
        s.isEmpty ? allowEmpty : s.utf8.count <= 128 && s.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// Inputs of the unlock signing string (§11.4).
    public struct UnlockFields: Sendable {
        public let userGuid: String
        public let vaultID: String
        public let requestID: String
        public let ts: String
        public let etkKid: Kid
        public let minStateSeq: UInt64
        public let minHeaderSeq: UInt64
        public let pin: String
        public let token: String
        /// hex(SHA-256(manifest bytes)): the request's manifest_sha256.
        public let manifestSHA256: String
        /// The release_update target, "" without one.
        public let toPcr0: String
        public let cancelRecovery: Bool
        /// (0.33.0, release R) The phone's unlock secret: the string ends with hex(SHA-256(unlock_secret)).
        public let unlockSecret: [UInt8]?

        public init(
            userGuid: String, vaultID: String, requestID: String, ts: String, etkKid: Kid,
            minStateSeq: UInt64, minHeaderSeq: UInt64, pin: String, token: String, manifestSHA256: String,
            toPcr0: String = "", cancelRecovery: Bool = false, unlockSecret: [UInt8]? = nil
        ) {
            self.userGuid = userGuid
            self.vaultID = vaultID
            self.requestID = requestID
            self.ts = ts
            self.etkKid = etkKid
            self.minStateSeq = minStateSeq
            self.minHeaderSeq = minHeaderSeq
            self.pin = pin
            self.token = token
            self.manifestSHA256 = manifestSHA256
            self.toPcr0 = toPcr0
            self.cancelRecovery = cancelRecovery
            self.unlockSecret = unlockSecret
        }
    }

    /// The string `sig` covers in vault.unlock (§11.4): 12 lines (13 with cancel_recovery, one more with release R's
    /// unlock secret) joined by "\n", no trailing newline, decimal integers, lowercase hex.
    public static func unlockSigningString(_ f: UnlockFields) throws -> String {
        guard validVaultID(f.userGuid, allowEmpty: false), validVaultID(f.vaultID, allowEmpty: false), Ulid.isValid(f.requestID) else {
            throw CryptoError.format("unlock field")
        }
        _ = try Timestamps.parseMillis(f.ts)
        guard !f.pin.isEmpty, !f.token.isEmpty, !(f.pin + f.token).utf8.contains(where: { $0 == 0x0D || $0 == 0x0A }) else {
            throw CryptoError.format("unlock field")
        }
        guard Bytes.isLowerHex(f.manifestSHA256, 64) else { throw CryptoError.format("unlock field") }
        if !f.toPcr0.isEmpty, !Bytes.isLowerHex(f.toPcr0, 96) { throw CryptoError.format("unlock field") }
        var lines = [
            Labels.unlock, f.userGuid, f.vaultID, f.requestID, f.ts, f.etkKid.description,
            String(f.minStateSeq), String(f.minHeaderSeq),
            Bytes.hex(Bytes.sha256(Array(f.pin.utf8))), Bytes.hex(Bytes.sha256(Array(f.token.utf8))),
            f.manifestSHA256, f.toPcr0,
        ]
        if f.cancelRecovery { lines.append("cancel_recovery") }
        if let s = f.unlockSecret {
            guard s.count == unlockSecretSize else { throw CryptoError.format("unlock field") }
            lines.append(Bytes.hex(Bytes.sha256(s)))
        }
        return lines.joined(separator: "\n")
    }

    /// The release-approval signing string (§11.10.3):
    /// label \n vault_id \n request_id \n from_pcr0 \n to_pcr0 \n to_release \n manifest_serial. One parameter per line.
    public static func approvalSigningString( // swiftlint:disable:this function_parameter_count
        vaultID: String, requestID: String, fromPcr0: String, toPcr0: String, toRelease: UInt64, serial: UInt64
    ) throws -> String {
        guard validVaultID(vaultID, allowEmpty: false), Ulid.isValid(requestID), Bytes.isLowerHex(fromPcr0, 96),
              Bytes.isLowerHex(toPcr0, 96), toRelease > 0, serial > 0
        else { throw CryptoError.format("approval field") }
        return [Labels.releaseApproval, vaultID, requestID, fromPcr0, toPcr0, String(toRelease), String(serial)].joined(separator: "\n")
    }

    /// Seals an enroll or unlock request to the ETK (§11.3, §11.4): inner id = request_id, sender_kid all-zero, padded
    /// to exactly 12,288 bytes.
    public static func sealRequest(etk: KemPublicKey, type: String, requestID: String, ts: Date, body: [UInt8]) throws -> [UInt8] {
        var json = try Inner(id: requestID, type: type, ts: ts, body: body).marshal(.sealed)
        var padded = try Padding.padFixed(json, Padding.altChannelRequest)
        defer {
            Bytes.wipe(&padded)
            Bytes.wipe(&json)
        }
        return try Envelope.sealSealed(etk, senderKid: Kid.anonymous, padded: padded).0
    }
}

/// The `vault.enroll` body (§11.3), members in spec order. Mirrors vettid-android `EnrollRequest`.
public final class EnrollRequest: @unchecked Sendable {
    public let userGuid: String
    public let requestID: String
    let nonce: [UInt8]
    public let pin: String
    let ik: [UInt8]
    public let kem: KemPublicKey
    public let relay: RelayAddr
    public let openToken: String
    public let name: String
    public let attest: DeviceAttest
    public let manifestSHA256: String
    public let manifestSerial: UInt64
    /// The app key (§11.3, §11.12, 0.15.0): SPKI DER of a P-256 key; required since 0.15.0, nil only for older vectors.
    let apiKey: [UInt8]?
    private let lock = NSLock()
    private var unlockSecret: [UInt8]?

    public init(
        userGuid: String, requestID: String, nonce: [UInt8], pin: String, ik: [UInt8], kem: KemPublicKey, relay: RelayAddr,
        openToken: String, name: String, attest: DeviceAttest, manifestSHA256: String, manifestSerial: UInt64,
        apiKey: [UInt8]? = nil, unlockSecret: [UInt8]? = nil
    ) {
        self.userGuid = userGuid
        self.requestID = requestID
        self.nonce = nonce
        self.pin = pin
        self.ik = ik
        self.kem = kem
        self.relay = relay
        self.openToken = openToken
        self.name = name
        self.attest = attest
        self.manifestSHA256 = manifestSHA256
        self.manifestSerial = manifestSerial
        self.apiKey = apiKey
        self.unlockSecret = unlockSecret
    }

    /// Zeroes this request's copy of the unlock secret (after ``marshal()``).
    public func wipe() {
        lock.withLock {
            if var s = unlockSecret { Bytes.wipe(&s) }
            unlockSecret = nil
        }
    }

    public func marshal() throws -> [UInt8] {
        guard nonce.count == 32, AltChannel.isValidPin(pin), Bytes.isLowerHex(manifestSHA256, 64), manifestSerial >= 1 else {
            throw CryptoError.format("enroll request")
        }
        let app = JsonBuilder()
            .base64("ik", ik)
            .base64("kem", kem.bytes)
            .raw("relay", JsonBuilder().string("url", relay.url).string("mailbox", relay.mailbox).base64("pk", relay.pk).build())
            .string("open_token", openToken)
            .string("name", name)
            .raw("device_attest", attest.marshal())
        if let apiKey { app.base64("api_key", apiKey) }
        let b = JsonBuilder()
            .string("user_guid", userGuid)
            .string("request_id", requestID)
            .base64("nonce", nonce)
            .string("pin", pin)
        if let s = lock.withLock({ unlockSecret }) { b.base64("unlock_secret", s) }
        return b.raw("app", app.build())
            .string("manifest_sha256", manifestSHA256)
            .uint("manifest_serial", manifestSerial)
            .bytes()
    }
}

/// The `vault.unlock` body (§11.4), members in spec order. Mirrors vettid-android `UnlockRequest`.
public final class UnlockRequest: @unchecked Sendable {
    /// `release_update` (§11.10.3).
    public struct ReleaseUpdate: Sendable {
        public let to: String
        public let toRelease: UInt64
        public let approval: DeviceAssertion

        public init(to: String, toRelease: UInt64, approval: DeviceAssertion) {
            self.to = to
            self.toRelease = toRelease
            self.approval = approval
        }
    }

    public let userGuid: String
    public let vaultID: String
    public let requestID: String
    let deviceIk: [UInt8]
    public let pin: String
    public let minStateSeq: UInt64
    public let minHeaderSeq: UInt64
    public let token: String
    public let assertion: DeviceAssertion
    public let manifestSHA256: String
    public let manifestSerial: UInt64
    public let update: ReleaseUpdate?
    public let cancelRecovery: Bool
    let sig: [UInt8]
    private let lock = NSLock()
    private var unlockSecret: [UInt8]?

    public init(
        userGuid: String, vaultID: String, requestID: String, deviceIk: [UInt8], pin: String,
        minStateSeq: UInt64, minHeaderSeq: UInt64, token: String, assertion: DeviceAssertion,
        manifestSHA256: String, manifestSerial: UInt64, update: ReleaseUpdate? = nil, cancelRecovery: Bool = false,
        sig: [UInt8], unlockSecret: [UInt8]? = nil
    ) {
        self.userGuid = userGuid
        self.vaultID = vaultID
        self.requestID = requestID
        self.deviceIk = deviceIk
        self.pin = pin
        self.minStateSeq = minStateSeq
        self.minHeaderSeq = minHeaderSeq
        self.token = token
        self.assertion = assertion
        self.manifestSHA256 = manifestSHA256
        self.manifestSerial = manifestSerial
        self.update = update
        self.cancelRecovery = cancelRecovery
        self.sig = sig
        self.unlockSecret = unlockSecret
    }

    /// Zeroes this request's copy of the unlock secret (after ``marshal()``).
    public func wipe() {
        lock.withLock {
            if var s = unlockSecret { Bytes.wipe(&s) }
            unlockSecret = nil
        }
    }

    public func marshal() throws -> [UInt8] {
        guard AltChannel.isValidPin(pin), Bytes.isLowerHex(manifestSHA256, 64), manifestSerial >= 1,
              sig.count == Suite.ed25519SignatureSize
        else { throw CryptoError.format("unlock request") }
        let b = JsonBuilder()
            .string("user_guid", userGuid)
            .string("vault_id", vaultID)
            .string("request_id", requestID)
            .base64("device_ik", deviceIk)
            .string("pin", pin)
        if let s = lock.withLock({ unlockSecret }) { b.base64("unlock_secret", s) }
        b.uint("min_state_seq", minStateSeq)
            .uint("min_header_seq", minHeaderSeq)
            .string("token", token)
            .raw("device_assertion", assertion.marshal())
            .string("manifest_sha256", manifestSHA256)
            .uint("manifest_serial", manifestSerial)
        if let update {
            b.raw(
                "release_update",
                JsonBuilder()
                    .string("to", update.to)
                    .uint("to_release", update.toRelease)
                    .raw("approval", update.approval.marshal())
                    .build()
            )
        }
        if cancelRecovery { b.bool("cancel_recovery", true) }
        return b.base64("sig", sig).bytes()
    }
}

/// The ETK descriptor (§11.2), parsed strictly from the exact served bytes. Mirrors vettid-android `Descriptor`.
public struct Descriptor: Sendable {
    public let instanceID: String
    public let kid: Kid
    public let etk: KemPublicKey
    /// PCR0 (96 lowercase hex).
    public let release: String
    public let notAfter: Date
    public let bytes: [UInt8]
    /// (0.34.0, release R) The release's capabilities (§11.10.9); empty for a release before R.
    public let capabilities: [String]

    private static let maxSize = 4096

    public static func isValidInstanceID(_ s: String) -> Bool {
        (1...48).contains(s.utf8.count) && s.utf8.allSatisfy {
            (0x61...0x7A).contains($0) || (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F || $0 == 0x2D
        }
    }

    /// A non-debug lowercase-hex SHA-384 PCR.
    public static func isValidPcr(_ s: String) -> Bool { Bytes.isLowerHex(s, 96) && s.contains { $0 != "0" } }

    public static func parse(_ b: [UInt8]) throws -> Descriptor {
        guard !b.isEmpty, b.count <= maxSize else { throw CryptoError.format("descriptor") }
        let o = try StrictJson.parseObject(b)
        _ = try o.uint("v", min: 1, max: 1)
        _ = try o.uint("suite", min: 2, max: 2)
        let instanceID = try o.string("instance_id")
        guard isValidInstanceID(instanceID) else { throw CryptoError.format("descriptor instance_id") }
        let kid = try Kid.parseHex(try o.string("kid"))
        let etk = try KemPublicKey.parse(try o.base64("etk", Suite.ekSize))
        guard etk.kid == kid else { throw CryptoError.format("descriptor kid") }
        let release = try o.string("release")
        guard isValidPcr(release) else { throw CryptoError.format("descriptor release") }
        return Descriptor(
            instanceID: instanceID, kid: kid, etk: etk, release: release,
            notAfter: try Timestamps.parseSeconds(try o.string("not_after")),
            bytes: b, capabilities: try Capabilities.parse(o)
        )
    }

    /// Writes a descriptor in §11.2 member order (tests and tooling); [capabilities] only when given (release R).
    public static func marshal(
        instanceID: String, etk: KemPublicKey, release: String, notAfter: Date, capabilities: [String]? = nil
    ) -> [UInt8] {
        let b = JsonBuilder()
            .uint("v", 1)
            .uint("suite", UInt64(Suite.suite2))
            .string("instance_id", instanceID)
            .string("kid", etk.kid.description)
            .string("etk", Base64s.encodeStd(etk.bytes))
            .string("release", release)
            .string("not_after", Timestamps.formatSeconds(notAfter))
        if let capabilities { Capabilities.write(b, capabilities) }
        return b.bytes()
    }
}
