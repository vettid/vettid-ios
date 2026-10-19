import CryptoKit
import Foundation
import Testing
@testable import VettIDAltChan
import VettIDAltChanTesting
import VettIDAttestation
import VettIDCrypto

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The release approval in an unlock (VAULT-MESSAGING §11.10.3; IOS-PLAN §6.2), checked as vettid-vault's enclave checks
/// it (`enclave/core.go`, `VerifyApproval`): two App Attest assertions in one request, `device_assertion` over the
/// unlock's challenge and the approval over SHA-256 of the approval string, whose counters both exceed the counter the
/// vault stored before the request and differ; the approval string names the routed release as `from_pcr0_hex`, the
/// request's id and its manifest serial, so that it is good for that one unlock only. With the TEST App Attest key.
@Suite struct ReleaseApprovalTests {
    static let vaultID = "0123456789abcdef0123456789abcdef"
    static let target = String(repeating: "c5", count: 48)

    /// What one sealed unlock carried.
    struct Sent {
        let requestID: String
        let serial: UInt64
        let deviceAssertion: [UInt8]
        let approval: [UInt8]
        let to: String
        let toRelease: UInt64
    }

    func build(_ attester: TestIOSAttester) throws -> Sent {
        let e = try FakeEnclave("inst-a")
        let api = FakeAltAPI([e])
        let m = try ManifestVerifier(pinned: [try api.manifestKey]).verify(try api.served())
        let built = try AltRequests.buildUnlock(
            userGuid: "guid-1", vaultID: Self.vaultID, pin: "246802", enclave: try e.verified(m), manifest: m, attester: attester,
            ik: Ed25519PrivateKey.generate(), token: "v4.public.t", state: AltState(),
            options: UnlockOptions(approve: Approval(toPcr0: Self.target, toRelease: 4)), now: Date()
        )
        let body = try StrictJson.parseObject(try e.open(built.request.envelope).body)
        let u = try body.obj("release_update")
        guard case .ios(let d) = try DeviceAssertion.parse(try body.obj("device_assertion")),
              case .ios(let a) = try DeviceAssertion.parse(try u.obj("approval"))
        else { throw CryptoError.format("not the ios form") }
        return Sent(
            requestID: try body.string("request_id"), serial: try body.uint("manifest_serial", min: 0, max: 1 << 53),
            deviceAssertion: d, approval: a, to: try u.string("to"), toRelease: try u.uint("to_release", min: 1, max: 1 << 53)
        )
    }

    /// The assertion's authenticator data and its counter (bytes 33–36, big-endian).
    func counter(_ assertion: [UInt8]) throws -> UInt32 {
        let ad = try CborValue.decode(assertion).bytes(at: "authenticatorData")
        return ad[33..<37].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    @Test func bothCountersExceedTheStoredOneAndDiffer() throws {
        let a = TestIOSAttester()
        // The counter the vault stored after this key's last accepted assertion.
        a.setCounter(41)
        let s = try build(a)
        let unlock = try counter(s.deviceAssertion)
        let approval = try counter(s.approval)
        #expect(unlock > 41 && approval > 41)
        #expect(unlock != approval)
        // One after the other: the unlock's first, then the approval's (the enclave stores the larger).
        #expect(unlock == 42 && approval == 43)
        // A retry (another request after `attestation` or `manifest`) asserts afresh: every counter is new.
        let again = try build(a)
        #expect(try counter(again.deviceAssertion) == 44 && counter(again.approval) == 45)
        #expect(again.requestID != s.requestID)
    }

    @Test func theApprovalVerifiesOverTheStringTheEnclaveBuilds() throws {
        let a = TestIOSAttester()
        let s = try build(a)
        #expect(s.to == Self.target && s.toRelease == 4)
        // The enclave builds the string itself, with its own PCR0 as from_pcr0_hex (the routed release).
        let string = try AltChannel.approvalSigningString(
            vaultID: Self.vaultID, requestID: s.requestID, fromPcr0: FakeEnclave.pcr0, toPcr0: Self.target, toRelease: 4, serial: s.serial
        )
        let v = try CborValue.decode(s.approval)
        let ad = try v.bytes(at: "authenticatorData")
        let sig = try P256.Signing.ECDSASignature(derRepresentation: try v.bytes(at: "signature"))
        let pub = try P256.Signing.PublicKey(x963Representation: a.publicPoint)
        #expect(pub.isValidSignature(sig, for: Bytes.sha256(ad, Bytes.sha256(Array(string.utf8)))))
        // Good for that one unlock only: another request id, another source release or another serial does not verify.
        for other in [
            try AltChannel.approvalSigningString(vaultID: Self.vaultID, requestID: "01K7Z5N4Q8R2S6T0V3W7X9Y1Z2", fromPcr0: FakeEnclave.pcr0, toPcr0: Self.target, toRelease: 4, serial: s.serial),
            try AltChannel.approvalSigningString(vaultID: Self.vaultID, requestID: s.requestID, fromPcr0: String(repeating: "b4", count: 48), toPcr0: Self.target, toRelease: 4, serial: s.serial),
            try AltChannel.approvalSigningString(vaultID: Self.vaultID, requestID: s.requestID, fromPcr0: FakeEnclave.pcr0, toPcr0: Self.target, toRelease: 4, serial: s.serial + 1),
        ] {
            #expect(!pub.isValidSignature(sig, for: Bytes.sha256(ad, Bytes.sha256(Array(other.utf8)))))
        }
        // The device assertion is not over the approval string.
        let d = try CborValue.decode(s.deviceAssertion)
        let dsig = try P256.Signing.ECDSASignature(derRepresentation: try d.bytes(at: "signature"))
        #expect(!pub.isValidSignature(dsig, for: Bytes.sha256(try d.bytes(at: "authenticatorData"), Bytes.sha256(Array(string.utf8)))))
    }
}

// swiftlint:enable line_length
