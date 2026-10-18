import CryptoKit
import Foundation
import Testing
import VettIDAttestation
import VettIDCrypto

/// A file from the test resources (see Resources/SOURCE.md).
func resource(_ subdirectory: String, _ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: subdirectory), "missing \(name)")
    return Array(try Data(contentsOf: url))
}

/// A JSON object from the test resources.
func resourceObject(_ subdirectory: String, _ name: String) throws -> JsonObject {
    try StrictJson.parseObject(try resource(subdirectory, name))
}

/// The TEST-ONLY P-384 chain of `Resources/nitro/test-pki.json` (scripts/nitro-test-pki), shaped like AWS Nitro's:
/// root → intermediate → leaf, valid 2026-01-01 to 2036-01-01. The leaf's key is the public scalar 48 × 0x33.
struct TestPki {
    let root: [UInt8]
    let inter: [UInt8]
    let leaf: [UInt8]
    let leafSigner: P384.Signing.PrivateKey

    static func load() throws -> TestPki {
        let o = try resourceObject("nitro", "test-pki.json")
        return TestPki(
            root: try o.base64("root_der_b64"),
            inter: try o.base64("inter_der_b64"),
            leaf: try o.base64("leaf_der_b64"),
            leafSigner: try P384.Signing.PrivateKey(rawRepresentation: try Bytes.unhex(try o.string("leaf_scalar_hex")))
        )
    }
}

/// Builds COSE_Sign1 attestation documents as the NSM does, signed by the test PKI's leaf. Test only. Mirrors
/// vettid-android `FakeNsm`.
struct FakeNsm {
    let pki: TestPki
    var pcr0 = String(repeating: "ab", count: 48)
    var pcr1 = String(repeating: "11", count: 48)
    var pcr2 = String(repeating: "22", count: 48)

    func attest(
        at: Date,
        userData: [UInt8]? = nil,
        nonce: [UInt8]? = nil,
        publicKey: [UInt8]? = nil,
        alg: Int64 = -35,
        signer: P384.Signing.PrivateKey? = nil
    ) throws -> [UInt8] {
        let pcrs = [pcr0, pcr1, pcr2, String(repeating: "00", count: 48)]
        let p = CborEncoder().map(9)
            .text("module_id").text("i-test-enc0123")
            .text("digest").text("SHA384")
            .text("timestamp").uint(UInt64((at.timeIntervalSince1970 * 1000).rounded()))
            .text("pcrs").map(pcrs.count)
        for (i, h) in pcrs.enumerated() { p.uint(UInt64(i)).bytes(try Bytes.unhex(h)) }
        p.text("certificate").bytes(pki.leaf)
            .text("cabundle").array(2).bytes(pki.root).bytes(pki.inter)
        for (k, v) in [("public_key", publicKey), ("user_data", userData), ("nonce", nonce)] {
            if let v { p.text(k).bytes(v) } else { p.text(k).null() }
        }
        let payload = p.encoded()
        let prot = CborEncoder().map(1).int(1).int(alg).encoded()
        let sigStructure = CborEncoder().array(4).text("Signature1").bytes(prot).bytes([]).bytes(payload).encoded()
        let sig = try (signer ?? pki.leafSigner).signature(for: sigStructure).rawRepresentation
        return CborEncoder().tag(18).array(4).bytes(prot).map(0).bytes(payload).bytes(Array(sig)).encoded()
    }
}

/// Signed manifests for the manifest tests, under a fresh P-256 key. Test only.
struct ManifestSigner {
    let key = P256.Signing.PrivateKey()

    var manifestKey: ManifestKey {
        get throws { try ManifestKey(spki: Array(key.publicKey.derRepresentation)) }
    }

    static func entry(_ n: UInt64, _ pcr0: String, _ status: String, endsAt: String? = nil) -> String {
        let b = JsonBuilder().uint("release", n).string("pcr0", pcr0)
            .string("pcr1", String(repeating: "11", count: 48)).string("pcr2", String(repeating: "22", count: 48))
            .string("seal_key", "arn:aws:kms:us-east-1:000000000000:key/test-\(n)").string("status", status)
            .string("published_at", "2026-09-01T00:00:00Z")
        if let endsAt { b.string("ends_at", endsAt) }
        return b.string("notes", "https://vettid.org/releases/\(n)").build()
    }

    static func manifest(_ serial: UInt64, _ entries: String...) -> [UInt8] {
        JsonBuilder().uint("v", 1).uint("serial", serial).string("issued_at", "2026-10-02T12:00:00Z")
            .raw("releases", JsonBuilder.array(entries)).bytes()
    }

    func serve(_ m: [UInt8], with other: P256.Signing.PrivateKey? = nil, keyID: String? = nil) throws -> [UInt8] {
        let sig = try (other ?? key).signature(for: Array(ReleaseManifest.label.utf8) + [0] + m).rawRepresentation
        return JsonBuilder().base64("manifest", m).base64("sig", Array(sig)).string("key_id", try keyID ?? manifestKey.keyID).bytes()
    }
}

/// Expects [body] to throw an ``AttestationError`` of [kind] and returns it.
@discardableResult
func expectAttestation(
    _ kind: AttestationError.Kind,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) -> AttestationError? {
    do {
        try body()
        Issue.record("expected \(kind), nothing thrown. \(comment.map { "\($0)" } ?? "")", sourceLocation: sourceLocation)
    } catch let e as AttestationError {
        #expect(e.kind == kind, "\(e) \(comment.map { "\($0)" } ?? "")", sourceLocation: sourceLocation)
        return e
    } catch {
        Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
    }
    return nil
}

func hexRep(_ s: String) -> String { String(repeating: s, count: 48) }

func date(_ s: String) throws -> Date { try Timestamps.parseSeconds(s) }

/// The first index of [needle] in [hay].
func indexOf(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
    guard hay.count >= needle.count else { return nil }
    return (0...(hay.count - needle.count)).first { Array(hay[$0..<($0 + needle.count)]) == needle }
}
