import CryptoKit
import Foundation
import Testing
@testable import VettIDAttestation
import VettIDCrypto

// Checks stay on one line each.
// swiftlint:disable line_length

/// The app's checks of an enclave (VAULT-MESSAGING §11.2, §11.3). Mirrors the enclave part of vettid-android
/// `ManifestTest`.
@Suite struct EnclaveVerifierTests {
    let signer = ManifestSigner()
    let nsm: FakeNsm
    let ev: EnclaveVerifier
    let m7: ReleaseManifest
    let etk: KemPublicKey
    let t0: Date

    init() throws {
        var n = FakeNsm(pki: try TestPki.load())
        n.pcr0 = hexRep("cd")
        nsm = n
        ev = EnclaveVerifier(nitro: NitroVerifier(roots: [n.pki.root]))
        let r3 = ManifestSigner.entry(3, hexRep("ab"), "deprecated", endsAt: "2026-12-01T00:00:00Z")
        let r4 = ManifestSigner.entry(4, hexRep("cd"), "active")
        m7 = try ManifestVerifier(pinned: [try signer.manifestKey]).verify(try signer.serve(ManifestSigner.manifest(7, r3, r4)))
        etk = try KemPrivateKey.generate().publicKey
        t0 = try date("2026-10-02T12:00:00Z")
    }

    func descriptor(_ id: String, _ pcr0: String, life: TimeInterval = 24 * 3600) -> [UInt8] {
        Descriptor.marshal(instanceID: id, etk: etk, release: pcr0, notAfter: t0.addingTimeInterval(life))
    }

    func attest(_ n: FakeNsm, _ desc: [UInt8]) throws -> [UInt8] {
        try n.attest(at: t0, userData: AltChannel.etkUserData(desc))
    }

    @Test func aListedActiveEnclaveVerifies() throws {
        let desc = descriptor("i-test-1", hexRep("cd"))
        let e = try ev.verifyEnclave(descriptor: desc, attestation: try attest(nsm, desc), manifest: m7, enroll: true, now: t0.addingTimeInterval(60))
        #expect(e.release.number == 4)
        #expect(e.descriptor.etk == etk)
    }

    @Test func refusals() throws {
        let desc = descriptor("i-test-1", hexRep("cd"))
        let att = try attest(nsm, desc)
        // user_data over other bytes, an old attestation, a descriptor living too long, the descriptor's own format.
        expectAttestation(.userData) { _ = try ev.verifyEnclave(descriptor: descriptor("i-test-2", hexRep("cd")), attestation: att, manifest: m7, enroll: true, now: t0) }
        expectAttestation(.stale) { _ = try ev.verifyEnclave(descriptor: desc, attestation: att, manifest: m7, enroll: true, now: t0.addingTimeInterval(27 * 3600)) }
        let long = descriptor("i-test-1", hexRep("cd"), life: 25 * 3600)
        expectAttestation(.stale) { _ = try ev.verifyEnclave(descriptor: long, attestation: try attest(nsm, long), manifest: m7, enroll: true, now: t0) }
        expectAttestation(.format) { _ = try ev.verifyEnclave(descriptor: Array("{}".utf8), attestation: att, manifest: m7, enroll: true, now: t0) }
        // The descriptor's release is not the document's PCR0.
        let wrongRelease = descriptor("i-test-1", hexRep("ab"))
        expectAttestation(.pcr) { _ = try ev.verifyEnclave(descriptor: wrongRelease, attestation: try attest(nsm, wrongRelease), manifest: m7, enroll: true, now: t0) }
        // A debug enclave.
        var dbg = nsm
        dbg.pcr1 = hexRep("00")
        expectAttestation(.debug) { _ = try ev.verifyEnclave(descriptor: desc, attestation: try attest(dbg, desc), manifest: m7, enroll: true, now: t0) }
        // PCR1 other than the manifest's.
        var other = nsm
        other.pcr1 = hexRep("99")
        expectAttestation(.pcr) { _ = try ev.verifyEnclave(descriptor: desc, attestation: try attest(other, desc), manifest: m7, enroll: true, now: t0) }
    }

    @Test func deprecatedIsForUnlockOnlyAndAnUnlistedReleaseIsUnknown() throws {
        var n3 = nsm
        n3.pcr0 = hexRep("ab")
        let desc3 = descriptor("i-test-3", hexRep("ab"))
        let att3 = try attest(n3, desc3)
        let notActive = expectAttestation(.release) { _ = try ev.verifyEnclave(descriptor: desc3, attestation: att3, manifest: m7, enroll: true, now: t0) }
        #expect(notActive == .release("not active"))
        #expect(notActive?.isManifest == false)
        #expect(try ev.verifyEnclave(descriptor: desc3, attestation: att3, manifest: m7, enroll: false, now: t0).release.number == 3)
        // A release in no entry of the manifest (a canary release without its manifest, a stale manifest): the document
        // itself verifies, and the failure says the release is unknown.
        var nU = nsm
        nU.pcr0 = hexRep("12")
        let descU = descriptor("i-test-4", hexRep("12"))
        let attU = try attest(nU, descU)
        for enroll in [true, false] {
            let u = expectAttestation(.release) { _ = try ev.verifyEnclave(descriptor: descU, attestation: attU, manifest: m7, enroll: enroll, now: t0) }
            #expect(u == .release("not listed", unknown: true))
        }
    }

