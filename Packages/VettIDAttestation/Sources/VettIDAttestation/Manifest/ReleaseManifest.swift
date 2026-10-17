import CryptoKit
import Foundation
import VettIDCrypto

/// Release statuses (VAULT-MESSAGING §11.10.1), fixed from release 1 on.
public enum ReleaseStatus: String, Sendable {
    case active, deprecated, retired, removed

    static func of(_ s: String) throws -> ReleaseStatus {
        guard let v = ReleaseStatus(rawValue: s) else { throw AttestationError.format("manifest status") }
        return v
    }
}

/// One manifest entry.
public struct Release: Equatable, Sendable {
    public let number: UInt64
    public let pcr0: String
    public let pcr1: String
    public let pcr2: String
    public let sealKey: String
    public let status: ReleaseStatus
    public let publishedAt: Date
    /// The release's end date (0.10.0, optional).
    public let endsAt: Date?
    public let notes: String

    public var measurements: Measurements { Measurements(pcr0: pcr0, pcr1: pcr1, pcr2: pcr2) }
}

/// VettID's signed release manifest (VAULT-MESSAGING §11.10.1, 0.10.0), parsed strictly from its exact bytes: compact
/// JSON with the §5.3 rules, at most 65,536 bytes, entries sorted by unique release number, unique PCR0s, lowercase
/// non-debug PCRs, known statuses, https notes and well-formed `ends_at` wherever present. As vettid-vault
/// `vms/manifest` and vettid-android `ReleaseManifest`.
public struct ReleaseManifest: Sendable {
    public static let label = "vettid/pcr-manifest/1"
    public static let maxBytes = 65_536
    public static let maxServed = 90_112
    static let maxSealKey = 256
    static let maxNotes = 1024

    public let serial: UInt64
    public let issuedAt: Date
    public let releases: [Release]
    /// The exact signed bytes.
    public let bytes: [UInt8]

    /// hex(SHA-256(manifest bytes)): a request's `manifest_sha256` and the bucket object name.
    public var sha256Hex: String { Bytes.hex(Bytes.sha256(bytes)) }

    public func byPcr0(_ pcr0: String) -> Release? {
        releases.first { Bytes.constantTimeEquals(Array($0.pcr0.utf8), Array(pcr0.utf8)) }
    }

    public func byNumber(_ n: UInt64) -> Release? { releases.first { $0.number == n } }

    /// The active entry with the highest release number.
    public func newest() -> Release? { releases.last { $0.status == .active } }

    /// Refuses a manifest older than one already seen (§11.10.1).
    public func checkSerial(seen: UInt64) throws {
        guard serial >= seen else { throw AttestationError.manifestSerial }
    }

    public static func parse(_ b: [UInt8]) throws -> ReleaseManifest {
        guard !b.isEmpty, b.count <= maxBytes else { throw AttestationError.format("manifest size") }
        do {
            let o = try StrictJson.parseObject(b)
            guard StrictJson.compact(b).count == b.count else { throw AttestationError.format("manifest not compact") }
            _ = try o.uint("v", min: 1, max: 1)
            let serial = try o.uint("serial", min: 1, max: StrictJson.maxSafeInteger)
            let issuedAt = try Timestamps.parseSeconds(try o.string("issued_at"))
            let arr = try o.array("releases")
            guard !arr.isEmpty else { throw AttestationError.format("manifest releases") }
            var out: [Release] = []
            var seen = Set<String>()
            for raw in arr {
                let r = try parseRelease(try raw.asObject())
                if let last = out.last, r.number <= last.number { throw AttestationError.format("manifest order") }
                guard seen.insert(r.pcr0).inserted else { throw AttestationError.format("manifest duplicate pcr0") }
                out.append(r)
            }
            return ReleaseManifest(serial: serial, issuedAt: issuedAt, releases: out, bytes: b)
        } catch is CryptoError {
            throw AttestationError.format("manifest")
        }
    }

    private static func parseRelease(_ e: JsonObject) throws -> Release {
        let r = Release(
            number: try e.uint("release", min: 1, max: StrictJson.maxSafeInteger),
            pcr0: try e.string("pcr0"),
            pcr1: try e.string("pcr1"),
            pcr2: try e.string("pcr2"),
            sealKey: try e.string("seal_key"),
            status: try ReleaseStatus.of(try e.string("status")),
            publishedAt: try Timestamps.parseSeconds(try e.string("published_at")),
            endsAt: try e.optString("ends_at").map { try Timestamps.parseSeconds($0) },
            notes: try e.string("notes")
        )
        guard Descriptor.isValidPcr(r.pcr0), Descriptor.isValidPcr(r.pcr1), Descriptor.isValidPcr(r.pcr2) else {
            throw AttestationError.format("manifest pcr")
        }
        guard validSealKey(r.sealKey) else { throw AttestationError.format("manifest seal_key") }
        guard validNotes(r.notes) else { throw AttestationError.format("manifest notes") }
        return r
    }

