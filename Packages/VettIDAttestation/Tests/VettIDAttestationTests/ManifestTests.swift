import CryptoKit
import Foundation
import Testing
@testable import VettIDAttestation
import VettIDCrypto

// Checks stay on one line each.
// swiftlint:disable line_length

/// The manifest parser and the release rules (VAULT-MESSAGING §11.10.1, §11.10.6). Mirrors vettid-android
/// `ManifestTest`.
@Suite struct ManifestTests {
    let signer = ManifestSigner()
    let verifier: ManifestVerifier
    let now: Date
    let r3 = ManifestSigner.entry(3, hexRep("ab"), "deprecated", endsAt: "2026-12-01T00:00:00Z")
    let r4 = ManifestSigner.entry(4, hexRep("cd"), "active")

    init() throws {
        verifier = ManifestVerifier(pinned: [try signer.manifestKey])
        now = try date("2026-10-04T12:00:00Z")
    }

    @Test func verifiesAndParses() throws {
        let m = try verifier.verify(try signer.serve(ManifestSigner.manifest(7, r3, r4)))
        #expect(m.serial == 7)
        #expect(m.byNumber(3)?.endsAt == (try date("2026-12-01T00:00:00Z")))
        #expect(m.byPcr0(hexRep("cd"))?.number == 4)
        #expect(m.byPcr0(hexRep("ef")) == nil)
        #expect(m.sha256Hex == Bytes.hex(Bytes.sha256(ManifestSigner.manifest(7, r3, r4))))
    }

    @Test func signatureAndKeyRules() throws {
        let m = ManifestSigner.manifest(7, r3, r4)
        expectAttestation(.manifestKey) { _ = try verifier.verify(try signer.serve(m, keyID: "0000000000000000")) }
        expectAttestation(.signature) { _ = try verifier.verify(try signer.serve(m, with: P256.Signing.PrivateKey())) }
        let served = try #require(String(bytes: try signer.serve(m), encoding: .utf8))
        let tampered = served.replacingOccurrences(of: Base64s.encodeStd(m), with: Base64s.encodeStd(ManifestSigner.manifest(8, r3, r4)))
        expectAttestation(.signature) { _ = try verifier.verify(Array(tampered.utf8)) }
        // A manifest signed by any other key fails closed under the production keys.
        expectAttestation(.manifestKey) { _ = try ManifestVerifier(pinned: ManifestKeys.production).verify(try signer.serve(m)) }
    }

    @Test func strictFormat() throws {
        func text(_ b: [UInt8]) -> String { String(bytes: b, encoding: .utf8) ?? "" }
        let bad: [[UInt8]] = [
            ManifestSigner.manifest(7, r4, r3), // not sorted
            ManifestSigner.manifest(7, r4, ManifestSigner.entry(5, hexRep("cd"), "active")), // duplicate pcr0
            ManifestSigner.manifest(7, ManifestSigner.entry(4, hexRep("00"), "active")), // debug pcr
            ManifestSigner.manifest(7, ManifestSigner.entry(4, hexRep("CD"), "active")), // upper-case hex
            ManifestSigner.manifest(7, ManifestSigner.entry(4, hexRep("cd"), "paused")), // unknown status
            ManifestSigner.manifest(7, ManifestSigner.entry(4, hexRep("cd"), "active", endsAt: "2026-12-01")), // malformed ends_at
            ManifestSigner.manifest(7, ManifestSigner.entry(4, hexRep("cd"), "active").replacingOccurrences(of: "https://", with: "http://")),
            ManifestSigner.manifest(7, ManifestSigner.entry(4, hexRep("cd"), "active").replacingOccurrences(of: "https://", with: "https://user@")),
            ManifestSigner.manifest(7), // no releases
            ManifestSigner.manifest(0, r4),
            Array(text(ManifestSigner.manifest(7, r4)).replacingOccurrences(of: ",\"serial\"", with: ", \"serial\"").utf8), // not compact
            Array(text(ManifestSigner.manifest(7, r4)).replacingOccurrences(of: "{\"v\":1", with: "{\"v\":1,\"v\":1").utf8), // duplicate member
        ]
        for m in bad {
            #expect(throws: AttestationError.self, "\(text(m).prefix(80))") { _ = try verifier.verify(try signer.serve(m)) }
        }
        // Unknown members are ignored (additive fields).
        let withFuture = text(ManifestSigner.manifest(7, r4)).replacingOccurrences(of: "\"v\":1,", with: "\"v\":1,\"future\":{\"x\":1},")
        #expect(try ReleaseManifest.parse(Array(withFuture.utf8)).serial == 7)
    }

