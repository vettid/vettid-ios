import Foundation
import Testing
@testable import VettIDCrypto

// Vector checks stay on one line each.
// swiftlint:disable line_length

/// VAULT-MESSAGING 0.32.0 §5.5 (the versioned, padded claim-check blob) and §10.5.1 (the vault's at-rest attachment
/// objects, which use the same framing) against vettid-vault's `blob.json` and `attachment.json`, byte for byte.
/// Mirrors vettid-android `BlobVectorsTest`.
@Suite struct BlobVectorsTests {
    let v: VectorDoc

    init() throws { v = try VectorDoc.load("blob.json") }

    @Test func sealReproducesTheVectorBlob() throws {
        let sealed = try deterministic(try v.hex("nonce_hex")) { try ClaimBlob.seal(try v.hex("content_hex"), key: try v.hex("key_hex")) }
        #expect(sealed.blob == (try v.hex("blob_hex")))
        #expect(sealed.sha256 == (try v.hex("sha256_hex")))
        #expect(Base64s.encodeStd(sealed.sha256) == (try v.str("sha256_b64")))
        #expect(UInt64(sealed.size) == (try v.num("size")))
        #expect(UInt64(sealed.blob.count) == (try v.num("blob_len")))
    }

    @Test func framingAadAndPadmeMatch() throws {
        #expect(try ClaimBlob.frame(v.hex("content_hex")) == v.hex("framed_hex"))
        #expect(ClaimBlob.aad() == (try v.hex("aad_hex")))
        #expect(ClaimBlob.padme(4 + (try v.num("size"))) == (try v.num("padme")))
        #expect(ClaimBlob.label == (try v.str("label")))
        #expect(UInt64(ClaimBlob.version) == (try v.num("version")))
        let samples = try v.o.array("padme_samples")
        #expect(!samples.isEmpty)
        for s in samples {
            let o = VectorDoc(o: try s.asObject())
            let l = try o.num("l")
            #expect(ClaimBlob.padme(l) == (try o.num("padme")), "padme(\(l))")
        }
    }

    @Test func theReferenceSizesFollowFromTheLayout() throws {
        let r = try v.sub("reference")
        let maxBlob = try r.num("max_blob_bytes")
        let maxContent = try r.num("attachment_max_bytes")
        #expect(ClaimBlob.blobLength(maxContent) == (try r.num("largest_blob_len")))
        #expect(ClaimBlob.blobLength(maxContent) <= maxBlob)
        #expect(ClaimBlob.blobLength(maxContent + 1) > maxBlob)
        // A thumbnail's stored object: the version, the nonce, the padded thumbnail and the tag.
        #expect(ClaimBlob.blobLength(try r.num("thumb_max_bytes")) == (try r.num("largest_thumb_object_len")))
    }

    @Test func openReturnsTheContent() throws {
        #expect(try ClaimBlob.open(v.hex("blob_hex"), key: v.hex("key_hex"), sha256: v.hex("sha256_hex"), size: v.num("size")) == v.hex("content_hex"))
    }

    @Test func everyMustFailCaseIsRefusedForItsReason() throws {
        let cases = try v.o.array("must_fail")
        #expect(cases.count == 6)
        for c in cases {
            let o = VectorDoc(o: try c.asObject())
            let name = try o.str("name")
            do {
                _ = try ClaimBlob.open(o.hex("blob_hex"), key: v.hex("key_hex"), sha256: o.hex("sha256_hex"), size: o.num("size"))
                Issue.record("\(name) opened")
            } catch let e as ClaimBlob.Refused {
                #expect(e.failure.rawValue == (try o.str("error")), "\(name)")
            }
        }
    }

    @Test func aFlippedByteIsRefusedBeforeDecryption() throws {
        // The hash is checked first: a wrong key would otherwise be a decryption failure.
        var blob = try v.hex("blob_hex")
        blob[40] ^= 1
        #expect(throws: ClaimBlob.Refused.self) { try ClaimBlob.open(blob, key: rep(0, 32), sha256: v.hex("sha256_hex"), size: v.num("size")) }
        do {
            _ = try ClaimBlob.open(blob, key: rep(0, 32), sha256: v.hex("sha256_hex"), size: v.num("size"))
        } catch let e as ClaimBlob.Refused {
            #expect(e.failure == .sha256)
        }
    }

    @Test func aRoundTripWithAFreshKeyAndNonce() throws {
        let content = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 * 31) }
        let s = try ClaimBlob.seal(content)
        #expect(UInt64(s.blob.count) == ClaimBlob.blobLength(UInt64(content.count)))
        #expect(try ClaimBlob.open(s.blob, key: s.key, sha256: s.sha256, size: UInt64(content.count)) == content)
        let other = try ClaimBlob.seal(content)
        #expect(other.key != s.key, "a blob key is used for one blob only")
        expectCrypto(.format) { _ = try ClaimBlob.seal([]) }
        expectCrypto(.key) { _ = try ClaimBlob.seal([1], key: rep(1, 31)) }
    }

    @Test func theAtRestObjectsUseTheSameFraming() throws {
        let a = try VectorDoc.load("attachment.json")
        let framed = try ClaimBlob.frame(a.hex("content_hex"))
        #expect(framed == (try a.hex("framed_hex")))
        let objects = try a.o.array("objects")
        #expect(objects.count == 2)
        for value in objects {
            let o = VectorDoc(o: try value.asObject())
            let part = try o.str("part")
            let aad = Array("\(try a.str("label"))\u{0}\(try a.str("vault_id"))\u{0}\(try a.str("att_id"))\u{0}\(part)\u{0}".utf8) + [1]
            #expect(aad == (try o.hex("aad_hex")), "aad \(part)")
            let ct = try XChaCha20Poly1305.seal(key: a.hex("k_att_hex"), nonce: o.hex("nonce_hex"), aad: aad, plaintext: framed)
            let object = [1] + (try o.hex("nonce_hex")) + ct
            #expect(object == (try o.hex("object_hex")), "object \(part)")
            #expect(UInt64(object.count) == (try o.num("object_len")))
            #expect(try o.str("store_key") == "vaults/\(try a.str("vault_id"))/att/\(try a.str("att_id").lowercased())" + (part == "t" ? ".t" : ""))
        }
    }
}

// swiftlint:enable line_length