    /// 1 to 256 printable ASCII characters, no space (a KMS key ARN).
    private static func validSealKey(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return !b.isEmpty && b.count <= maxSealKey && b.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// An https URL with a host and no user info, at most 1,024 characters (vettid-vault `validNotes`).
    private static func validNotes(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= maxNotes, let u = URLComponents(string: s) else { return false }
        return u.scheme == "https" && !(u.host ?? "").isEmpty && u.user == nil && u.password == nil
    }

    /// SHA-256("vettid/pcr-manifest/1" || 0x00 || manifest): what the signature covers.
    public static func signedDigest(_ manifest: [UInt8]) -> [UInt8] { Bytes.sha256(Array(label.utf8), [0], manifest) }

    static func signedMessage(_ manifest: [UInt8]) -> [UInt8] { Array(label.utf8) + [0] + manifest }
}

/// The served document `{manifest: b64, sig: b64 r||s, key_id: 16 hex}` (§11.10.1).
public struct ServedManifest: Sendable {
    public let manifestBytes: [UInt8]
    public let sig: [UInt8]
    public let keyID: String

    public static func parse(_ raw: [UInt8]) throws -> ServedManifest {
        guard !raw.isEmpty, raw.count <= ReleaseManifest.maxServed else { throw AttestationError.format("served manifest size") }
        do {
            let o = try StrictJson.parseObject(raw)
            let m = try o.base64("manifest")
            guard !m.isEmpty, m.count <= ReleaseManifest.maxBytes else { throw AttestationError.format("served manifest") }
            let keyID = try o.string("key_id")
            guard Bytes.isLowerHex(keyID, 16) else { throw AttestationError.format("served manifest key_id") }
            return ServedManifest(manifestBytes: m, sig: try o.base64("sig", 64), keyID: keyID)
        } catch is CryptoError {
            throw AttestationError.format("served manifest")
        }
    }
}

/// A pinned manifest public key (ECDSA P-256), given as its SubjectPublicKeyInfo DER.
public struct ManifestKey: Sendable {
    /// hex(SHA-256(SPKI DER)[0:8]).
    public let keyID: String
    let publicKey: P256.Signing.PublicKey

    public init(spki: [UInt8]) throws {
        guard let k = try? P256.Signing.PublicKey(derRepresentation: spki) else { throw AttestationError.format("manifest key") }
        publicKey = k
        keyID = Bytes.hex(Array(Bytes.sha256(spki).prefix(8)))
    }

    public init(base64 spki: String) throws {
        guard let b = try? Base64s.decodeStd(spki) else { throw AttestationError.format("manifest key") }
        try self.init(spki: b)
    }
}

/// Verifies served manifests against the pinned keys (§11.10.1).
public struct ManifestVerifier: Sendable {
    private let pinned: [ManifestKey]

    public init(pinned: [ManifestKey]) { self.pinned = pinned }

    /// Checks the signature under the pinned key `key_id` selects, then parses the manifest strictly.
    public func verify(_ s: ServedManifest) throws -> ReleaseManifest {
        guard let key = pinned.first(where: { Bytes.constantTimeEquals(Array($0.keyID.utf8), Array(s.keyID.utf8)) }) else {
            throw AttestationError.manifestKey
        }
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: s.sig),
              key.publicKey.isValidSignature(sig, for: ReleaseManifest.signedMessage(s.manifestBytes))
        else { throw AttestationError.signature("manifest") }
        return try ReleaseManifest.parse(s.manifestBytes)
    }

    public func verify(_ served: [UInt8]) throws -> ReleaseManifest { try verify(try ServedManifest.parse(served)) }

    /// Verifies a served document that a request names by hash and serial (0.10.0): it parses, SHA-256 of its manifest
    /// equals [sha256Hex], its signature verifies under a pinned key, the manifest parses strictly, and its serial
    /// equals [serial].
    public func verifyByHash(_ doc: [UInt8], sha256Hex: String, serial: UInt64) throws -> ReleaseManifest {
        let s = try ServedManifest.parse(doc)
        let got = Bytes.hex(Bytes.sha256(s.manifestBytes))
        guard Bytes.isLowerHex(sha256Hex, 64), Bytes.constantTimeEquals(Array(got.utf8), Array(sha256Hex.utf8)) else {
            throw AttestationError.hash
        }
        let m = try verify(s)
        guard m.serial == serial else { throw AttestationError.hash }
        return m
    }
}