    @Test func managerSerialAndReleaseRules() throws {
        let store = InMemoryReleaseStateStore()
        let mgr = ReleaseManifestManager(verifier: verifier, store: store)
        #expect(mgr.refreshDue(now: now))
        let m7 = try mgr.accept(try signer.serve(ManifestSigner.manifest(7, r3, r4)), now: now)
        #expect(store.highestSerial == 7)
        #expect(mgr.cached()?.serial == 7)
        #expect(!mgr.refreshDue(now: now.addingTimeInterval(3600)))
        #expect(mgr.refreshDue(now: now.addingTimeInterval(25 * 3600)))
        // The serial never goes back.
        expectAttestation(.manifestSerial) { _ = try mgr.accept(try signer.serve(ManifestSigner.manifest(6, r3, r4)), now: now) }
        #expect(store.highestSerial == 7)

        // Enrollment: active only.
        #expect(try mgr.checkEnroll(m7, pcr0: hexRep("cd")).number == 4)
        #expect(expectAttestation(.release) { _ = try mgr.checkEnroll(m7, pcr0: hexRep("ab")) } == .release("not active"))
        #expect(expectAttestation(.release) { _ = try mgr.checkEnroll(m7, pcr0: hexRep("ef")) } == .release("not listed", unknown: true))
        #expect(expectAttestation(.release) { _ = try mgr.decideUnlock(m7, pcr0: hexRep("ef")) } == .release("not listed", unknown: true))
        // A manifest's own failures are marked as the manifest's; an enclave document's are not.
        let ofManifest: [AttestationError] = [.signature("manifest"), .format("served manifest size"), .manifestKey, .manifestSerial, .hash]
        let allManifest = ofManifest.allSatisfy { $0.isManifest }
        #expect(allManifest)
        let ofEnclave: [AttestationError] = [.signature("attestation"), .format("COSE_Sign1"), .chain, .pcr("manifest"), .stale]
        let anyManifest = ofEnclave.contains { $0.isManifest }
        #expect(!anyManifest)

        // Unlock: the first unlock proceeds; deprecated shows end of life with the newest active release.
        #expect(try mgr.decideUnlock(m7, pcr0: hexRep("cd")) == .proceed(try #require(m7.byNumber(4))))
        guard case .endOfLife(_, let newest) = try mgr.decideUnlock(m7, pcr0: hexRep("ab")) else {
            Issue.record("end of life expected")
            return
        }
        #expect(newest?.number == 4)
        mgr.recordUnlocked(try #require(m7.byNumber(4)))
        // Never a PIN to an older release than the last one unlocked into.
        #expect(expectAttestation(.release) { _ = try mgr.decideUnlock(m7, pcr0: hexRep("ab")) } == .release("rollback"))
        // A newer listed release: tell the user first.
        let m8 = try mgr.accept(try signer.serve(ManifestSigner.manifest(8, r3, r4, ManifestSigner.entry(5, hexRep("ef"), "active"))), now: now)
        guard case .updated(let from, _) = try mgr.decideUnlock(m8, pcr0: hexRep("ef")) else {
            Issue.record("updated expected")
            return
        }
        #expect(from.number == 4)
        // Removed: the vault cannot be opened there.
        let m9 = try mgr.accept(
            try signer.serve(ManifestSigner.manifest(9, ManifestSigner.entry(4, hexRep("cd"), "removed"), ManifestSigner.entry(5, hexRep("ef"), "active"))),
            now: now
        )
        guard case .removed = try mgr.decideUnlock(m9, pcr0: hexRep("cd")) else {
            Issue.record("removed expected")
            return
        }
        // A cached document that no longer verifies is dropped.
        store.servedManifest = Array("{}".utf8)
        #expect(mgr.cached() == nil)
    }
}

/// The pinned keys and the manifests staging.vettid.org served. Mirrors vettid-android `ManifestKeysTest`.
@Suite struct ManifestKeysTests {
    /// Staging key A (vettid-vault `enclave/releasecfg/staging.json`), as the Staging and Debug builds pin it.
    static let stagingKeyA =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEok8gqeC5VcGx4KL+B5fL7UgENBXf+59RigkR0TZ0NqjiWM2VK6V1+paNoqRTBx7nXXN3L/2ehjsTb31GGVkEAw=="

