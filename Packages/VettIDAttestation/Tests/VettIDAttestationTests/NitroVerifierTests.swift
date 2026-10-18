import CryptoKit
import Foundation
import Testing
@testable import VettIDAttestation
import VettIDCrypto

// Checks stay on one line each.
// swiftlint:disable line_length

/// The Nitro verifier: the round trip and rejections against the test PKI, the real AWS document of vettid-vault
/// `vms/nitro`, and CBOR strictness. Mirrors vettid-android `NitroVerifierTest`.
@Suite struct NitroVerifierTests {
    let t0: Date
    let nsm: FakeNsm
    let verifier: NitroVerifier

    init() throws {
        t0 = try date("2026-10-02T12:00:00Z")
        nsm = FakeNsm(pki: try TestPki.load())
        verifier = NitroVerifier(roots: [nsm.pki.root])
    }

    @Test func pinnedRootIsTheAwsFile() throws {
        #expect(NitroVerifier.fingerprint(NitroRoot.der) == NitroRoot.sha256Hex)
        #expect(SecCertificateCopySubjectSummary(NitroRoot.certificate) as String? == "aws.nitro-enclaves")
    }

    @Test func roundTrip() throws {
        let doc = try nsm.attest(at: t0, userData: Array("ud".utf8), nonce: Array("nonce".utf8), publicKey: Array("pk".utf8))
        let d = try verifier.verify(doc)
        #expect(d.timestamp == t0)
        #expect(d.moduleID == "i-test-enc0123")
        #expect(d.userData == Array("ud".utf8))
        #expect(d.publicKey == Array("pk".utf8))
        #expect(d.measurements.pcr0 == hexRep("ab"))
        #expect(!d.measurements.isDebug)
        try d.checkUserData(Array("ud".utf8))
        try d.checkNonce(Array("nonce".utf8))
        expectAttestation(.userData) { try d.checkUserData(Array("x".utf8)) }
        expectAttestation(.nonce) { try d.checkNonce(Array("nonce2".utf8)) }
        // Freshness: the past window and the future skew.
        let age: TimeInterval = 26 * 3600
        let skew: TimeInterval = 60
        try d.checkFresh(now: t0.addingTimeInterval(25 * 3600), maxAge: age, skew: skew)
        expectAttestation(.stale) { try d.checkFresh(now: t0.addingTimeInterval(27 * 3600), maxAge: age, skew: skew) }
        expectAttestation(.stale) { try d.checkFresh(now: t0.addingTimeInterval(-120), maxAge: age, skew: skew) }
        // Null optional fields.
        let bare = try verifier.verify(try nsm.attest(at: t0))
        #expect(bare.userData == nil && bare.nonce == nil)
        expectAttestation(.nonce) { try bare.checkNonce(Array("n".utf8)) }
    }

    @Test func rejections() throws {
        let doc = try nsm.attest(at: t0, userData: Array("ud".utf8))
        // The real AWS root does not anchor the test chain.
        expectAttestation(.chain) { _ = try NitroVerifier().verify(doc) }
        expectAttestation(.chain) { _ = try NitroVerifier(roots: []).verify(doc) }
        // Flipping bytes fails the signature, the chain or the parse: never a document that verifies.
        for i in stride(from: 60, to: doc.count - 200, by: 97) {
            var bad = doc
            bad[i] ^= 1
            #expect(throws: AttestationError.self, "flip at \(i)") { _ = try verifier.verify(bad) }
        }
        // Signed by a key outside the chain.
        expectAttestation(.signature) { _ = try verifier.verify(try nsm.attest(at: t0, signer: P384.Signing.PrivateKey())) }
        // Another algorithm in the protected header.
        expectAttestation(.format) { _ = try verifier.verify(try nsm.attest(at: t0, alg: -7)) }
        // A document from outside the leaf's validity (evaluated at the document's timestamp).
        expectAttestation(.chain) { _ = try verifier.verify(try nsm.attest(at: t0.addingTimeInterval(4000 * 86400))) }
        // Debug PCRs are reported.
        var dbg = nsm
        dbg.pcr0 = hexRep("00")
        #expect(try verifier.verify(try dbg.attest(at: t0)).measurements.isDebug)
        // Garbage, trailing bytes, an oversized document.
        expectAttestation(.format) { _ = try verifier.verify([1, 2, 3]) }
        expectAttestation(.format) { _ = try verifier.verify(doc + [0]) }
        expectAttestation(.format) { _ = try verifier.verify([UInt8](repeating: 0, count: NitroVerifier.maxDocument + 1)) }
    }

