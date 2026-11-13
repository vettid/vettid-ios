import CryptoKit
import Foundation
import Testing
@testable import VettIDAttestation
import VettIDCrypto

// Checks stay on one line each.
// swiftlint:disable line_length

/// The record of a verification (ANDROID-PLAN 0.1.124 §4 "Attestation in detail"): one line per check in the order the app
/// makes them, "Passed" only with a recorded pass, the first failure "Failed" and every later one "Not checked", with the
/// values once read. Mirrors the record part of vettid-android `ManifestTest`.
@Suite struct EnclaveRecordTests {
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

    /// The record's results are a run: [passed] passes, then one failure when [failed], then "Not checked".
    func expectRun(_ r: EnclaveRecord, passed: Int, failed: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        for (i, c) in AttestationCheck.allCases.enumerated() {
            let want: CheckResult = i < passed ? .passed : failed && i == passed ? .failed : .notRun
            #expect(r.result(c) == want, "\(c)", sourceLocation: sourceLocation)
        }
    }

    @Test func aVerifiedEnclaveRecordsEveryCheckPassedWithItsValues() throws {
        let desc = descriptor("i-test-1", hexRep("cd"))
        let v = ev.verify(descriptor: desc, attestation: try attest(nsm, desc), manifest: m7, enroll: true, now: t0.addingTimeInterval(60))
        #expect(try v.enclave().release.number == 4)
        let r = v.record
        #expect(r.allPassed)
        #expect(r.failed == nil)
        #expect(r.refusal == nil)
        #expect(r.at == t0.addingTimeInterval(60))
        #expect(r.manifestKeyID == (try signer.manifestKey.keyID))
        #expect(r.manifestSerial == 7)
        #expect(r.pcr0 == hexRep("cd"))
        #expect(r.pcr1 == nsm.pcr1)
        #expect(r.pcr2 == nsm.pcr2)
        #expect(r.attestedAt == t0)
        #expect(r.notAfter == t0.addingTimeInterval(24 * 3600))
        #expect(r.releaseNumber == 4)
        #expect(r.releaseStatus == .active)
        #expect(r.releaseEndsAt == nil)
    }

    @Test func eachFailureIsItsOwnLineAndEveryLaterOneIsNotChecked() throws {
        let desc = descriptor("i-test-1", hexRep("cd"))
        let att = try attest(nsm, desc)
        func run(_ d: [UInt8], _ a: [UInt8], now: Date? = nil, verifier: EnclaveVerifier? = nil) -> EnclaveVerification {
            (verifier ?? ev).verify(descriptor: d, attestation: a, manifest: m7, enroll: false, now: now ?? t0)
        }
        // Line 2: a chain to another root (and a document that is not a COSE_Sign1).
        let otherRoot = EnclaveVerifier(nitro: NitroVerifier(roots: [NitroRoot.der]))
        expectRun(run(desc, att, verifier: otherRoot).record, passed: 1, failed: true)
        expectRun(run(desc, [0x01, 0x02]).record, passed: 1, failed: true)
        // Line 3: the chain verifies, the signature does not (its last byte changed).
        var badSig = att
        badSig[badSig.count - 1] ^= 0x01
        let sig = run(desc, badSig)
        expectRun(sig.record, passed: 2, failed: true)
        #expect(throws: AttestationError.self) { try sig.enclave() }
        // Line 4: user_data over other bytes; a descriptor that does not parse.
        expectRun(run(descriptor("i-test-2", hexRep("cd")), att).record, passed: 3, failed: true)
        expectRun(run(Array("{}".utf8), att).record, passed: 3, failed: true)
        // Line 5: too old.
        expectRun(run(desc, att, now: t0.addingTimeInterval(27 * 3600)).record, passed: 4, failed: true)
        // Line 6: a debug enclave.
        var dbg = nsm
        dbg.pcr1 = hexRep("00")
        expectRun(run(desc, try attest(dbg, desc)).record, passed: 5, failed: true)
        // Line 7: the descriptor names another release than PCR0.
        let wrongRelease = descriptor("i-test-1", hexRep("ab"))
        expectRun(run(wrongRelease, try attest(nsm, wrongRelease)).record, passed: 6, failed: true)
        // Line 8: a descriptor living too long.
        let long = descriptor("i-test-1", hexRep("cd"), life: 25 * 3600)
        expectRun(run(long, try attest(nsm, long)).record, passed: 7, failed: true)
        // Line 9: a release in no entry; PCR1 other than the entry's.
        var unlisted = nsm
        unlisted.pcr0 = hexRep("12")
        let descU = descriptor("i-test-4", hexRep("12"))
        let u = run(descU, try attest(unlisted, descU)).record
        expectRun(u, passed: 8, failed: true)
        #expect(u.releaseNumber == nil)
        var other = nsm
        other.pcr1 = hexRep("99")
        expectRun(run(desc, try attest(other, desc)).record, passed: 8, failed: true)
    }

