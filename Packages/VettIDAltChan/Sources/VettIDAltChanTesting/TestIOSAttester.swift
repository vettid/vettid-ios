import CryptoKit
import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto

/// TEST ONLY. A software App Attest key whose attestation and assertions the dev enclave's TEST device policy accepts:
/// the Swift port of vettid-vault `internal/enclavetest/devattest.go`'s iOS attester (`NewIOSAttester`,
/// `AppleCA.Attest`, `IOSAssert`). The simulator has no App Attest; the vault has no relaxed mode (IOS-PLAN §6.2), so
/// tests and the simulator's dev stack use this. The App ID is the TEST one, `TESTTEAM00.com.vettid.app`, which only
/// the TEST policy accepts.
///
/// The formats are VAULT-MESSAGING §11.7's iOS forms, as Apple defines them:
///
/// - **attestation**: CBOR `{"fmt": "apple-appattest", "attStmt": {"x5c": [credential, intermediate], "receipt": …},
///   "authData": …}`; authData = SHA-256(App ID) ‖ flags `0x41` ‖ counter 0 ‖ aaguid `appattest` + 7 zero bytes (the
///   production environment) ‖ the key id's length and the key id ‖ the COSE EC2 P-256 key. The credential
///   certificate's nonce extension is SHA-256(authData ‖ clientDataHash), and clientDataHash is the challenge.
/// - **assertion**: CBOR `{"signature": …, "authenticatorData": …}`; authenticatorData = SHA-256(App ID) ‖ flags `0x01`
///   ‖ counter; the signature is ECDSA P-256 over SHA-256(nonce), nonce = SHA-256(authenticatorData ‖ clientDataHash),
///   the counter increasing from 1.
/// - **key id**: SHA-256 of the uncompressed public point.
public final class TestIOSAttester: Attester, CustomStringConvertible, @unchecked Sendable {
    /// The marker the release check refuses in a Release or Staging app (IOS-PLAN §5).
    public static let testOnlyMarker = "VETTID TEST ONLY: the TEST App Attest attester"
    /// The App ID of the dev enclave's TEST policy (vettid-vault `enclavetest.IOSAppID`).
    public static let testAppID = "TESTTEAM00.com.vettid.app"
    /// The production environment's aaguid: "appattest" and seven zero bytes.
    public static let aaguidProduction = Array("appattest".utf8) + [UInt8](repeating: 0, count: 7)
    static let flagsAttested: UInt8 = 0x41
    static let flagsAsserted: UInt8 = 0x01
    static let receipt = Array("TEST receipt".utf8)
    static let hashSize = 32

    public let appID: String
    /// The marker, so that it stays in any binary that links this type.
    public var description: String { Self.testOnlyMarker }
    private let signer: P256.Signing.PrivateKey
    private let ca: TestAppleCA
    private let lock = NSLock()
    private var counter: UInt32 = 0

    /// A fresh random key, or with [seed] vettid-vault's `NewIOSAttester(seed, …)` key (`TestKey(P-256, seed)`).
    public init(seed: UInt8? = nil, appID: String = TestIOSAttester.testAppID, ca: TestAppleCA = .shared) {
        signer = seed.map(TestKey.p256) ?? P256.Signing.PrivateKey()
        self.appID = appID
        self.ca = ca
    }

    /// The uncompressed public point (65 bytes).
    public var publicPoint: [UInt8] { Array(signer.publicKey.x963Representation) }

    /// SHA-256 of the public point.
    public var keyID: [UInt8] { Bytes.sha256(publicPoint) }

    /// The last assertion counter used (0 before the first assertion).
    public var lastCounter: UInt32 { lock.withLock { counter } }

    /// Sets the counter the next assertion exceeds (a key used across processes keeps it increasing).
    public func setCounter(_ c: UInt32) { lock.withLock { counter = c } }

    // MARK: - Attester

    public func attest(_ challenge: [UInt8]) throws -> DeviceAttest {
        try DeviceAttest.iosAttestation(
            keyID: keyID, attestation: try attestation(clientDataHash: challenge, serial: ca.nextSerial())
        )
    }

    public func assert(_ signed: AttestSigned) throws -> DeviceAssertion {
        let c: UInt32 = lock.withLock {
            counter += 1
            return counter
        }
        return try DeviceAssertion.iosAssertion(try assertion(clientDataHash: signed.clientDataHash, counter: c))
    }

    // MARK: - Formats

    /// The attestation object over [clientDataHash] with the credential certificate's [serial].
    public func attestation(clientDataHash: [UInt8], serial: Int64) throws -> [UInt8] {
        guard clientDataHash.count == Self.hashSize else { throw CryptoError.format("clientDataHash") }
        let ad = Self.attestedAuthData(appID: appID, point: publicPoint)
        let nonce = Bytes.sha256(ad, clientDataHash)
        let leaf = try ca.issueCredential(publicKey: signer.publicKey, nonce: nonce, serial: serial)
        let e = CborEncoder()
        e.map(3).text("fmt").text("apple-appattest")
        e.text("attStmt").map(2).text("x5c").array(2).bytes(leaf).bytes(ca.intermediateDER)
        e.text("receipt").bytes(Self.receipt)
        e.text("authData").bytes(ad)
        return e.encoded()
    }

    /// The assertion over [clientDataHash] with [counter]. ECDSA is randomized: only the signature varies.
    public func assertion(clientDataHash: [UInt8], counter: UInt32) throws -> [UInt8] {
        guard clientDataHash.count == Self.hashSize else { throw CryptoError.format("clientDataHash") }
        let ad = Self.assertionAuthData(appID: appID, counter: counter)
        let nonce = Bytes.sha256(ad, clientDataHash)
        // App Attest signs nonce with ECDSA-SHA256, so the signed digest is SHA-256(nonce).
        let sig = try signer.signature(for: nonce)
        let e = CborEncoder()
        e.map(2).text("signature").bytes(Array(sig.derRepresentation)).text("authenticatorData").bytes(ad)
        return e.encoded()
    }

    /// The attested key's authenticator data: rpIdHash, flags `0x41`, counter 0, the production aaguid, the key id as
    /// credential id and the COSE key.
    public static func attestedAuthData(appID: String, point: [UInt8]) -> [UInt8] {
        let keyID = Bytes.sha256(point)
        var ad = Bytes.sha256(Array(appID.utf8))
        ad.append(flagsAttested)
        ad += bigEndian(UInt32(0))
        ad += aaguidProduction
        ad += [UInt8(keyID.count >> 8), UInt8(keyID.count & 0xFF)]
        ad += keyID
        ad += coseKey(point)
        return ad
    }

    /// An assertion's authenticator data: rpIdHash, flags `0x01`, the counter.
    public static func assertionAuthData(appID: String, counter: UInt32) -> [UInt8] {
        Bytes.sha256(Array(appID.utf8)) + [flagsAsserted] + bigEndian(counter)
    }

    /// The COSE_Key `{1: 2, 3: -7, -1: 1, -2: x, -3: y}` (EC2, ES256, P-256), in enclavetest's order.
    public static func coseKey(_ point: [UInt8]) -> [UInt8] {
        let e = CborEncoder()
        e.map(5).int(1).int(2).int(3).int(-7).int(-1).int(1)
        e.int(-2).bytes(Array(point[1..<33])).int(-3).bytes(Array(point[33..<65]))
        return e.encoded()
    }

    static func bigEndian(_ v: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
}
