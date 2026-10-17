import Foundation
import Testing
@testable import VettIDCrypto

/// The HPKE and KEM cases of vettid-android `PrimitivesTest`, the padding, inner and envelope cases of `WireFormatTest`,
/// and the SHA-3 and ML-KEM building blocks.
struct HpkeTests {
    @Test func sha3KnownAnswers() {
        // FIPS 202 values for the empty input.
        #expect(Bytes.hex(SHA3.sha3_256([])) == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
        #expect(Bytes.hex(SHA3.shake256([], outputLength: 32)) == "46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762f")
        // The parts are hashed as one input.
        #expect(SHA3.sha3_256(Array("ab".utf8), Array("c".utf8)) == SHA3.sha3_256(Array("abc".utf8)))
        #expect(Bytes.hex(SHA3.sha3_256(Array("abc".utf8))) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
    }

    @Test func mlkemRoundTripAndImplicitRejection() throws {
        let (pk, sk) = try MLKEM768.keypair(coins: rep(1, 64))
        #expect(pk.count == 1184 && sk.count == 2400)
        let (ct, ss) = try MLKEM768.encapsulate(pk: pk, m: rep(2, 32))
        #expect(try MLKEM768.decapsulate(sk: sk, ct: ct) == ss)
        // A forged ciphertext decapsulates to some other secret, without an error (FIPS 203 implicit rejection).
        var forged = ct
        forged[0] ^= 1
        #expect(try MLKEM768.decapsulate(sk: sk, ct: forged) != ss)
        // Deterministic in its randomness.
        #expect(try MLKEM768.keypair(coins: rep(1, 64)).pk == pk)
        #expect(try MLKEM768.encapsulate(pk: pk, m: rep(2, 32)).ct == ct)
    }

    @Test func hpkeRoundTripSingleUseAndExport() throws {
        let sk = try KemPrivateKey.generate()
        let s = try HpkeSender.setup(sk.publicKey, info: Array("info".utf8))
        let ct = try s.seal(aad: Array("aad".utf8), plaintext: Array("hello".utf8))
        expectCrypto(.used) { _ = try s.seal(aad: Array("aad".utf8), plaintext: Array("again".utf8)) }
        let r = try HpkeRecipient.setup(enc: s.enc, key: sk, info: Array("info".utf8))
        #expect(try r.open(aad: Array("aad".utf8), ciphertext: ct) == Array("hello".utf8))
        expectCrypto(.used) { _ = try r.open(aad: Array("aad".utf8), ciphertext: ct) }
        #expect(try s.export("x", 32) == (try r.export("x", 32)))
        // Wrong info or aad fails.
        expectCrypto(.decrypt) {
            _ = try HpkeRecipient.setup(enc: s.enc, key: sk, info: Array("other".utf8)).open(aad: Array("aad".utf8), ciphertext: ct)
        }
        expectCrypto(.decrypt) {
            _ = try HpkeRecipient.setup(enc: s.enc, key: sk, info: Array("info".utf8)).open(aad: Array("aaX".utf8), ciphertext: ct)
        }
        expectCrypto(.key) { _ = try HpkeRecipient.setup(enc: rep(0, 1119), key: sk, info: []) }
        // Two senders to the same key never share an encapsulation.
        #expect(try HpkeSender.setup(sk.publicKey, info: []).enc != s.enc)
        // A forged X25519 half that gives the all-zero secret is refused (as Go refuses it).
        var lowOrder = s.enc
        for i in 1088..<1120 { lowOrder[i] = 0 }
        expectCrypto(.decrypt) { _ = try HpkeRecipient.setup(enc: lowOrder, key: sk, info: []) }
    }

    @Test func kemKeysAreValidated() throws {
        let sk = try KemPrivateKey.fromSeed(rep(5, 32))
        let ek = sk.publicKey.bytes
        expectCrypto(.key) { _ = try KemPublicKey.parse(Array(ek.prefix(1215))) }
        // A coefficient >= q (3329 = 0xd01): set the first 12-bit value to 0xfff.
        var bad = ek
        bad[0] = 0xFF
        bad[1] |= 0x0F
        expectCrypto(.key) { _ = try KemPublicKey.parse(bad) }
        #expect(try KemPublicKey.parse(ek) == sk.publicKey)
        expectCrypto(.key) { _ = try KemPrivateKey.fromSeed(rep(5, 31)) }
        sk.destroy()
        expectCrypto(.key) { _ = try sk.seed() }
        expectCrypto(.key) { _ = try HpkeRecipient.setup(enc: rep(0, 1120), key: sk, info: []) }
        #expect(sk.description.contains("redacted"))
    }

