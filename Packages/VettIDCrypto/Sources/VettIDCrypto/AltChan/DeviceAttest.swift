/// `device_attest` (enrollment §11.3, app pairing §6.7, transfer §6.7.1), in both forms of VAULT-MESSAGING §11.7:
///
/// ```
/// {"platform": "android", "chain": ["<b64 DER cert, leaf first>", ...]}           # 1–10 certificates
/// {"platform": "ios", "key_id": "<b64>", "attestation": "<b64 CBOR attestation object>"}
/// ```
///
/// The iPhone app builds the `ios` form (App Attest); the enclave verifies it. Unknown members are ignored; a missing
/// or mistyped member, or another platform, is refused. Mirrors vettid-android `DeviceAttest` (which builds the
/// `android` form only).
public enum DeviceAttest: Equatable, Sendable {
    case android(chain: [[UInt8]])
    case ios(keyID: [UInt8], attestation: [UInt8])

    public static let platformAndroid = "android"
    public static let platformIOS = "ios"
    public static let maxChain = 10
    static let maxBlob = 16 * 1024
    /// An App Attest attestation object is a few kilobytes of CBOR; the same bound as Android's chain, per item.
    static let maxAttestation = 16 * 1024

    public var platform: String {
        switch self {
        case .android: Self.platformAndroid
        case .ios: Self.platformIOS
        }
    }

    /// The App Attest key id of an iOS attestation; nil for Android.
    public var iosKeyID: [UInt8]? {
        if case .ios(let keyID, _) = self { return keyID }
        return nil
    }

    /// An Android chain, leaf first: 1–10 non-empty DER certificates of at most 16 KiB each.
    public static func androidChain(_ chain: [[UInt8]]) throws -> DeviceAttest {
        guard !chain.isEmpty, chain.count <= maxChain, chain.allSatisfy({ !$0.isEmpty && $0.count <= maxBlob }) else {
            throw CryptoError.format("device_attest chain")
        }
        return .android(chain: chain)
    }

    /// An iOS App Attest key id and attestation object, both non-empty.
    public static func iosAttestation(keyID: [UInt8], attestation: [UInt8]) throws -> DeviceAttest {
        guard !keyID.isEmpty, keyID.count <= 64, !attestation.isEmpty, attestation.count <= maxAttestation else {
            throw CryptoError.format("device_attest ios")
        }
        return .ios(keyID: keyID, attestation: attestation)
    }

    public func marshal() -> String {
        let b = JsonBuilder().string("platform", platform)
        switch self {
        case .android(let chain):
            b.raw("chain", JsonBuilder.array(chain.map { JsonBuilder.quote(Base64s.encodeStd($0)) }))
        case .ios(let keyID, let attestation):
            b.base64("key_id", keyID).base64("attestation", attestation)
        }
        return b.build()
    }

    /// Parses strictly (§11.7).
    public static func parse(_ o: JsonObject) throws -> DeviceAttest {
        switch try o.string("platform") {
        case platformAndroid:
            return try androidChain(try o.array("chain").map { try Base64s.decodeStd(try $0.asString()) })
        case platformIOS:
            return try iosAttestation(keyID: try o.base64("key_id"), attestation: try o.base64("attestation"))
        default:
            throw CryptoError.format("device_attest platform")
        }
    }

    public static func parse(_ raw: [UInt8]) throws -> DeviceAttest { try parse(try StrictJson.parseObject(raw)) }
}

/// A release's capabilities (VAULT-MESSAGING 0.34.0 §11.10.9): a constant of the vault's image, carried in its
/// attested ETK descriptor (§11.2) and in a transfer's bundle (§6.4). Lowercase names of 1 to 32 characters
/// `[a-z0-9_]`, unique, sorted, at most 32. A missing member is an empty list (a release before R); a malformed one is
/// refused like any malformed descriptor or bundle. Names the app does not know are kept and ignored. Mirrors
/// vettid-android `Capabilities`.
public enum Capabilities {
    /// §11.14: the phone-held unlock secret, the recovery open, none of the recovery of §11.11.5.
    public static let recoveryR = "recovery_r"
    /// The release offers recovery (listed only then).
    public static let recoveryOffered = "recovery_offered"

    public static let member = "capabilities"
    private static let maxNames = 32
    private static let maxName = 32

