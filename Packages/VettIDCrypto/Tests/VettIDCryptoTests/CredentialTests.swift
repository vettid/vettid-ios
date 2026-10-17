import Foundation
import Testing
@testable import VettIDCrypto

// Reference checks stay on one line each.
// swiftlint:disable line_length

/// A request id other than the one a value was sealed for.
private let otherRequestID = "01JB2Z6V9K3M4N5P6Q7R8S9T31"

/// VAULT-MESSAGING §3.5 (the Protean Credential's wire crypto) and §10.12 (grant seal) on the app side. §16 has no
/// vector for them, so they are checked against vettid-vault's own code: `Resources/reference/credential.json` holds
/// what its `credwire`, `sharewire` and `features/credential` produce from fixed seeds (`scripts/credential-reference`),
/// and the Swift code opens each sealed value and reproduces each rotation statement byte for byte. Plus the
/// round trips and refusals of vettid-android's `CredentialAndItemsTest` and `GrantSealTest`.
@Suite struct CredentialReferenceTests {
    let r: VectorDoc

    init() throws { r = try VectorDoc.load("credential.json", subdirectory: "reference") }

    @Test func aPayloadSealedByTheVaultsCodeOpensWithTheLtk() throws {
        let ltk = try KemPrivateKey.fromSeed(r.hex("ltk_seed_hex"))
        let opened = try CredentialSeal.openPayload(ltk: ltk, vaultID: r.str("vault_id"), utkID: r.str("utk_id"), type: r.str("type"), innerID: r.str("request_id"), sealed: r.hex("payload_sealed_hex"))
        #expect(opened == Array(try r.str("payload").utf8))
    }

    @Test func aValueSealedByTheVaultsCodeOpensWithTheReplyKey() throws {
        let reply = try KemPrivateKey.fromSeed(r.hex("reply_seed_hex"))
        let opened = try CredentialSeal.openValue(reply: reply, vaultID: r.str("vault_id"), innerID: r.str("request_id"), sealed: r.hex("value_sealed_hex"))
        #expect(opened == Array(try r.str("value").utf8))
        expectCrypto(.decrypt) { _ = try CredentialSeal.openValue(reply: reply, vaultID: r.str("vault_id"), innerID: otherRequestID, sealed: r.hex("value_sealed_hex")) }
    }

    @Test func aGrantSealedByTheVaultsCodeOpensForItsGrantAndFetch() throws {
        let reply = try KemPrivateKey.fromSeed(r.hex("grant_seed_hex"))
        let opened = try GrantSeal.openValue(reply: reply, grantID: r.str("grant_id"), fetchID: r.str("fetch_id"), sealed: r.hex("grant_sealed_hex"))
        #expect(opened == Array(try r.str("grant").utf8))
        expectCrypto(.decrypt) { _ = try GrantSeal.openValue(reply: reply, grantID: r.str("fetch_id"), fetchID: r.str("grant_id"), sealed: r.hex("grant_sealed_hex")) }
    }

    @Test func rotationStatementsMatchTheVaultsByteForByte() throws {
        let seeds = try r.o.array("rotation_seeds_hex").map { try Bytes.unhex(try $0.asString()) }
        let keys = try seeds.map { try Ed25519PrivateKey.fromSeed($0) }
        let want = try r.o.array("rotations").map { try $0.asString() }
        #expect(want.count == 2)
        #expect(try CredentialKeyRotation.create(old: keys[0], new: keys[1]).marshal() == want[0])
        #expect(try CredentialKeyRotation.create(old: keys[1], new: keys[2]).marshal() == want[1])
        let chain = try want.map { try CredentialKeyRotation.parse(try StrictJson.parseObject(Array($0.utf8))) }
        #expect(try CredentialKeyRotation.followChain(pinned: keys[0].publicKey, chain) == keys[2].publicKey)
    }

