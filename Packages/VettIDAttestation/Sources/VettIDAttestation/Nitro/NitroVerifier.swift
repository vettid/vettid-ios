import CryptoKit
import Foundation
import Security
import VettIDCrypto

/// PCR0–PCR2 as lowercase hex (VAULT-MESSAGING §11.2 step 2).
public struct Measurements: Equatable, Sendable {
    public let pcr0: String
    public let pcr1: String
    public let pcr2: String

    public init(pcr0: String, pcr1: String, pcr2: String) {
        self.pcr0 = pcr0
        self.pcr1 = pcr1
        self.pcr2 = pcr2
    }

    /// Any of PCR0–2 all zero: a debug-mode enclave.
    public var isDebug: Bool { [pcr0, pcr1, pcr2].contains { $0.allSatisfy { $0 == "0" } } }

    /// Constant-time comparison.
    public func matches(_ o: Measurements) -> Bool { Bytes.constantTimeEquals(Array(joined().utf8), Array(o.joined().utf8)) }

    /// The three PCRs joined, as the app stores an enrollment's expected measurements.
    public func joined() -> String { pcr0 + pcr1 + pcr2 }
}

/// A verified Nitro attestation document.
public struct NitroDocument: Sendable {
    public let moduleID: String
    public let timestamp: Date
    public let pcrs: [Int: [UInt8]]
    public let publicKey: [UInt8]?
    public let userData: [UInt8]?
    public let nonce: [UInt8]?

    public func pcrHex(_ i: Int) -> String { pcrs[i].map(Bytes.hex) ?? "" }

    public var measurements: Measurements { Measurements(pcr0: pcrHex(0), pcr1: pcrHex(1), pcr2: pcrHex(2)) }

    /// At most [maxAge] old and not more than [skew] in the future.
    public func checkFresh(now: Date, maxAge: TimeInterval, skew: TimeInterval) throws {
        guard timestamp <= now.addingTimeInterval(skew), now.timeIntervalSince(timestamp) <= maxAge else { throw AttestationError.stale }
    }

    public func checkUserData(_ want: [UInt8]) throws {
        guard Bytes.constantTimeEquals(userData ?? [], want) else { throw AttestationError.userData }
    }

    public func checkNonce(_ want: [UInt8]) throws {
        guard Bytes.constantTimeEquals(nonce ?? [], want) else { throw AttestationError.nonce }
    }
}

/// Verifies AWS Nitro Enclaves attestation documents (VAULT-MESSAGING §11.2, §11.3): a COSE_Sign1 (RFC 9052) signed
/// with ES384 by a certificate that chains to the pinned AWS Nitro root, evaluated at the document's own timestamp
/// (signing certificates are short-lived; the caller bounds the document's age with ``NitroDocument/checkFresh``).
///
/// As vettid-vault `vms/nitro` and vettid-android `NitroVerifier`: the root is pinned as the only trust anchor (not by
/// its name), the protected header must name ES384 and nothing else, the payload's PCR0–2 must be SHA-384 sized, and the
/// CBOR is parsed strictly. The chain is checked by the Security framework (basic X.509 policy, no network fetch,
/// no revocation: Nitro certificates carry neither CRL nor OCSP).
public struct NitroVerifier: Sendable {
    public static let maxDocument = 32 * 1024
    public static let pcrSize = 48
    static let maxCABundle = 8
    static let maxField = 1024
    static let maxPublicKey = 2048
    static let coseSign1Tag: UInt64 = 18
    static let coseHeaderAlg: Int64 = 1
    static let coseAlgES384: Int64 = -35
    static let es384SignatureSize = 96

    /// The trust anchors' DER (the pinned AWS root unless a test passes its own).
    private let roots: [[UInt8]]

    public init(roots: [[UInt8]] = [NitroRoot.der]) { self.roots = roots }

    public func verify(_ doc: [UInt8]) throws -> NitroDocument {
        guard !roots.isEmpty else { throw AttestationError.chain }
        guard !doc.isEmpty, doc.count <= Self.maxDocument else { throw AttestationError.format("attestation size") }
        guard case .array(let arr) = try CborValue.decode(doc).untag(Self.coseSign1Tag), arr.count == 4 else {
            throw AttestationError.format("COSE_Sign1")
        }
        guard case .bytes(let prot) = arr[0] else { throw AttestationError.format("protected header") }
        guard case .map = arr[1] else { throw AttestationError.format("unprotected header") }
        guard case .bytes(let payload) = arr[2] else { throw AttestationError.format("payload") }
        guard case .bytes(let sig) = arr[3], sig.count == Self.es384SignatureSize else { throw AttestationError.format("signature") }
        let ph = try CborValue.decode(prot)
        guard let entries = ph.entries else { throw AttestationError.format("protected header") }
        guard entries.count == 1, ph.lookup(int: Self.coseHeaderAlg) == .nint(UInt64(-1 - Self.coseAlgES384)) else {
            throw AttestationError.format("algorithm")
        }

        let parsed = try parsePayload(payload)
        let d = parsed.document
        let key = try verifyChain(leaf: parsed.leaf, bundle: parsed.bundle, at: d.timestamp)

        // Sig_structure = ["Signature1", protected, external_aad = h'', payload]
        let sigStructure = CborEncoder().array(4).text("Signature1").bytes(prot).bytes([]).bytes(payload).encoded()
        guard let signature = try? P384.Signing.ECDSASignature(rawRepresentation: sig),
              key.isValidSignature(signature, for: sigStructure)
        else { throw AttestationError.signature("attestation") }
        return d
    }

