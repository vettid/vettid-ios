import CryptoKit
import DeviceCheck
import Foundation
import Security
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDKeys
import XCTest
@testable import VettID

/// App Attest on a real iPhone (IOS-PLAN §6.2, §8 I1.4): a fresh key attested over a challenge, then assertions over an
/// unlock challenge and over SHA-256 of an approval string, with the clientDataHash rules of the TEST attester. Skipped
/// where App Attest is unsupported (the simulator, CI). The objects are checked here as the vault's verifier reads them
/// (the certificate chain itself is VA1's: `scripts/devattest-verify/run.sh --real`). Nothing is logged: with
/// `VETTID_TEST_APPATTEST_EXPORT=1` the attestation and the assertions are written to the app's temporary directory as
/// ``exportName``, for VA1 on the Mac, and nowhere else.
final class AppAttestDeviceTests: XCTestCase {
    static let account = "vettid.test.appattest.key_id"
    static let asideAccount = "vettid.test.appattest.key_id.aside"
    static let exportName = "vettid-va1-export.json"
    /// The production environment's aaguid (Apple's App Attest documentation), the only one the vault accepts.
    static let production = Array("appattest".utf8) + [UInt8](repeating: 0, count: 7)

    let on = ProtectedDataFlag(available: true)

    override func setUpWithError() throws {
        try XCTSkipUnless(DCAppAttestService.shared.isSupported, "App Attest is not supported on this device")
        // An export from an earlier run never stays on the phone past a run that did not ask for one.
        if ProcessInfo.processInfo.environment["VETTID_TEST_APPATTEST_EXPORT"] != "1" {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(Self.exportName))
        }
        try KeychainKeyIDStore(account: Self.account, protectedData: on).delete()
        try KeychainKeyIDStore(account: Self.asideAccount, protectedData: on).delete()
    }

    override func tearDownWithError() throws {
        try KeychainKeyIDStore(account: Self.account, protectedData: on).delete()
        try KeychainKeyIDStore(account: Self.asideAccount, protectedData: on).delete()
    }

    private func key() -> AppAttestKey {
        AppAttestKey(
            service: DeviceCheckAppAttestService(), keyID: KeychainKeyIDStore(account: Self.account, protectedData: on),
            aside: KeychainKeyIDStore(account: Self.asideAccount, protectedData: on), mayStartOver: { false }
        )
    }

    /// Runs [body] off the main thread, as the app's requests do (App Attest blocks its caller while Apple answers).
    private func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached { try body() }.value
    }

    func testAttestThenAssert() async throws {
        let attester = AppAttestAttester(key: key())
        let challenge = Randomness.bytes(32)
        let attested = try await background { try attester.attest(challenge) }
        guard case .ios(let keyID, let attestation) = attested else { return XCTFail("not an iOS attestation") }
        let parsed = try Attested(attestation)
        XCTAssertEqual(parsed.fmt, "apple-appattest")
        XCTAssertEqual(parsed.credentialID, keyID, "the credential id is the key id")
        XCTAssertEqual(Bytes.sha256(parsed.point), keyID, "the key id is SHA-256 of the attested point")
        XCTAssertEqual(parsed.counter, 0)
        XCTAssertTrue(parsed.flags & 0x40 != 0)
        // Every configuration is signed for the production environment (IOS-PLAN §6.2).
        XCTAssertEqual(parsed.aaguid, Self.production, "the production App Attest environment")
        // The credential certificate carries SHA-256(authData ‖ clientDataHash), clientDataHash being the challenge.
        let nonce = Bytes.sha256(parsed.authData, challenge)
        XCTAssertNotNil(parsed.leaf.firstRange(of: nonce), "the nonce extension holds the challenge's nonce")
        XCTAssertEqual(parsed.x5c.count, 2)

        // Assertions: an unlock challenge (clientDataHash = the challenge), then an approval string (SHA-256 of it),
        // one after the other with increasing counters (§11.10.3), from another attester object over the same key id.
        let later = AppAttestAttester(key: key())
        let signed: [AttestSigned] = [.challenge(Randomness.bytes(32)), .string("vettid/release-approval/1\nv\nr")]
        var counter: UInt32 = 0
        var assertions: [(AttestSigned, [UInt8])] = []
        for s in signed {
            let a = try await background { try later.assert(s) }
            guard case .ios(let assertion) = a else { return XCTFail("not an iOS assertion") }
            let (ad, sig) = try Self.assertionParts(assertion)
            XCTAssertEqual(Array(ad.prefix(32)), parsed.rpIDHash, "the same App ID")
            let c = UInt32(ad[33]) << 24 | UInt32(ad[34]) << 16 | UInt32(ad[35]) << 8 | UInt32(ad[36])
            XCTAssertGreaterThan(c, counter)
            counter = c
            let pub = try P256.Signing.PublicKey(x963Representation: parsed.point)
            let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: sig)
            // App Attest signs nonce = SHA-256(authenticatorData ‖ clientDataHash) with ECDSA-SHA256.
            XCTAssertTrue(pub.isValidSignature(ecdsa, for: Bytes.sha256(ad, s.clientDataHash)))
            assertions.append((s, assertion))
        }
        try export(keyID: keyID, attestation: attestation, challenge: challenge, assertions: assertions)
    }

    /// IOS-PLAN §6.2 (chosen; not in the spec): the key the vault accepted keeps asserting while a later attestation is
    /// unconfirmed, and a confirmed one takes over.
    func testTheConfirmedKeyAssertsUntilAnotherIsConfirmed() async throws {
        let k = key()
        let attester = AppAttestAttester(key: k)
        let a = try await background { try attester.attest(Randomness.bytes(32)) }
        guard case .ios(let idA, let attA) = a else { return XCTFail("not an iOS attestation") }
        try attester.confirm(keyID: idA)
        let b = try await background { try attester.attest(Randomness.bytes(32)) }
        guard case .ios(let idB, let attB) = b else { return XCTFail("not an iOS attestation") }
        let pointA = try Attested(attA).point
        let pointB = try Attested(attB).point
        let stillA = try await signedBy(attester, pointA)
        XCTAssertTrue(stillA, "an unconfirmed attestation does not replace the current key")
        try attester.confirm(keyID: idB)
        let nowB = try await signedBy(AppAttestAttester(key: key()), pointB)
        XCTAssertTrue(nowB, "the confirmed key takes over")
    }

    private func signedBy(_ attester: AppAttestAttester, _ point: [UInt8]) async throws -> Bool {
        let signed = AttestSigned.challenge(Randomness.bytes(32))
        guard case .ios(let assertion) = try await background({ try attester.assert(signed) }) else { return false }
        let (ad, sig) = try Self.assertionParts(assertion)
        let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: sig)
        return try P256.Signing.PublicKey(x963Representation: point).isValidSignature(ecdsa, for: Bytes.sha256(ad, signed.clientDataHash))
    }

    /// No key id kept: missing. A key id App Attest does not know: iOS 27 answers `invalidKey` (the key is gone, the
    /// "no longer holds the keys" path) or, in some runs, `invalidInput` (a plain failure, never a loss).
    func testAMissingOrUnknownKey() async throws {
        let k = key()
        let challenge = Randomness.bytes(32)
        do {
            _ = try await background { try k.assert(clientDataHash: challenge) }
            XCTFail("asserted without a key")
        } catch {
            XCTAssertEqual(error as? KeysError, .missing("app attest key"))
        }
        try KeychainKeyIDStore(account: Self.account, protectedData: on)
            .write(Array(Data(Randomness.bytes(32)).base64EncodedString().utf8))
        do {
            _ = try await background { try k.assert(clientDataHash: challenge) }
            XCTFail("asserted with an unknown key")
        } catch {
            let e = error as? AppAttestError
            XCTAssertTrue(e == .keyGone || e == .failed(2), "\(error)")
        }
    }

    // MARK: - Export for VA1

    /// With `VETTID_TEST_APPATTEST_EXPORT=1`: the objects, for `scripts/devattest-verify/run.sh --real` on the Mac. The
    /// App ID is the team ID (which only `Config/Signing.xcconfig` holds) and this bundle id; the runner adds the team.
    private func export(keyID: [UInt8], attestation: [UInt8], challenge: [UInt8], assertions: [(AttestSigned, [UInt8])]) throws {
        guard ProcessInfo.processInfo.environment["VETTID_TEST_APPATTEST_EXPORT"] == "1" else { return }
        var list: [[String: String]] = []
        for (signed, assertion) in assertions {
            list.append(["client_data_hash": Self.b64(signed.clientDataHash), "assertion": Self.b64(assertion)])
        }
        var doc: [String: Any] = [:]
        doc["bundle_id"] = Bundle.main.bundleIdentifier ?? ""
        doc["attested_at"] = ISO8601DateFormatter().string(from: Date())
        doc["key_id"] = Self.b64(keyID)
        doc["attestation"] = Self.b64(attestation)
        doc["challenge"] = Self.b64(challenge)
        doc["assertions"] = list
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.exportName)
        try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private static func b64(_ b: [UInt8]) -> String { Data(b).base64EncodedString() }

    // MARK: - Parsing

    static func assertionParts(_ assertion: [UInt8]) throws -> (authenticatorData: [UInt8], signature: [UInt8]) {
        let v = try CborValue.decode(assertion)
        return (try v.bytes(at: "authenticatorData"), try v.bytes(at: "signature"))
    }
}

