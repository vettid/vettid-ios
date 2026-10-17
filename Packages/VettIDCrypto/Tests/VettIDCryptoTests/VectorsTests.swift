import Testing
@testable import VettIDCrypto

/// The VAULT-MESSAGING §16 vectors (vettid-vault testdata/vectors, copied to Resources/vectors): every value is checked
/// from the receiving side, and every envelope is also rebuilt from the sending side, byte for byte, with the vectors'
/// deterministic randomness. The mailbox ids of keys.json come with the relay code in I0.10. Mirrors vettid-android
/// `VectorsTest` and `IkFingerprintTest`.
struct VectorsTests {
    private let keys: VectorDoc

    init() throws { keys = try VectorDoc.load("keys.json") }

    /// The KEM key of a keys.json entry, checked against its ek, kid and seed.
    private func kem(_ who: String) throws -> KemPrivateKey {
        let d = try keys.sub(who)
        let k = try KemPrivateKey.fromSeed(try d.hex("kem_seed_hex"))
        let ek = k.publicKey.bytes
        #expect(ek.count == Suite.ekSize)
        #expect(ek == (try d.b64("ek_b64")), "ek of \(who)")
        #expect(k.publicKey.kid.bytes == (try d.hex("kid_hex")), "kid of \(who)")
        #expect(Array(Bytes.sha256(Array("vettid/vms/2/kid".utf8), ek).prefix(8)) == (try d.hex("kid_hex")), "kid (direct)")
        #expect(try k.seed() == (try d.hex("kem_seed_hex")), "seed round trip")
        return k
    }

    @Test(arguments: ["vault", "initiator"])
    func principalKeys(_ who: String) throws {
        let d = try keys.sub(who)
        let ik = try Ed25519PrivateKey.fromSeed(try d.hex("ik_seed_hex"))
        #expect(ik.publicKey == (try d.b64("ik_pk_b64")), "ik_pk")
        let relay = try Ed25519PrivateKey.fromSeed(try d.hex("relay_seed_hex"))
        #expect(relay.publicKey == (try d.b64("relay_pk_b64")), "relay_pk")
        _ = try kem(who)
    }

    @Test func kemKeys() throws {
        // The vault kid and the ETK kid are in §16 too.
        #expect(try kem("vault").publicKey.kid.description == "40d6c2c8471844a9")
        #expect(try kem("etk").publicKey.kid.description == "d6c9d114385e91df")
        _ = try kem("initiator_ephemeral")
    }