    @Test func valuesAreRecordedOnlyOnceRead() throws {
        let desc = descriptor("i-test-1", hexRep("cd"))
        // The chain failed: the document was never read.
        let chain = EnclaveVerifier(nitro: NitroVerifier(roots: [NitroRoot.der])).verify(descriptor: desc, attestation: try attest(nsm, desc), manifest: m7, enroll: false, now: t0).record
        #expect(chain.pcr0 == nil && chain.attestedAt == nil && chain.notAfter == nil && chain.releaseNumber == nil)
        #expect(chain.manifestSerial == 7)
        // The descriptor did not parse: the document's values are there, not_after is not.
        let format = ev.verify(descriptor: Array("{}".utf8), attestation: try attest(nsm, desc), manifest: m7, enroll: false, now: t0).record
        #expect(format.pcr0 == hexRep("cd") && format.attestedAt == t0)
        #expect(format.notAfter == nil)
    }

    @Test func aReleaseNotActiveForAnEnrollmentIsRefusedAfterEveryCheckPassed() throws {
        var n3 = nsm
        n3.pcr0 = hexRep("ab")
        let desc3 = descriptor("i-test-3", hexRep("ab"))
        let att3 = try attest(n3, desc3)
        let enroll = ev.verify(descriptor: desc3, attestation: att3, manifest: m7, enroll: true, now: t0)
        #expect(throws: AttestationError.release("not active")) { try enroll.enclave() }
        #expect(enroll.record.allPassed)
        #expect(enroll.record.refusal == .notActive)
        #expect(enroll.record.releaseNumber == 3)
        #expect(enroll.record.releaseStatus == .deprecated)
        #expect(enroll.record.releaseEndsAt == (try date("2026-12-01T00:00:00Z")))
        // To unlock, it verifies.
        let unlock = ev.verify(descriptor: desc3, attestation: att3, manifest: m7, enroll: false, now: t0)
        #expect(try unlock.enclave().release.number == 3)
        #expect(unlock.record.refusal == nil)
    }

    @Test func aRefusedManifestFailsLineOneAndChecksNothingElse() {
        let r = EnclaveRecord.manifestFailed(at: t0)
        expectRun(r, passed: 0, failed: true)
        #expect(r.failed == .manifest)
        #expect(r.manifestKeyID == nil && r.manifestSerial == nil && r.pcr0 == nil)
    }

    /// No way to build a "Passed" after a check that did not pass; a stored set of results is read back only as such a run.
    @Test func onlyARunReadsBack() {
        let n = AttestationCheck.allCases.count
        for passed in 0...n {
            for failed in [false, true] where !(failed && passed == n) {
                let r = EnclaveRecord(at: t0, passed: passed, failed: failed)
                expectRun(r, passed: passed, failed: failed)
                #expect(EnclaveRecord.run(r.results).map { [$0.passed, $0.failed ? 1 : 0] } == [passed, failed ? 1 : 0])
            }
        }
        var gap = EnclaveRecord(at: t0, passed: 3, failed: false).results
        gap[.match] = .passed
        #expect(EnclaveRecord.run(gap) == nil)
        var twoFailed = EnclaveRecord(at: t0, passed: 3, failed: true).results
        twoFailed[.match] = .failed
        #expect(EnclaveRecord.run(twoFailed) == nil)
        var missing = EnclaveRecord(at: t0, passed: 9, failed: false).results
        missing[.validity] = nil
        #expect(EnclaveRecord.run(missing) == nil)
    }

    /// A manifest not verified under a pinned key never passes line 1.
    @Test func anUnverifiedManifestFailsLineOne() throws {
        let desc = descriptor("i-test-1", hexRep("cd"))
        let unsigned = try ReleaseManifest.parse(ManifestSigner.manifest(7, ManifestSigner.entry(4, hexRep("cd"), "active")))
        let v = ev.verify(descriptor: desc, attestation: try attest(nsm, desc), manifest: unsigned, enroll: false, now: t0)
        #expect(throws: AttestationError.signature("manifest")) { try v.enclave() }
        expectRun(v.record, passed: 0, failed: true)
    }

    @Test func theManifestKnowsTheKeyThatVerifiedIt() throws {
        #expect(m7.keyID == (try signer.manifestKey.keyID))
        #expect(try ReleaseManifest.parse(ManifestSigner.manifest(7, ManifestSigner.entry(4, hexRep("cd"), "active"))).keyID == nil)
    }

    @Test func theRootFingerprintIsThePinnedRootsSha256() {
        #expect(NitroRoot.fingerprint(NitroRoot.der) == NitroRoot.sha256Hex)
    }
}

// swiftlint:enable line_length