    /// The other direction: what the Swift code seals with fixed HPKE randomness (64 × 0x71, 0x72, 0x73) was opened by
    /// the reference (`go run . open …` in `scripts/credential-reference`); the hashes pin those exact bytes.
    @Test func whatSwiftSealsIsWhatTheVaultsCodeOpened() throws {
        let ltk = try KemPrivateKey.fromSeed(r.hex("ltk_seed_hex"))
        let reply = try KemPrivateKey.fromSeed(r.hex("reply_seed_hex"))
        let grant = try KemPrivateKey.fromSeed(r.hex("grant_seed_hex"))
        let utk = Utk(id: try r.str("utk_id"), ek: ltk.publicKey, expiresAt: Date(timeIntervalSince1970: 0))
        let p = try deterministic(rep(0x71, 64)) { try CredentialSeal.sealPayload(utk: utk, vaultID: r.str("vault_id"), type: r.str("type"), innerID: r.str("request_id"), payload: Array(r.str("payload").utf8)) }
        let v = try deterministic(rep(0x72, 64)) { try CredentialSeal.sealValue(reply: reply.publicKey, vaultID: r.str("vault_id"), innerID: r.str("request_id"), value: Array(r.str("value").utf8)) }
        let g = try deterministic(rep(0x73, 64)) { try GrantSeal.sealValue(reply: grant.publicKey, grantID: r.str("grant_id"), fetchID: r.str("fetch_id"), value: Array(r.str("grant").utf8)) }
        #expect(Bytes.hex(Bytes.sha256(p)) == "97138804035a9527b5a0a215815ab94f396462b13b6d11d5ef249b3af20ab2f4")
        #expect(Bytes.hex(Bytes.sha256(v)) == "1e3d8c8b1a43a9262be005c55d0481cbd18d0d09670ecda66d7fa9007657665c")
        #expect(Bytes.hex(Bytes.sha256(g)) == "8869872253a78abd0eb4d1da0536e1fffaca562498efe85eaa36897e29beff2a")
    }

    @Test func theHeaderOfTheVaultsCredentialBlob() throws {
        let cek = try KemPrivateKey.fromSeed(r.hex("cek_seed_hex"))
        #expect(cek.publicKey.kid.description == (try r.str("cek_kid")))
        let h = try CredentialBlobHeader.parse(r.hex("credential_blob_hex"))
        #expect(h.version == (try r.num("blob_version")))
        #expect(h.cekKid == cek.publicKey.kid)
    }
}

@Suite struct CredentialTests {
    let vaultID = "test-vault-0001"
    let requestID = "01JB2Z6V9K3M4N5P6Q7R8S9T30"