    @Test func vaultEnrolled() throws {
        let desc = descriptor("i-test-1", hexRep("cd"))
        let e = try ev.verifyEnclave(descriptor: desc, attestation: try attest(nsm, desc), manifest: m7, enroll: true, now: t0)
        let bundle = Array(#"{"v":1}"#.utf8)
        let nonce = [UInt8](repeating: 7, count: 32)
        let enrolled = try nsm.attest(at: t0, userData: AltChannel.vaultUserData(bundle), nonce: nonce)
        try ev.verifyEnrolled(attestation: enrolled, vaultBundle: bundle, nonce: nonce, expected: e.measurements, now: t0)
        expectAttestation(.nonce) { try ev.verifyEnrolled(attestation: enrolled, vaultBundle: bundle, nonce: [UInt8](repeating: 0, count: 32), expected: e.measurements, now: t0) }
        expectAttestation(.userData) { try ev.verifyEnrolled(attestation: enrolled, vaultBundle: Array("{}".utf8), nonce: nonce, expected: e.measurements, now: t0) }
        let otherMs = Measurements(pcr0: hexRep("ab"), pcr1: hexRep("11"), pcr2: hexRep("22"))
        expectAttestation(.pcr) { try ev.verifyEnrolled(attestation: enrolled, vaultBundle: bundle, nonce: nonce, expected: otherMs, now: t0) }
        expectAttestation(.stale) { try ev.verifyEnrolled(attestation: enrolled, vaultBundle: bundle, nonce: nonce, expected: e.measurements, now: t0.addingTimeInterval(27 * 3600)) }
    }
}

/// The canary manifest's installation checks and the choice between it and the published one (VAULT-RELEASES §10.1).
/// Mirrors the installation part of vettid-android `CanaryManifestTest`; its use by the alternate channel comes with
/// the transport (I1).
@Suite struct CanaryManifestTests {
    let signer = ManifestSigner()
    let verifier: ManifestVerifier

    init() throws { verifier = ManifestVerifier(pinned: [try signer.manifestKey]) }

    func served(_ serial: UInt64, number: UInt64 = 3) throws -> [UInt8] {
        try signer.serve(ManifestSigner.manifest(serial, ManifestSigner.entry(number, hexRep("cd"), "active")))
    }

    @Test func aSignedNewerCanaryIsAccepted() throws {
        #expect(try CanaryManifests.check(verifier: verifier, served: served(8), seen: 7, published: 7).serial == 8)
        #expect(try CanaryManifests.check(verifier: verifier, served: served(8), seen: 0, published: nil).serial == 8)
    }

    @Test func signatureKeyAndFormatAreCheckedFirst() throws {
        let m8 = ManifestSigner.manifest(8, ManifestSigner.entry(3, hexRep("cd"), "active"))
        let otherKey = P256.Signing.PrivateKey()
        // A key this build does not pin.
        let unpinned = try ManifestSigner().serve(m8)
        expectAttestation(.manifestKey) { _ = try CanaryManifests.check(verifier: verifier, served: unpinned, seen: 0, published: nil) }
        // Signed by another key but naming the pinned key_id.
        expectAttestation(.signature) { _ = try CanaryManifests.check(verifier: verifier, served: try signer.serve(m8, with: otherKey), seen: 0, published: nil) }
        // Malformed documents.
        for doc in [Array("{}".utf8), Array("not json".utf8), [], [UInt8](repeating: 0x20, count: 90_113)] {
            expectAttestation(.format) { _ = try CanaryManifests.check(verifier: verifier, served: doc, seen: 0, published: nil) }
        }
    }

    @Test func theSerialRules() throws {
        #expect(throws: CanaryManifestError.older) { _ = try CanaryManifests.check(verifier: verifier, served: try served(6), seen: 7, published: nil) }
        // Equal to the one seen: allowed (the same document again).
        #expect(try CanaryManifests.check(verifier: verifier, served: served(7), seen: 7, published: nil).serial == 7)
        for p: UInt64 in [8, 9] {
            #expect(throws: CanaryManifestError.published) { _ = try CanaryManifests.check(verifier: verifier, served: try served(8), seen: 0, published: p) }
        }
    }

    @Test func theHigherSerialIsChosen() throws {
        let p = try verifier.verify(try served(7))
        let c = try verifier.verify(try served(8))
        #expect(CanaryManifests.choose(published: p, canary: c)?.serial == 8)
        #expect(CanaryManifests.choose(published: nil, canary: c)?.serial == 8)
        #expect(CanaryManifests.choose(published: p, canary: nil)?.serial == 7)
        #expect(CanaryManifests.choose(published: nil, canary: nil) == nil)
        // Equal serials: the published one.
        let same = try verifier.verify(try served(8, number: 4))
        #expect(CanaryManifests.choose(published: same, canary: c)?.releases.first?.number == 4)
    }
}

// swiftlint:enable line_length
