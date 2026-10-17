import CryptoKit
import Foundation
import Testing
@testable import VettIDAltChan
import VettIDCrypto

/// A software app key for tests: the production key is a Secure Enclave key (VettIDKeys, I1.4). Mirrors
/// vettid-android's test `SoftAppKey`.
struct SoftAppKey: AppKeySigner {
    let signing: P256.Signing.PrivateKey

    init(_ signing: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { self.signing = signing }

    func spki() throws -> [UInt8] { Array(signing.publicKey.derRepresentation) }

    func sign(_ message: [UInt8]) throws -> [UInt8] { Array(try signing.signature(for: message).derRepresentation) }

    func verify(_ message: [UInt8], _ der: [UInt8]) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: der) else { return false }
        return signing.publicKey.isValidSignature(sig, for: message)
    }
}

/// The app key and signed member API requests (VAULT-MESSAGING 0.15.0 §11.12, `appkey.json`; vettid-android has no copy
/// of this file): the key's SPKI and akid, the three requests' signing strings and headers, each signature verified
/// under the vector's key (ECDSA is randomized; the vector's are RFC 6979, any valid one verifies), and the recovery
/// QR with its `api`. Also mirrors vettid-android `AppRequestSigningTest`.
struct AppKeyVectorsTests {
    private let doc: JsonObject

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "appkey", withExtension: "json", subdirectory: "vectors"))
        doc = try StrictJson.parseObject(Array(try Data(contentsOf: url)))
    }

    @Test func theAppKeyAndItsAkid() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: try Bytes.unhex(try doc.string("app_key_scalar_hex")))
        let spki = Array(key.publicKey.derRepresentation)
        #expect(spki == (try doc.base64("app_key_spki_b64")))
        #expect(AppRequestSigning.akid(spki) == (try doc.string("akid")))
        #expect(AppRequestSigning.context == (try doc.string("label")))
    }

    @Test(arguments: ["unlock_request", "redeem_request", "enclave_request"])
    func signedRequests(_ name: String) throws {
        let r = try doc.obj(name)
        let key = try P256.Signing.PrivateKey(rawRepresentation: try Bytes.unhex(try doc.string("app_key_scalar_hex")))
        let akid = try doc.string("akid")
        let body = Array(try r.string("body").utf8)
        #expect(Bytes.hex(Bytes.sha256(body)) == (try r.string("body_sha256_hex")))
        let ts = try r.uint("ts", min: 0, max: StrictJson.maxSafeInteger)
        let signing = AppRequestSigning.signingString(
            method: try r.string("method"), path: try r.string("path"), query: try r.string("query"),
            vaultID: try r.string("vault_id"), akid: akid, ts: ts, nonce: try r.string("nonce"), body: body
        )
        #expect(signing == (try r.string("signing_string")), "\(name)")
        // The vector's signature verifies under the vector's key.
        let sig = try Base64s.decodeRawUrl(try r.string("sig_b64url"))
        #expect(SoftAppKey(key).verify(Array(signing.utf8), sig), "\(name) sig")
        // Our header has the same fields, with a signature of our own that verifies.
        let nonce = try Base64s.decodeRawUrl(try r.string("nonce"))
        let vault = try r.string("vault_id")
        let query = try r.string("query")
        let header = try AppRequestSigning.headerValue(
            signer: SoftAppKey(key), method: try r.string("method"), path: try r.string("path"),
            query: query.isEmpty ? nil : query, vaultID: vault.isEmpty ? nil : vault, body: body, ts: ts, nonceBytes: nonce
        )
        let want = try r.string("header")
        let wantSig = try #require(want.range(of: "; sig="))
        #expect(header.hasPrefix(String(want[..<wantSig.upperBound])), "\(name) header")
        let ourSig = try #require(header.range(of: "; sig="))
        let ours = try Base64s.decodeRawUrl(String(header[ourSig.upperBound...]))
        #expect(SoftAppKey(key).verify(Array(signing.utf8), ours))
    }

    @Test func theRecoveryQRWithItsAPI() throws {
        let c = try RecoveryCode.parseQR(Array(try doc.string("recovery_qr").utf8))
        #expect(c.api == "https://account.vettid.org")
        #expect(c.vaultID == "test-vault-0001")
        #expect(RecoveryCodes.isValid(c.code))
    }

    @Test func theSigningStringIsTheSpecsLinesWithoutATrailingNewline() {
        let body = Array(#"{"secret":"x"}"#.utf8)
        let s = AppRequestSigning.signingString(
            method: "POST", path: "/api/vault/enroll/redeem", query: "", vaultID: "", akid: "00112233445566778899aabbccddeeff",
            ts: 1_791_000_000, nonce: "bm9uY2U", body: body
        )
        let lines = [
            "vettid/member-api/app/1", "POST", "/api/vault/enroll/redeem", "", "", "00112233445566778899aabbccddeeff", "1791000000",
        ]
        #expect(s == (lines + ["bm9uY2U", Bytes.hex(Bytes.sha256(body))]).joined(separator: "\n"))
        // A GET hashes the empty body; the query is the raw string without "?".
        let g = AppRequestSigning.signingString(
            method: "GET", path: "/api/vault/enclave", query: "release=ab%2Fc", vaultID: "v1", akid: "k", ts: 5, nonce: "n", body: []
        )
        #expect(g == "vettid/member-api/app/1\nGET\n/api/vault/enclave\nrelease=ab%2Fc\nv1\nk\n5\nn\n" +
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func theHeaderHasTheSpecsFieldsInOrderAndASignatureOverTheString() throws {
        let key = SoftAppKey()
        let nonce = (0..<16).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let h = try AppRequestSigning.headerValue(
            signer: key, method: "POST", path: "/api/vault/lock", query: nil, vaultID: "vid", body: Array("{}".utf8),
            ts: 1_791_000_000, nonceBytes: nonce
        )
        let parts = h.components(separatedBy: "; ")
        #expect(parts.map { String($0.prefix { $0 != "=" }) } == ["v", "vault", "kid", "ts", "nonce", "sig"])
        let f = Dictionary(uniqueKeysWithValues: parts.map { p in
            let i = p.firstIndex(of: "=")!
            return (String(p[..<i]), String(p[p.index(after: i)...]))
        })
        #expect(f["v"] == "1")
        #expect(f["vault"] == "vid")
        #expect(f["kid"] == AppRequestSigning.akid(try key.spki()))
        #expect(f["ts"] == "1791000000")
        #expect(f["nonce"] == Base64s.encodeRawUrl(nonce))
        for k in ["nonce", "sig"] {
            #expect(!(f[k] ?? "").contains { $0 == "=" || $0 == "+" || $0 == "/" }, "\(k): base64url without padding")
        }
        let msg = AppRequestSigning.signingString(
            method: "POST", path: "/api/vault/lock", query: "", vaultID: "vid", akid: f["kid"]!, ts: 1_791_000_000,
            nonce: f["nonce"]!, body: Array("{}".utf8)
        )
        #expect(key.verify(Array(msg.utf8), try Base64s.decodeRawUrl(f["sig"]!)))
        // An empty vault (a redeem) is written as nothing after `vault=`.
        let redeem = try AppRequestSigning.headerValue(signer: key, method: "POST", path: "/x", query: nil, vaultID: nil, body: [])
        #expect(redeem.contains("; vault=; kid="))
    }
}