    /// Evaluates leaf → bundle (root first in the document, so reversed) against the pinned roots at [at] and returns
    /// the leaf's P-384 key.
    private func verifyChain(leaf: [UInt8], bundle: [[UInt8]], at: Date) throws -> P384.Signing.PublicKey {
        let anchors = try roots.map(Self.certificate)
        let intermediates = bundle.reversed().filter { c in !roots.contains(c) }
        let path = try ([leaf] + intermediates).map(Self.certificate)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(path as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetVerifyDate(trust, at as CFDate) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil)
        else { throw AttestationError.chain }
        guard let secKey = SecCertificateCopyKey(path[0]),
              let x963 = SecKeyCopyExternalRepresentation(secKey, nil) as Data?,
              let key = try? P384.Signing.PublicKey(x963Representation: x963)
        else { throw AttestationError.chain }
        return key
    }

    private struct Payload {
        let document: NitroDocument
        let leaf: [UInt8]
        let bundle: [[UInt8]]
    }

    private func parsePayload(_ b: [UInt8]) throws -> Payload {
        let m = try CborValue.decode(b)
        guard m.entries != nil else { throw AttestationError.format("payload") }
        let moduleID = try m.text(at: "module_id")
        guard !moduleID.isEmpty else { throw AttestationError.format("module_id") }
        guard try m.text(at: "digest") == "SHA384" else { throw AttestationError.format("digest") }
        let ts = try m.uint(at: "timestamp")
        guard ts != 0, ts <= 1 << 53 else { throw AttestationError.format("timestamp") }
        let pcrs = try Self.pcrs(m.lookup("pcrs"))
        let leaf = try m.bytes(at: "certificate")
        guard case .array(let bun)? = m.lookup("cabundle"), !bun.isEmpty, bun.count <= Self.maxCABundle else {
            throw AttestationError.format("cabundle")
        }
        let bundle = try bun.map { v -> [UInt8] in
            guard case .bytes(let c) = v else { throw AttestationError.format("cabundle") }
            return c
        }
        let d = NitroDocument(
            moduleID: moduleID,
            timestamp: Date(timeIntervalSince1970: Double(ts) / 1000),
            pcrs: pcrs,
            publicKey: try Self.optBytes(m, "public_key", Self.maxPublicKey),
            userData: try Self.optBytes(m, "user_data", Self.maxField),
            nonce: try Self.optBytes(m, "nonce", Self.maxField)
        )
        return Payload(document: d, leaf: leaf, bundle: bundle)
    }

    private static func pcrs(_ v: CborValue?) throws -> [Int: [UInt8]] {
        guard let entries = v?.entries, !entries.isEmpty, entries.count <= 32 else { throw AttestationError.format("pcrs") }
        var pcrs: [Int: [UInt8]] = [:]
        for e in entries {
            guard case .uint(let idx) = e.key else { throw AttestationError.format("pcr index") }
            guard case .bytes(let value) = e.value else { throw AttestationError.format("pcr value") }
            guard idx <= 31, [pcrSize, 32, 64].contains(value.count) else { throw AttestationError.format("pcr") }
            pcrs[Int(idx)] = value
        }
        for i in 0...2 where pcrs[i]?.count != pcrSize { throw AttestationError.format("pcr\(i)") }
        return pcrs
    }

    private static func optBytes(_ m: CborValue, _ key: String, _ max: Int) throws -> [UInt8]? {
        switch m.lookup(key) {
        case nil, .null?: return nil
        case .bytes(let b)?:
            guard b.count <= max else { throw AttestationError.format(key) }
            return b
        default: throw AttestationError.format(key)
        }
    }

    private static func certificate(_ der: [UInt8]) throws -> SecCertificate {
        guard let c = SecCertificateCreateWithData(nil, Data(der) as CFData) else { throw AttestationError.format("certificate") }
        return c
    }

    /// SHA-256 of a certificate's DER, lowercase hex (for pin checks).
    public static func fingerprint(_ der: [UInt8]) -> String { Bytes.hex(Bytes.sha256(der)) }
}