/// The parts of an App Attest attestation object the tests check.
private struct Attested {
    let fmt: String
    let authData: [UInt8]
    let x5c: [[UInt8]]
    var leaf: [UInt8] { x5c.first ?? [] }

    init(_ attestation: [UInt8]) throws {
        let v = try CborValue.decode(attestation)
        fmt = try v.text(at: "fmt")
        authData = try v.bytes(at: "authData")
        guard case .array(let certs)? = v.lookup("attStmt")?.lookup("x5c") else { throw TestError("no x5c") }
        x5c = certs.compactMap { if case .bytes(let b) = $0 { b } else { nil } }
        guard authData.count > 55 else { throw TestError("short authData") }
    }

    var rpIDHash: [UInt8] { Array(authData[0 ..< 32]) }
    var flags: UInt8 { authData[32] }
    var counter: UInt32 { authData[33 ..< 37].reduce(0) { $0 << 8 | UInt32($1) } }
    var aaguid: [UInt8] { Array(authData[37 ..< 53]) }
    var credentialID: [UInt8] {
        let n = Int(authData[53]) << 8 | Int(authData[54])
        return Array(authData[55 ..< 55 + n])
    }

    /// The credential certificate's public key, SEC1 uncompressed.
    var point: [UInt8] {
        guard let cert = SecCertificateCreateWithData(nil, Data(leaf) as CFData), let key = SecCertificateCopyKey(cert),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return [] }
        return Array(data)
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}