    /// A real NSM document (indefinite-length payload map, untagged, null nonce) verifies against the pinned AWS root at
    /// its own timestamp (vettid-vault `vms/nitro` fixture_test.go).
    @Test func realAwsDocument() throws {
        let b64 = try #require(String(bytes: try resource("nitro", "aws-attestation-2025-09-16.b64"), encoding: .utf8))
        let doc = try Base64s.decodeStd(b64.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(doc[10] == 0xBF)
        let d = try NitroVerifier().verify(doc)
        #expect(d.moduleID.hasPrefix("i-02447a481344e9ec0-enc"))
        #expect(d.pcrs.count == 16)
        #expect(!d.measurements.isDebug)
        #expect(d.userData?.count == 32)
        #expect(d.nonce == nil)
        #expect(!(d.publicKey ?? []).isEmpty)
        expectAttestation(.stale) { try d.checkFresh(now: d.timestamp.addingTimeInterval(365 * 86400), maxAge: 300, skew: 60) }
        var sig = doc
        sig[sig.count - 1] ^= 1
        expectAttestation(.signature) { _ = try NitroVerifier().verify(sig) }
        // A byte of the module id's value.
        let at = try #require(indexOf(doc, Array("module_id".utf8))) + 12
        var altered = doc
        altered[at] ^= 1
        #expect(throws: AttestationError.self) { _ = try NitroVerifier().verify(altered) }
        expectAttestation(.chain) { _ = try NitroVerifier(roots: [nsm.pki.root]).verify(doc) }
    }

    @Test func cborStrictness() throws {
        #expect(try CborValue.decode(CborEncoder().uint(500).encoded()) == .uint(500))
        #expect(try CborValue.decode(CborEncoder().int(-35).encoded()) == .nint(34))
        // Duplicate keys, floats, undefined, indefinite strings, trailing data, depth, a length past the end.
        let dup = CborEncoder().map(2).text("a").uint(1).text("a").uint(2).encoded()
        for bad: [UInt8] in [dup, [0xF9, 0, 0], [0xF7], [0x5F, 0xFF], [0x01, 0x02], [UInt8](repeating: 0x81, count: 20) + [0], [0x5A, 0x7F, 0, 0, 0]] {
            expectAttestation(.format, "\(Bytes.hex(bad))") { _ = try CborValue.decode(bad) }
        }
        // Invalid UTF-8 in a text string.
        expectAttestation(.format) { _ = try CborValue.decode([0x62, 0xC3, 0x28]) }
        // Indefinite maps and arrays, as the NSM emits.
        let m = try CborValue.decode([0xBF, 0x61, 0x61, 0x9F, 0x01, 0xFF, 0xFF])
        #expect(m.lookup("a") == .array([.uint(1)]))
    }

    @Test func cborDecodePrefixReadsExactlyOneItem() throws {
        let map = CborEncoder().map(1).text("k").uint(7).encoded()
        let (v, n) = try CborValue.decodePrefix(map + [0x01, 0x02])
        #expect(v.lookup("k") == .uint(7))
        #expect(n == map.count)
        #expect(try CborValue.decodePrefix(map).length == map.count)
        // The same rules as decode: empty, truncated, duplicate keys.
        let dup = CborEncoder().map(2).text("a").uint(1).text("a").uint(2).encoded()
        for bad: [UInt8] in [[], Array(map.dropLast()), dup + [0x00]] {
            expectAttestation(.format, "\(Bytes.hex(bad))") { _ = try CborValue.decodePrefix(bad) }
        }
    }
}

// swiftlint:enable line_length