    /// The production keys are exactly key A and key B (VAULT-RELEASES §6.1), as the production images pin them.
    @Test func productionKeyIDs() {
        #expect(ManifestKeys.production.map(\.keyID) == ["4353463f85c4012f", "1abd49da96970b6e"])
    }

    @Test func stagingKeyIDAndDisjointPins() throws {
        let staging = try ManifestKey(base64: Self.stagingKeyA)
        #expect(staging.keyID == "e9b3a403423120ac")
        #expect(!ManifestKeys.production.map(\.keyID).contains(staging.keyID))
    }

    /// The manifests staging.vettid.org served (serial 1, and serial 17 as of 2026-10-16), copied from vettid.org
    /// `vault/staging/pcr-manifest.json`: they verify under the staging pin, fail closed under the production pins, and
    /// the serial rule refuses going back from 17 to 1.
    @Test func servedStagingManifestsVerifyUnderTheStagingPinOnly() throws {
        let verifier = ManifestVerifier(pinned: [try ManifestKey(base64: Self.stagingKeyA)])
        let doc1 = try resource("manifest", "staging-pcr-manifest-serial1.json")
        let m1 = try verifier.verify(doc1)
        #expect(m1.serial == 1)
        let r1 = try #require(m1.byNumber(1))
        #expect(r1.status == .active)
        #expect(m1.byPcr0("cbaf7412603d1b54dad85c2a7769396c153d20c6f4a1c0f5a13341653352edee48ecbdc31615a058f50e2685b61bf8e5") == r1)
        expectAttestation(.manifestKey) { _ = try ManifestVerifier(pinned: ManifestKeys.production).verify(doc1) }

        let doc17 = try resource("manifest", "staging-pcr-manifest-serial17.json")
        let m17 = try verifier.verify(doc17)
        #expect(m17.serial == 17)
        #expect(m17.byNumber(1)?.status == .removed)
        #expect(m17.byNumber(1)?.endsAt != nil)
        #expect(m17.newest()?.number == 14)
        let mgr = ReleaseManifestManager(verifier: verifier, store: InMemoryReleaseStateStore())
        _ = try mgr.accept(doc17, now: Date())
        expectAttestation(.manifestSerial) { _ = try mgr.accept(doc1, now: Date()) }
    }
}

/// VAULT-MESSAGING §11.10 vectors (`release.json`, from vettid-vault): the manifest signature and key id, the 0.10.0
/// manifest-by-hash and the release-approval signature, checked as vettid-vault's verify_test.go does. Mirrors
/// vettid-android `ReleaseVectorsTest`, except that the RFC 6979 signatures are verified, not re-derived (CryptoKit
/// signs with fresh randomness); the test scalars are checked to give the vector's public keys instead.
@Suite struct ReleaseVectorsTests {
    let d: JsonObject
    let key: ManifestKey
    let verifier: ManifestVerifier

