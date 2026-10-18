import CryptoKit
import Foundation
import Testing
import VettIDAltChan
@testable import VettIDAltChanTesting
import VettIDAttestation
import VettIDCrypto
import X509

/// The TEST iOS attester (IOS-PLAN §8 I1.3), against the fixture `Resources/appattest/test-app-attest.json` that
/// vettid-vault's own verifier accepts (`scripts/devattest-verify`, `Resources/appattest/SOURCE.md`). Everything that is
/// not an ECDSA signature is reproduced byte for byte: the key id, the authenticator data, the receipt, the
/// `tbsCertificate` of the credential, intermediate and root certificates, each assertion's authenticator data. ECDSA
/// is randomized, so every signature in the fixture is verified instead.
///
/// `VETTID_WRITE_APPATTEST_FIXTURE=1 swift test --package-path Packages/VettIDAltChan --filter TestIOSAttester` writes
/// the fixture again (and then verifies it).
@Suite struct TestIOSAttesterTests {
    static let seed: UInt8 = 0x91
    static let serial: Int64 = 1001
    static let challenge = Bytes.sha256(Array("VettID TEST ONLY App Attest fixture: the enrollment challenge".utf8))
    static let unlockChallenge = Bytes.sha256(Array("VettID TEST ONLY App Attest fixture: the unlock challenge".utf8))