    @Test func padding() throws {
        #expect(try Padding.paddedLen(0) == 512)
        #expect(try Padding.paddedLen(511) == 512)
        #expect(try Padding.paddedLen(512) == 1024)
        #expect(try Padding.paddedLen(16_383) == 16_384)
        #expect(try Padding.paddedLen(16_384) == 32_768)
        #expect(try Padding.paddedLen(245_759) == 245_760)
        expectCrypto(.format) { _ = try Padding.paddedLen(245_760) }
        let p = try Padding.pad(Array("{}".utf8))
        #expect(try Padding.unpad(p) == Array("{}".utf8))
        // Over-padding, a wrong marker, no marker, bad sizes.
        expectCrypto(.format) { _ = try Padding.unpad(try Padding.padFixed(Array("{}".utf8), 1024)) }
        var wrongMarker = p
        wrongMarker[2] = 0x81
        expectCrypto(.format) { _ = try Padding.unpad(wrongMarker) }
        expectCrypto(.format) { _ = try Padding.unpad(rep(0, 512)) }
        expectCrypto(.format) { _ = try Padding.unpad(Array(p.prefix(511))) }
        var trailing = p
        trailing[511] = 1
        expectCrypto(.format) { _ = try Padding.unpad(trailing) }
        #expect(try Padding.unpadFixed(try Padding.padFixed(Array("{}".utf8), 4096), 4096) == Array("{}".utf8))
        expectCrypto(.format) { _ = try Padding.unpadFixed(try Padding.padFixed(Array("{}".utf8), 4096), 12_288) }
    }

    private let id = "01JB2Z6V9K3M4N5P6Q7R8S9T0V"