    init() throws {
        d = try resourceObject("vectors", "release.json")
        key = try ManifestKey(base64: try d.string("manifest_key_spki_b64"))
        verifier = ManifestVerifier(pinned: [key])
    }

    @Test func manifestSignature() throws {
        let mb = Array(try d.string("manifest").utf8)
        #expect(mb.count == 1060)
        #expect(try d.uint("manifest_len", min: 0, max: 1 << 20) == 1060)
        #expect(Bytes.hex(Bytes.sha256(mb)) == (try d.string("manifest_sha256_hex")))
        #expect(Bytes.hex(ReleaseManifest.signedDigest(mb)) == (try d.string("manifest_signed_digest_hex")))
        #expect(key.keyID == (try d.string("manifest_key_id")))
        let scalar = try P256.Signing.PrivateKey(rawRepresentation: try Bytes.unhex(try d.string("manifest_key_scalar_hex")))
        #expect(Base64s.encodeStd(Array(scalar.publicKey.derRepresentation)) == (try d.string("manifest_key_spki_b64")))
        let m = try verifier.verify(Array(try d.string("served").utf8))
        #expect(m.serial == 7)
        #expect(m.releases.map(\.status) == [.deprecated, .active])
        #expect(m.newest()?.number == 4)
        #expect(m.sha256Hex == (try d.string("manifest_sha256_hex")))
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: try Base64s.decodeStd(try d.string("manifest_sig_b64")))
        #expect(scalar.publicKey.isValidSignature(sig, for: Array(ReleaseManifest.label.utf8) + [0] + mb))
    }

    @Test func manifest0100ByHash() throws {
        let n = try d.obj("manifest_0_10_0")
        let nb = Array(try n.string("manifest").utf8)
        #expect(UInt64(nb.count) == (try n.uint("manifest_len", min: 0, max: 1 << 20)))
        let hash = try n.string("manifest_sha256_hex")
        #expect(Bytes.hex(Bytes.sha256(nb)) == hash)
        #expect(try n.string("object_key") == "manifests/\(hash).json")
        #expect(Bytes.hex(ReleaseManifest.signedDigest(nb)) == (try n.string("manifest_signed_digest_hex")))
        let served = Array(try n.string("served").utf8)
        let m = try verifier.verifyByHash(served, sha256Hex: hash, serial: 8)
        #expect(m.releases.map(\.status) == [.removed, .retired, .active])
        #expect(m.releases[0].endsAt != nil)
        #expect(m.releases[2].endsAt == nil)
        #expect(try n.string("manifest").contains(#""status":"removed","published_at":"2025-09-01T00:00:00Z","ends_at":"2026-09-01T00:00:00Z","notes""#))
        // The wrong hash or serial is refused.
        expectAttestation(.hash) { _ = try verifier.verifyByHash(served, sha256Hex: try d.string("manifest_sha256_hex"), serial: 8) }
        expectAttestation(.hash) { _ = try verifier.verifyByHash(served, sha256Hex: hash, serial: 7) }
    }

    @Test func approvalSignature() throws {
        let a = try d.obj("approval")
        let msg = Array(try a.string("signing_string").utf8)
        #expect(Bytes.hex(Bytes.sha256(msg)) == (try a.string("signing_string_sha256_hex")))
        let pub = try P256.Signing.PublicKey(derRepresentation: try Base64s.decodeStd(try a.string("device_key_spki_b64")))
        let sig = try P256.Signing.ECDSASignature(derRepresentation: try Base64s.decodeStd(try a.string("sig_der_b64")))
        #expect(pub.isValidSignature(sig, for: msg))
        let scalar = try P256.Signing.PrivateKey(rawRepresentation: try Bytes.unhex(try a.string("device_key_scalar_hex")))
        #expect(scalar.publicKey.derRepresentation == pub.derRepresentation)
    }
}

// swiftlint:enable line_length