    @Test func utkPayloadIsBoundToTypeAndRequest() throws {
        let ltk = try KemPrivateKey.generate()
        let utk = try Utk.parse(try StrictJson.parseObject(
            JsonBuilder().string("utk_id", "0123456789abcdef").base64("ek", ltk.publicKey.bytes).string("expires_at", "2026-11-01T12:00:00.000Z").bytes()
        ))
        let payload = Array(#"{"password":"correct horse"}"#.utf8)
        let sealed = try CredentialSeal.sealPayload(utk: utk, vaultID: vaultID, type: "credential.unlock", innerID: requestID, payload: payload)
        #expect(sealed.count == Suite.encSize + payload.count + Suite.tagSize)
        #expect(try CredentialSeal.openPayload(ltk: ltk, vaultID: vaultID, utkID: utk.id, type: "credential.unlock", innerID: requestID, sealed: sealed) == payload)
        // Another type, request, vault or UTK id does not open it.
        for c in [
            ("credential.rotate", requestID, vaultID, utk.id),
            ("credential.unlock", otherRequestID, vaultID, utk.id),
            ("credential.unlock", requestID, "other-vault", utk.id),
            ("credential.unlock", requestID, vaultID, "fedcba9876543210"),
        ] {
            expectCrypto(.decrypt) { _ = try CredentialSeal.openPayload(ltk: ltk, vaultID: c.2, utkID: c.3, type: c.0, innerID: c.1, sealed: sealed) }
        }
        expectCrypto(.format) { _ = try CredentialSeal.sealPayload(utk: utk, vaultID: vaultID, type: "x", innerID: requestID, payload: rep(0, 16 * 1024 + 1)) }
        expectCrypto(.format) {
            _ = try Utk.parse(try StrictJson.parseObject(Array(#"{"utk_id":"0123456789ABCDEF","ek":"","expires_at":"2026-11-01T12:00:00.000Z"}"#.utf8)))
        }
    }

    @Test func replyKeyValues() throws {
        let reply = try KemPrivateKey.generate()
        let value = Array(#"{"fields":[{"field_id":"f1","value":"abandon abandon"}],"notes":"n"}"#.utf8)
        let sealed = try CredentialSeal.sealValue(reply: reply.publicKey, vaultID: vaultID, innerID: requestID, value: value)
        #expect(try CredentialSeal.openValue(reply: reply, vaultID: vaultID, innerID: requestID, sealed: sealed) == value)
        expectCrypto(.decrypt) { _ = try CredentialSeal.openValue(reply: reply, vaultID: vaultID, innerID: otherRequestID, sealed: sealed) }
        expectCrypto(.decrypt) { _ = try CredentialSeal.openValue(reply: try KemPrivateKey.generate(), vaultID: vaultID, innerID: requestID, sealed: sealed) }
        expectCrypto(.decrypt) { _ = try CredentialSeal.openValue(reply: reply, vaultID: vaultID, innerID: requestID, sealed: Array(sealed.prefix(100))) }
        expectCrypto(.format) { _ = try CredentialSeal.sealValue(reply: reply.publicKey, vaultID: vaultID, innerID: requestID, value: rep(0, 64 * 1024 + 1)) }
    }

    @Test func blobHeader() throws {
        let kid = rep(7, 8)
        let blob = [1] + Bytes.uintBE(3, 8) + kid + rep(0, CredentialBlobHeader.minSize - 17)
        let h = try CredentialBlobHeader.parse(blob)
        #expect(h.version == 3)
        #expect(h.cekKid == (try Kid(kid)))
        var wrongFormat = blob
        wrongFormat[0] = 2
        expectCrypto(.format) { _ = try CredentialBlobHeader.parse(wrongFormat) }
        expectCrypto(.format) { _ = try CredentialBlobHeader.parse(Array(blob.dropLast())) }
        expectCrypto(.format) { _ = try CredentialBlobHeader.parse(blob + rep(0, CredentialBlobHeader.maxInner + 1)) }
        expectCrypto(.format) { _ = try CredentialBlobHeader.parse([1] + Bytes.uintBE(0, 8) + Array(blob[9...])) }
        expectCrypto(.format) { _ = try CredentialBlobHeader.parse([1] + Bytes.uintBE(StrictJson.maxSafeInteger + 1, 8) + Array(blob[9...])) }
    }

    @Test func credentialKeyRotationChain() throws {
        let k1 = Ed25519PrivateKey.generate()
        let k2 = Ed25519PrivateKey.generate()
        let k3 = Ed25519PrivateKey.generate()
        let r1 = try CredentialKeyRotation.create(old: k1, new: k2)
        let r2 = try CredentialKeyRotation.parse(try StrictJson.parseObject(Array(try CredentialKeyRotation.create(old: k2, new: k3).marshal().utf8)))
        #expect(try CredentialKeyRotation.followChain(pinned: k1.publicKey, [r1, r2]) == k3.publicKey)
        expectCrypto(.signature) { _ = try CredentialKeyRotation.followChain(pinned: k1.publicKey, [r2]) }
        expectCrypto(.signature) { _ = try CredentialKeyRotation.followChain(pinned: k1.publicKey, []) }
        expectCrypto(.signature) { _ = try CredentialKeyRotation.create(old: k1, new: k1) }
        // A statement whose new-key signature is another statement's does not verify.
        let forged = CredentialKeyRotation(oldKey: r1.oldKey, newKey: r1.newKey, sigOld: r1.sigOld, sigNew: r2.sigNew)
        expectCrypto(.signature) { try forged.verify() }
        expectCrypto(.signature) { _ = try CredentialKeyRotation.followChain(pinned: k1.publicKey, Array(repeating: r1, count: 33)) }
    }
}

/// A granted item's content sealed to the fetching device (§10.12): bound to the grant and the fetch. Mirrors
/// vettid-android `GrantSealTest`.
@Suite struct GrantSealTests {
    let content = Array(#"{"item_id":"01J","version":2,"name":"Allergies","category":"medical","fields":[]}"#.utf8)

    @Test func opensWithTheReplyKeyForTheSameGrantAndFetch() throws {
        let k = try KemPrivateKey.generate()
        let sealed = try GrantSeal.sealValue(reply: k.publicKey, grantID: "01GRANT", fetchID: "01FETCH", value: content)
        #expect(try GrantSeal.openValue(reply: k, grantID: "01GRANT", fetchID: "01FETCH", sealed: sealed) == content)
    }

    @Test func anotherFetchOrGrantDoesNotOpen() throws {
        let k = try KemPrivateKey.generate()
        let sealed = try GrantSeal.sealValue(reply: k.publicKey, grantID: "01GRANT", fetchID: "01FETCH", value: content)
        expectCrypto(.decrypt) { _ = try GrantSeal.openValue(reply: k, grantID: "01GRANT", fetchID: "01OTHER", sealed: sealed) }
        expectCrypto(.decrypt) { _ = try GrantSeal.openValue(reply: k, grantID: "01OTHER", fetchID: "01FETCH", sealed: sealed) }
        expectCrypto(.decrypt) { _ = try GrantSeal.openValue(reply: try KemPrivateKey.generate(), grantID: "01GRANT", fetchID: "01FETCH", sealed: sealed) }
        expectCrypto(.decrypt) { _ = try GrantSeal.openValue(reply: k, grantID: "01GRANT", fetchID: "01FETCH", sealed: Array(sealed.prefix(100))) }
    }
}

// swiftlint:enable line_length