    @Test func innerRules() throws {
        let t0 = try Timestamps.parseSeconds("2026-10-01T12:00:00Z")
        let ok = Inner(id: id, type: "message.send", ts: t0, seq: 3)
        let okJSON = #"{"v":1,"id":"\#(id)","type":"message.send","ts":"2026-10-01T12:00:00.000Z","seq":3,"body":{}}"#
        #expect(try ok.marshal(.session) == Array(okJSON.utf8))
        let resp = Inner(
            id: id, type: "x.y", ts: t0, re: id, status: "error", error: InnerError("not_found", "m"), body: Array(#"{"a" : 1}"#.utf8)
        )
        let respJSON = #"{"v":1,"id":"\#(id)","type":"x.y","ts":"2026-10-01T12:00:00.000Z","re":"\#(id)","status":"error","# +
            #""error":{"code":"not_found","message":"m"},"body":{"a":1}}"#
        #expect(try resp.marshal(.sealed) == Array(respJSON.utf8))
        let bad = [
            Inner(id: "01jb2z6v9k3m4n5p6q7r8s9t0v", type: "x", ts: t0),
            Inner(id: "81JB2Z6V9K3M4N5P6Q7R8S9T0V", type: "x", ts: t0),
            Inner(id: id, type: "X", ts: t0),
            Inner(id: id, type: "a..b", ts: t0),
            Inner(id: id, type: "a.", ts: t0),
            Inner(id: id, type: "1a", ts: t0),
            Inner(id: id, type: "x", ts: t0, seq: 1), // seq in sealed mode
            Inner(id: id, type: "x", ts: t0, re: id), // re without status
            Inner(id: id, type: "x", ts: t0, re: id, status: "ok", error: InnerError("e")),
            Inner(id: id, type: "x", ts: t0, re: id, status: "error"),
            Inner(id: id, type: "x", ts: t0, re: id, status: "error", error: InnerError("Bad")),
        ]
        for b in bad { expectCrypto(.format, "\(b)") { _ = try b.marshal(.sealed) } }
        expectCrypto(.format) { _ = try Inner(id: id, type: "x", ts: t0).marshal(.session) }

        func parse(_ s: String, _ mode: Mode = .sealed) throws -> Inner { try Inner.parse(Array(s.utf8), mode) }
        let base = #""v":1,"id":"\#(id)","type":"x","ts":"2026-10-01T12:00:00.000Z""#
        #expect(try parse("{\(base),\"unknown\":[1],\"body\":{}}").type == "x")
        let malformed = [
            "{\(base)}", // no body
            "{\(base),\"body\":[]}",
            "{\(base),\"body\":{\"a\":1,\"a\":2}}",
            "{\(base),\"seq\":1,\"body\":{}}",
            #"{"v":2,"id":"\#(id)","type":"x","ts":"2026-10-01T12:00:00.000Z","body":{}}"#,
            #"{"v":1,"id":"\#(id)","type":"x","ts":"2026-10-01T12:00:00Z","body":{}}"#,
            #"{"v":1,"id":"\#(id)","type":"x","ts":"2026-10-01T12:00:00.000+00:00","body":{}}"#,
            "{\(base),\"re\":\"\",\"status\":\"ok\",\"body\":{}}",
        ]
        for s in malformed { expectCrypto(.format, "\(s)") { _ = try parse(s) } }
        expectCrypto(.format) { _ = try parse("{\(base),\"body\":{}}", .session) }

        // Freshness.
        let fresh = Inner(id: id, type: "x", ts: t0, exp: t0.addingTimeInterval(60))
        try fresh.checkTime(now: t0, durable: true)
        expectCrypto(.time) { try fresh.checkTime(now: t0.addingTimeInterval(-301), durable: true) }
        expectCrypto(.time) { try fresh.checkTime(now: t0.addingTimeInterval(61), durable: false) }
        expectCrypto(.time) { try Inner(id: id, type: "x", ts: t0).checkTime(now: t0.addingTimeInterval(17 * 86_400), durable: true) }
        try Inner(id: id, type: "x", ts: t0).checkTime(now: t0.addingTimeInterval(17 * 86_400), durable: false)
    }

    @Test func envelopeStructure() throws {
        let t0 = try Timestamps.parseSeconds("2026-10-01T12:00:00Z")
        let sk = try KemPrivateKey.generate()
        let padded = try Inner.encode(Inner(id: id, type: "x", ts: t0), .sealed)
        let (env, _) = try Envelope.sealSealed(sk.publicKey, senderKid: Kid.anonymous, padded: padded)
        #expect(env.count == Envelope.overheadSealed + 512)
        _ = try Envelope.parse(env)
        func mutate(_ i: Int, _ v: UInt8) -> [UInt8] {
            var c = env
            c[i] = v
            return c
        }
        expectCrypto(.format) { _ = try Envelope.parse(mutate(0, 1)) }
        expectCrypto(.suite) { _ = try Envelope.parse(mutate(1, 1)) }
        expectCrypto(.suite) { _ = try Envelope.parse(mutate(1, 3)) }
        expectCrypto(.format) { _ = try Envelope.parse(mutate(2, 3)) }
        expectCrypto(.format) { _ = try Envelope.parse(mutate(3, 1)) }
        expectCrypto(.format) { _ = try Envelope.parse(Array(env.prefix(env.count - 1))) }
        expectCrypto(.format) { _ = try Envelope.parse(Array(env.prefix(19))) }
        // A tampered header (the AAD) or ciphertext does not open.
        expectCrypto(.decrypt) { _ = try Envelope.openSealed(try Envelope.parse(mutate(5, 9)), key: sk) }
        expectCrypto(.decrypt) { _ = try Envelope.openSealed(try Envelope.parse(mutate(env.count - 1, env[env.count - 1] &+ 1)), key: sk) }
        // The kid selects the key; no other key is tried.
        expectCrypto(.protocolViolation) { _ = try Envelope.openSealed(try Envelope.parse(env), key: try KemPrivateKey.generate()) }
        expectCrypto(.protocolViolation) { _ = try Envelope.openSession(try Envelope.parse(env), key: rep(0, 32)) }
        // The sealer's header is the envelope's, and exports match the recipient's.
        let sealer = try Sealer(sk.publicKey, senderKid: Kid.anonymous)
        let sealed = try sealer.seal(padded)
        #expect(Array(sealed.prefix(Envelope.headerSealed)) == sealer.header)
        let (_, exporter) = try Envelope.openSealed(try Envelope.parse(sealed), key: sk)
        #expect(try exporter.export("vettid/vms/2/hs-ks", 32) == (try sealer.export("vettid/vms/2/hs-ks", 32)))
    }
}
