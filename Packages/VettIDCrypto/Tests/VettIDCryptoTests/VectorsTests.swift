import Testing
@testable import VettIDCrypto

/// The VAULT-MESSAGING §16 vectors of `keys.json` (vettid-vault testdata/vectors, copied to Resources/vectors): the
/// identity and relay keys from their seeds, the kids of the KEM keys, and the ik fingerprint. The KEM keys themselves
/// (ek from kem_seed) come with ML-KEM in I0.4, the mailbox ids with the relay code in I0.10. Mirrors the keys part
/// of vettid-android `VectorsTest` and `IkFingerprintTest`.
struct VectorsTests {
    private let keys: VectorDoc

    init() throws { keys = try VectorDoc.load("keys.json") }

    @Test(arguments: ["vault", "initiator"])
    func principalKeys(_ who: String) throws {
        let d = try keys.sub(who)
        let ik = try Ed25519PrivateKey.fromSeed(try d.hex("ik_seed_hex"))
        #expect(ik.publicKey == (try d.b64("ik_pk_b64")), "ik_pk")
        let relay = try Ed25519PrivateKey.fromSeed(try d.hex("relay_seed_hex"))
        #expect(relay.publicKey == (try d.b64("relay_pk_b64")), "relay_pk")
        try checkKid(d)
    }

    @Test(arguments: ["initiator_ephemeral", "etk"])
    func kemKids(_ who: String) throws {
        try checkKid(try keys.sub(who))
    }

    /// kid = SHA-256("vettid/vms/2/kid" || ek)[0:8] of the vector's ek.
    private func checkKid(_ d: VectorDoc) throws {
        let ek = try d.b64("ek_b64")
        #expect(ek.count == Suite.ekSize)
        #expect(Kid.of(ek).bytes == (try d.hex("kid_hex")), "kid")
        #expect(Array(Bytes.sha256(Array("vettid/vms/2/kid".utf8), ek).prefix(8)) == (try d.hex("kid_hex")), "kid (direct)")
    }

    @Test func ikFingerprint() throws {
        let fp = try keys.sub("ik_fingerprint")
        let ik = try keys.sub("vault").b64("ik_pk_b64")
        #expect(try fp.b64("ik_b64") == ik)
        #expect(Bytes.hex(try IkFingerprint.digest(ik)) == (try fp.str("sha256_hex")))
        #expect(try IkFingerprint.format(ik) == (try fp.str("shown")))
        #expect(IkFingerprint.formatB64(Base64s.encodeStd(ik)) == (try fp.str("shown")))
        #expect(try IkFingerprint.format(ik) == "9a1f bb7d 873e eafb 494b ef94 f072 7b25")
        // Labelled: not the plain hash of the key.
        #expect(!Bytes.hex(Bytes.sha256(ik)).hasPrefix("9a1fbb7d"))
        // Only 32 bytes.
        expectCrypto(.format) { _ = try IkFingerprint.format(rep(0, 31)) }
        #expect(IkFingerprint.formatB64("") == nil)
        #expect(IkFingerprint.formatB64("not base64!") == nil)
        #expect(IkFingerprint.formatB64(Base64s.encodeStd(rep(0, 33))) == nil)
    }

    /// The vectors parse under the strict rules they are written to.
    @Test func everyStringIsReadable() throws {
        #expect(keys.o.has("description"))
        #expect(try keys.sub("vault").str("relay_url") == "https://relay.vettid.org")
    }
}