    @Test func hpke() throws {
        let d = try VectorDoc.load("hpke.json")
        #expect(try d.str("kem_id") == "0x647a")
        #expect(try d.str("kdf_id") == "0x0001")
        #expect(try d.str("aead_id") == "0x0003")
        let vault = try kem("vault")
        #expect(vault.publicKey.bytes == (try d.b64("recipient_ek_b64")), "recipient ek")
        let rnd = try d.hex("encapsulation_randomness_hex")
        let info = Array(try d.str("info").utf8)

        let exposed = try deterministic(rnd) { try HpkeSender.setupExposingSchedule(vault.publicKey, info: info) }
        let (sender, ss, schedule) = (exposed.sender, exposed.sharedSecret, exposed.schedule)
        #expect(Int(try d.num("enc_len")) == Suite.encSize)
        #expect(sender.enc == (try d.b64("enc_b64")), "enc")
        #expect(ss == (try d.hex("shared_secret_hex")), "shared_secret")
        #expect(schedule.key == (try d.hex("key_hex")), "key")
        #expect(schedule.baseNonce == (try d.hex("base_nonce_hex")), "base_nonce")
        #expect(schedule.exporterSecret == (try d.hex("exporter_secret_hex")), "exporter_secret")
        // The public setup draws the same randomness and gives the same enc.
        let plain = try deterministic(rnd) { try HpkeSender.setup(vault.publicKey, info: info) }
        #expect(plain.enc == sender.enc)

        // Independent derivation of the X-Wing combiner and the RFC 9180 key schedule (as vettid-vault
        // internal/hpkederand), from the ML-KEM-768, X25519 and SHA-3 primitives alone.
        let ek = vault.publicKey.bytes
        let pkX = Array(ek[1184...])
        let (ctM, ssM) = try MLKEM768.encapsulate(pk: Array(ek[0..<1184]), m: Array(rnd[0..<32]))
        let ctX = try X25519.publicKey(Array(rnd[32..<64]))
        let ssX = try X25519.sharedSecret(Array(rnd[32..<64]), pkX)
        #expect(ctM + ctX == (try d.b64("enc_b64")), "enc (independent)")
        #expect(SHA3.sha3_256(ssM, ssX, ctX, pkX, [0x5C, 0x2E, 0x2F, 0x2F, 0x5E, 0x5C]) == (try d.hex("shared_secret_hex")))

        let suiteID = Array("HPKE".utf8) + [0x64, 0x7A, 0x00, 0x01, 0x00, 0x03]
        func labeledExtract(_ salt: [UInt8], _ label: String, _ ikm: [UInt8]) -> [UInt8] {
            Hkdf.extract(salt: salt, ikm: Array("HPKE-v1".utf8) + suiteID + Array(label.utf8) + ikm)
        }
        func labeledExpand(_ prk: [UInt8], _ label: String, _ ctx: [UInt8], _ l: Int) throws -> [UInt8] {
            let info = Bytes.uintBE(UInt64(l), 2) + Array("HPKE-v1".utf8) + suiteID + Array(label.utf8) + ctx
            return try Hkdf.expand(prk: prk, info: info, length: l)
        }
        let ksc = [0] + labeledExtract([], "psk_id_hash", []) + labeledExtract([], "info_hash", info)
        let secret = labeledExtract(try d.hex("shared_secret_hex"), "secret", [])
        #expect(try labeledExpand(secret, "key", ksc, 32) == (try d.hex("key_hex")))
        #expect(try labeledExpand(secret, "base_nonce", ksc, 12) == (try d.hex("base_nonce_hex")))
        let exporterSecret = try labeledExpand(secret, "exp", ksc, 32)
        #expect(exporterSecret == (try d.hex("exporter_secret_hex")))
        let exported = try labeledExpand(exporterSecret, "sec", Array("vettid/vms/2/hs-ks".utf8), 32)
        #expect(try sender.export("vettid/vms/2/hs-ks", 32) == exported)

        // The recipient derives the same context from enc.
        let recipient = try HpkeRecipient.setup(enc: sender.enc, key: vault, info: info)
        #expect(try recipient.export("vettid/vms/2/hs-ks", 32) == (try sender.export("vettid/vms/2/hs-ks", 32)))
    }

    @Test func envelopeSealed() throws {
        let d = try VectorDoc.load("envelope_sealed.json")
        let h = try VectorDoc.load("hpke.json")
        let vault = try kem("vault")
        let raw = try d.b64("envelope_b64")
        #expect(raw.count == 1668)
        #expect(raw.count == Int(try d.num("envelope_len")))
        #expect(try d.num("padded_len") == 512)
        let e = try Envelope.parse(raw)
        #expect(e.senderKid.bytes == (try d.hex("sender_kid_hex")))
        #expect(e.recipientKid.bytes == (try d.hex("recipient_kid_hex")))
        #expect(Array(raw[20..<1140]) == (try h.b64("enc_b64")), "enc in header")
        let (padded, _) = try Envelope.openSealed(e, key: vault)
        #expect(padded == (try d.hex("padded_hex")))
        #expect(try Padding.unpad(padded) == Array(try d.str("inner").utf8))
        let inner = try Inner.decode(padded, .sealed)
        #expect(try inner.marshal(.sealed) == Array(try d.str("inner").utf8))

        // Sender side, byte for byte.
        let (built, _) = try deterministic(try h.hex("encapsulation_randomness_hex")) {
            try Envelope.sealSealed(vault.publicKey, senderKid: Kid.anonymous, padded: Inner.encode(inner, .sealed))
        }
        #expect(built == raw, "envelope")
    }

    @Test func envelopeSession() throws {
        let d = try VectorDoc.load("envelope_session.json")
        let raw = try d.b64("envelope_b64")
        #expect(raw.count == 572)
        #expect(raw.count == Int(try d.num("envelope_len")))
        let inner = try Inner.parse(Array(try d.str("inner").utf8), .session)
        #expect(try inner.marshal(.session) == Array(try d.str("inner").utf8))
        let built = try deterministic(try d.hex("nonce_hex")) {
            try Envelope.sealSession(
                key: d.hex("k_i2r_hex"),
                senderKid: Kid(d.hex("sender_kid_hex")),
                recipientKid: Kid(d.hex("recipient_kid_hex")),
                padded: Inner.encode(inner, .session)
            )
        }
        #expect(built == raw, "envelope")
        let opened = try Inner.decode(try Envelope.openSession(try Envelope.parse(raw), key: try d.hex("k_i2r_hex")), .session)
        #expect(opened.seq == 1)
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
}