    static let description =
        "VETTID TEST ONLY: the TEST iOS attester's output (VettIDAltChanTesting), verified by vettid-vault devattest"

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/appattest/test-app-attest.json")
    }

    static func approvalString() throws -> String {
        try AltChannel.approvalSigningString(
            vaultID: "test-vault-0001", requestID: "01K7Z5N4Q8R2S6T0V3W7X9Y1Z2", fromPcr0: String(repeating: "a", count: 96),
            toPcr0: String(repeating: "b", count: 96), toRelease: 4, serial: 7
        )
    }

    // MARK: - The fixture

    /// The attestation and three assertions (an unlock, a release approval, another unlock) of the seed-0x91 key.
    static func makeFixture() throws -> [UInt8] {
        let a = TestIOSAttester(seed: seed)
        let att = try a.attestation(clientDataHash: challenge, serial: serial)
        let attest = try DeviceAttest.iosAttestation(keyID: a.keyID, attestation: att)
        let approval = try approvalString()
        let signed: [AttestSigned] = [.challenge(challenge), .string(approval), .challenge(unlockChallenge)]
        var assertions: [String] = []
        for item in signed {
            let assertion = try a.assert(item)
            let b = JsonBuilder()
            switch item {
            case .challenge(let c): b.string("client_data", "challenge").string("challenge_hex", Bytes.hex(c))
            case .string(let m): b.string("client_data", "approval").string("message", m)
            }
            assertions.append(b.uint("counter", UInt64(a.lastCounter)).raw("device_assertion", assertion.marshal()).build())
        }
        let ca = JsonBuilder().base64("root", TestAppleCA.shared.rootDER).base64("intermediate", TestAppleCA.shared.intermediateDER)
        let doc = JsonBuilder()
            .string("description", Self.description)
            .string("app_id", TestIOSAttester.testAppID)
            .uint("key_seed", UInt64(seed))
            .string("public_key_hex", Bytes.hex(a.publicPoint))
            .string("key_id_hex", Bytes.hex(a.keyID))
            .uint("serial", UInt64(serial))
            .string("challenge_hex", Bytes.hex(challenge))
            .raw("test_ca", ca.build())
            .raw("device_attest", attest.marshal())
            .raw("assertions", JsonBuilder.array(assertions))
            .build()
        // One member per line, so that a change shows in a diff.
        let pretty = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: Data(doc.utf8)),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return Array(pretty) + [0x0A]
    }

    /// Written at most once per run, before either test reads it.
    static let written: Result<Void, Error> = Result {
        if ProcessInfo.processInfo.environment["VETTID_WRITE_APPATTEST_FIXTURE"] == "1" {
            try Data(try makeFixture()).write(to: fixtureURL, options: .atomic)
        }
    }

    static func loadFixture() throws -> JsonObject {
        try written.get()
        return try StrictJson.parseObject(Array(try Data(contentsOf: fixtureURL)))
    }

    @Test func theFixtureIsReproducedByteForByteExceptSignatures() throws {
        let doc = try Self.loadFixture()
        #expect(try doc.string("app_id") == "TESTTEAM00.com.vettid.app")
        #expect(try doc.uint("key_seed", min: 1, max: 255) == UInt64(Self.seed))
        #expect(try doc.uint("serial", min: 1, max: 1 << 31) == UInt64(Self.serial))
        #expect(try doc.hex("challenge_hex") == Self.challenge)

        let a = TestIOSAttester(seed: Self.seed)
        #expect(try doc.hex("public_key_hex") == a.publicPoint)
        #expect(try doc.hex("key_id_hex") == a.keyID)
        guard case .ios(let keyID, let fixed) = try DeviceAttest.parse(try doc.obj("device_attest")) else {
            Issue.record("device_attest is not the ios form")
            return
        }
        #expect(keyID == a.keyID)

        let fresh = try CborValue.decode(try a.attestation(clientDataHash: Self.challenge, serial: Self.serial))
        let old = try CborValue.decode(fixed)
        #expect(old.entries?.map(\.key) == [.text("fmt"), .text("attStmt"), .text("authData")])
        #expect(try old.text(at: "fmt") == "apple-appattest")
        #expect(try old.bytes(at: "authData") == fresh.bytes(at: "authData"))
        let expectedAD = TestIOSAttester.attestedAuthData(appID: TestIOSAttester.testAppID, point: a.publicPoint)
        #expect(try old.bytes(at: "authData") == expectedAD)
        let oldStmt = try #require(old.lookup("attStmt"))
        let freshStmt = try #require(fresh.lookup("attStmt"))
        #expect(oldStmt.entries?.map(\.key) == [.text("x5c"), .text("receipt")])
        #expect(try oldStmt.bytes(at: "receipt") == freshStmt.bytes(at: "receipt"))
        let oldChain = try Self.x5c(oldStmt)
        let freshChain = try Self.x5c(freshStmt)
        #expect(oldChain.count == 2 && freshChain.count == 2)
        for (o, f) in zip(oldChain, freshChain) {
            #expect(try TestAppleCA.tbs(o) == TestAppleCA.tbs(f))
        }
        let ca = try doc.obj("test_ca")
        #expect(try ca.base64("intermediate") == oldChain[1])
        #expect(try TestAppleCA.tbs(try ca.base64("root")) == TestAppleCA.tbs(TestAppleCA.shared.rootDER))
    }

    @Test func theFixturesSignaturesVerify() throws {
        let doc = try Self.loadFixture()
        let ca = try doc.obj("test_ca")
        let root = try Certificate(derEncoded: try ca.base64("root"))
        let inter = try Certificate(derEncoded: try ca.base64("intermediate"))
        guard case .ios(_, let att) = try DeviceAttest.parse(try doc.obj("device_attest")) else {
            Issue.record("device_attest is not the ios form")
            return
        }
        let stmt = try #require(try CborValue.decode(att).lookup("attStmt"))
        let leaf = try Certificate(derEncoded: try Self.x5c(stmt)[0])
        // root → root, root → intermediate, intermediate → credential (ECDSA P-384, SHA-384).
        #expect(root.publicKey.isValidSignature(root.signature, for: root))
        #expect(root.publicKey.isValidSignature(inter.signature, for: inter))
        #expect(inter.publicKey.isValidSignature(leaf.signature, for: leaf))
        #expect(!inter.publicKey.isValidSignature(root.signature, for: root))
        // The credential's key is the attested key and its nonce is SHA-256(authData ‖ clientDataHash).
        let a = TestIOSAttester(seed: Self.seed)
        #expect(Array(try #require(P256.Signing.PublicKey(leaf.publicKey)).x963Representation) == a.publicPoint)
        let ext = try #require(leaf.extensions[oid: TestAppleCA.nonceOID])
        let nonce = Bytes.sha256(try CborValue.decode(att).bytes(at: "authData"), Self.challenge)
        #expect(Array(ext.value) == TestAppleCA.nonceExtension(nonce))
        #expect(!ext.critical)

        // Each assertion: its authenticator data, its counter, and its signature under the attested key.
        let assertions = try doc.array("assertions").map { try $0.asObject() }
        #expect(assertions.map { (try? $0.string("client_data")) ?? "" } == ["challenge", "approval", "challenge"])
        for (i, o) in assertions.enumerated() {
            let counter = UInt32(i + 1)
            #expect(try o.uint("counter", min: 1, max: 1 << 32) == UInt64(counter))
            let cdh = try o.string("client_data") == "approval"
                ? Bytes.sha256(Array(try o.string("message").utf8)) : try o.hex("challenge_hex")
            guard case .ios(let raw) = try DeviceAssertion.parse(try o.obj("device_assertion")) else {
                Issue.record("device_assertion is not the ios form")
                continue
            }
            let v = try CborValue.decode(raw)
            #expect(v.entries?.map(\.key) == [.text("signature"), .text("authenticatorData")])
            let ad = try v.bytes(at: "authenticatorData")
            #expect(ad == TestIOSAttester.assertionAuthData(appID: TestIOSAttester.testAppID, counter: counter))
            let sig = try P256.Signing.ECDSASignature(derRepresentation: try v.bytes(at: "signature"))
            let pub = try P256.Signing.PublicKey(x963Representation: a.publicPoint)
            #expect(pub.isValidSignature(sig, for: Bytes.sha256(ad, cdh)))
            #expect(!pub.isValidSignature(sig, for: Bytes.sha256(ad, Self.challenge.reversed())))
        }
        #expect(try assertions[1].string("message") == Self.approvalString())
    }

    static func x5c(_ stmt: CborValue) throws -> [[UInt8]] {
        guard case .array(let items)? = stmt.lookup("x5c") else { throw CryptoError.format("x5c") }
        return try items.map {
            guard case .bytes(let b) = $0 else { throw CryptoError.format("x5c item") }
            return b
        }
    }

    // MARK: - Behaviour

    @Test func theKeyIsEnclavetestsTestKey() throws {
        // TestKey(P-256, seed): the scalar is 32 bytes of seed, as vettid-vault's enclavetest.TestKey.
        let k = TestKey.p256(0x91)
        #expect(Array(k.rawRepresentation) == [UInt8](repeating: 0x91, count: 32))
        #expect(Array(TestKey.p384(0x51).rawRepresentation) == [UInt8](repeating: 0x51, count: 48))
        let a = TestIOSAttester(seed: 0x91)
        #expect(a.publicPoint == Array(k.publicKey.x963Representation))
        #expect(a.keyID == Bytes.sha256(a.publicPoint))
        #expect(TestIOSAttester(seed: nil).keyID != TestIOSAttester(seed: nil).keyID)
    }

    @Test func theAuthenticatorDataHasAppleLayout() {
        let a = TestIOSAttester(seed: 0x92)
        let ad = TestIOSAttester.attestedAuthData(appID: a.appID, point: a.publicPoint)
        #expect(Array(ad[0..<32]) == Bytes.sha256(Array("TESTTEAM00.com.vettid.app".utf8)))
        #expect(ad[32] == 0x41)
        #expect(Array(ad[33..<37]) == [0, 0, 0, 0])
        #expect(Array(ad[37..<53]) == Array("appattest".utf8) + [UInt8](repeating: 0, count: 7))
        #expect(Array(ad[53..<55]) == [0, 32])
        #expect(Array(ad[55..<87]) == a.keyID)
        // COSE_Key {1: 2, 3: -7, -1: 1, -2: x, -3: y}
        #expect(Array(ad[87..<97]) == [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
        #expect(Array(ad[97..<129]) == Array(a.publicPoint[1..<33]))
        #expect(Array(ad[129..<132]) == [0x22, 0x58, 0x20])
        #expect(Array(ad[132...]) == Array(a.publicPoint[33...]))
        #expect(TestIOSAttester.assertionAuthData(appID: a.appID, counter: 0x0102_0304)
            == Bytes.sha256(Array(a.appID.utf8)) + [0x01, 0x01, 0x02, 0x03, 0x04])
    }

    @Test func attestationsCarryIncreasingSerialsAndRefuseAWrongChallengeSize() throws {
        let a = TestIOSAttester()
        guard case .ios(let keyID, let first) = try a.attest(Self.challenge),
              case .ios(_, let second) = try a.attest(Self.challenge) else {
            Issue.record("not the ios form")
            return
        }
        #expect(keyID == a.keyID)
        let s1 = try Certificate(derEncoded: try Self.x5c(try #require(CborValue.decode(first).lookup("attStmt")))[0]).serialNumber
        let s2 = try Certificate(derEncoded: try Self.x5c(try #require(CborValue.decode(second).lookup("attStmt")))[0]).serialNumber
        #expect(s1 != s2)
        #expect(throws: CryptoError.self) { try a.attest([1, 2, 3]) }
        #expect(throws: CryptoError.self) { try a.assertion(clientDataHash: [1], counter: 1) }
    }

    @Test func assertionsCountUpAndAssertWithTheSignedKindsClientDataHash() throws {
        let a = TestIOSAttester()
        #expect(a.lastCounter == 0)
        _ = try a.assert(.challenge(Self.challenge))
        _ = try a.assert(.challenge(Self.challenge))
        #expect(a.lastCounter == 2)
        a.setCounter(41)
        let approval = try Self.approvalString()
        guard case .ios(let raw) = try a.assert(.string(approval)) else {
            Issue.record("not the ios form")
            return
        }
        #expect(a.lastCounter == 42)
        let v = try CborValue.decode(raw)
        let ad = try v.bytes(at: "authenticatorData")
        #expect(ad == TestIOSAttester.assertionAuthData(appID: a.appID, counter: 42))
        // An approval string's clientDataHash is SHA-256 of it (§11.10.3); a challenge is the clientDataHash (§11.7).
        let sig = try P256.Signing.ECDSASignature(derRepresentation: try v.bytes(at: "signature"))
        let pub = try P256.Signing.PublicKey(x963Representation: a.publicPoint)
        #expect(pub.isValidSignature(sig, for: Bytes.sha256(ad, Bytes.sha256(Array(approval.utf8)))))
        #expect(AttestSigned.challenge(Self.challenge).clientDataHash == Self.challenge)
        #expect(AttestSigned.string(approval).message == Array(approval.utf8))
        #expect(throws: CryptoError.self) { try a.assert(.challenge([1, 2, 3])) }
    }

    @Test func itCarriesTheTestOnlyMarker() {
        #expect(TestIOSAttester.testOnlyMarker.hasPrefix("VETTID TEST ONLY"))
        #expect(TestIOSAttester().description == TestIOSAttester.testOnlyMarker)
        #expect(TestAppleCA.shared.description.hasPrefix("VETTID TEST ONLY"))
        #expect(SoftwareAppKey().description.hasPrefix("VETTID TEST ONLY"))
        #expect(DevStack().description.hasPrefix("VETTID TEST ONLY"))
        #expect(DevStackError("x").description.hasPrefix("VETTID TEST ONLY"))
    }
}

extension JsonObject {
    func hex(_ name: String) throws -> [UInt8] { try Bytes.unhex(try string(name)) }
}