    public static func isValidName(_ s: String) -> Bool {
        (1...maxName).contains(s.utf8.count) && s.utf8.allSatisfy {
            (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F
        }
    }

    /// `capabilities` of [o]; empty when absent.
    public static func parse(_ o: JsonObject) throws -> [String] {
        guard let items = try o.optArray(member) else { return [] }
        let names = try items.map { try $0.asString() }
        let sortedUnique = Array(Set(names)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        guard names.count <= maxNames, names.allSatisfy(isValidName), names == sortedUnique else {
            throw CryptoError.format("capabilities")
        }
        return names
    }

    /// Writes `capabilities` (tests and tooling).
    @discardableResult
    public static func write(_ b: JsonBuilder, _ names: [String]) -> JsonBuilder {
        b.raw(member, JsonBuilder.array(names.map { JsonBuilder.quote($0) }))
    }
}

/// `device_assertion` of `vault.unlock` (§11.4) and the approval of a release update (§11.10.3), in both forms of
/// VAULT-MESSAGING §11.7:
///
/// ```
/// {"platform": "android", "sig": "<b64 DER ECDSA P-256 signature>", "chain": [...]}   # chain optional (0.27.0, §11.7.1)
/// {"platform": "ios", "assertion": "<b64 CBOR assertion>"}
/// ```
///
/// Android's `chain` is the certificate chain of the bound device key, leaf first, sent while the vault has not
/// recorded its signer; it is not part of any signing string, and an approval never has it. The iPhone app builds the
/// `ios` form: an App Attest assertion whose `clientDataHash` is the challenge (or SHA-256 of the approval string).
/// Mirrors vettid-android `DeviceAssertion` (which builds the `android` form only).
public enum DeviceAssertion: Equatable, Sendable {
    case android(sig: [UInt8], chain: [[UInt8]]?)
    case ios(assertion: [UInt8])

    public var platform: String {
        switch self {
        case .android: DeviceAttest.platformAndroid
        case .ios: DeviceAttest.platformIOS
        }
    }

    /// [chain]: nil for none; otherwise 1–10 DER certificates, leaf first (as ``DeviceAttest/androidChain(_:)``).
    public static func androidSignature(_ sig: [UInt8], chain: [[UInt8]]? = nil) throws -> DeviceAssertion {
        guard !sig.isEmpty, sig.count <= DeviceAttest.maxBlob else { throw CryptoError.format("device_assertion sig") }
        let badItem: ([UInt8]) -> Bool = { $0.isEmpty || $0.count > DeviceAttest.maxBlob }
        if let chain, chain.isEmpty || chain.count > DeviceAttest.maxChain || chain.contains(where: badItem) {
            throw CryptoError.format("device_assertion chain")
        }
        return .android(sig: sig, chain: chain)
    }

    /// An App Attest assertion (CBOR), non-empty.
    public static func iosAssertion(_ assertion: [UInt8]) throws -> DeviceAssertion {
        guard !assertion.isEmpty, assertion.count <= DeviceAttest.maxBlob else { throw CryptoError.format("device_assertion ios") }
        return .ios(assertion: assertion)
    }

    /// The same assertion without its chain (a request that would not fit with it).
    public func withoutChain() -> DeviceAssertion {
        if case .android(let sig, _) = self { return .android(sig: sig, chain: nil) }
        return self
    }

    public func marshal() -> String {
        let b = JsonBuilder().string("platform", platform)
        switch self {
        case .android(let sig, let chain):
            b.base64("sig", sig)
            if let chain { b.raw("chain", JsonBuilder.array(chain.map { JsonBuilder.quote(Base64s.encodeStd($0)) })) }
        case .ios(let assertion):
            b.base64("assertion", assertion)
        }
        return b.build()
    }

    public static func parse(_ o: JsonObject) throws -> DeviceAssertion {
        switch try o.string("platform") {
        case DeviceAttest.platformAndroid:
            let chain = o.has("chain") ? try o.array("chain").map { try Base64s.decodeStd(try $0.asString()) } : nil
            return try androidSignature(try o.base64("sig"), chain: chain)
        case DeviceAttest.platformIOS:
            return try iosAssertion(try o.base64("assertion"))
        default:
            throw CryptoError.format("device_assertion platform")
        }
    }
}
