import Foundation
// The vector tests check every value of a file in one place, as vettid-android does.
// swiftlint:disable function_body_length
import Testing
@testable import VettIDCrypto

/// The §16 handshake and invite vectors, from the receiving side (every intermediate value) and the sending side (the
/// whole handshake through Initiator / PendingInit / Responder, byte for byte), and the mailbox ids of keys.json.
/// Mirrors the handshake, invite and keys parts of vettid-android `VectorsTest`.
struct HandshakeVectorsTests {
    private struct Keyset {
        let ik: Ed25519PrivateKey
        let kem: KemPrivateKey
        let relay: Ed25519PrivateKey
        let doc: VectorDoc

        var relayAddr: RelayAddr {
            get throws { RelayAddr(url: try doc.str("relay_url"), mailbox: try doc.str("mailbox"), pk: relay.publicKey) }
        }
    }

    private let keys: VectorDoc
    private let vault: Keyset
    private let ini: Keyset
    private let eph: KemPrivateKey

    init() throws {
        let keys = try VectorDoc.load("keys.json")
        self.keys = keys
        vault = try Self.principal(keys, "vault")
        ini = try Self.principal(keys, "initiator")
        eph = try KemPrivateKey.fromSeed(try keys.sub("initiator_ephemeral").hex("kem_seed_hex"))
    }

    private static func principal(_ keys: VectorDoc, _ name: String) throws -> Keyset {
        let d = try keys.sub(name)
        return Keyset(
            ik: try Ed25519PrivateKey.fromSeed(try d.hex("ik_seed_hex")),
            kem: try KemPrivateKey.fromSeed(try d.hex("kem_seed_hex")),
            relay: try Ed25519PrivateKey.fromSeed(try d.hex("relay_seed_hex")),
            doc: d
        )
    }

    private func lookup(_ kid: Kid) -> KemPrivateKey? { kid == vault.kem.publicKey.kid ? vault.kem : nil }

    @Test(arguments: ["vault", "initiator"])
    func mailboxIDs(_ who: String) throws {
        let d = try keys.sub(who)
        let relay = try Ed25519PrivateKey.fromSeed(try d.hex("relay_seed_hex"))
        #expect(Mailbox.id(relay.publicKey) == (try d.str("mailbox")))
        try RelayAddr(url: try d.str("relay_url"), mailbox: try d.str("mailbox"), pk: relay.publicKey).validate()
    }

    @Test func handshakeReceivingSide() throws {
        let d = try VectorDoc.load("handshake.json")
        let inp = try d.sub("inputs")
        #expect(try eph.seed() == (try inp.hex("initiator_eph_seed_hex")), "eph seed")
        let envInit = try d.b64("hs_init_envelope_b64")
        let envResp = try d.b64("hs_resp_envelope_b64")
        let envFin = try d.b64("hs_fin_envelope_b64")
        let t0 = try Timestamps.parseMillis(try inp.str("ts"))

        let p = try PendingInit.open(envInit, lookup: lookup, now: t0)
        #expect(try p.body.marshal() == Array(try d.str("hs_init_body").utf8))
        #expect(p.body.eph == eph.publicKey)
        let ie = try Envelope.parse(envInit)
        #expect(ie.senderKid == ini.kem.publicKey.kid)
        let (_, iexp) = try Envelope.openSealed(ie, key: vault.kem)
        let ks = try iexp.export("vettid/vms/2/hs-ks", 32)
        #expect(ks == (try d.hex("K_s_hex")), "K_s")

        let re = try Envelope.parse(envResp)
        #expect(re.recipientKid == eph.publicKey.kid)
        #expect(re.senderKid.isAnonymous)
        let (rpad, rexp) = try Envelope.openSealed(re, key: eph)
        let ke = try rexp.export("vettid/vms/2/hs-ke", 32)
        #expect(ke == (try d.hex("K_e_hex")), "K_e")
        let rin = try Inner.decode(rpad, .sealed)
        #expect(try rin.marshal(.sealed) == Array(try d.str("hs_resp_inner").utf8))

        let th1 = Bytes.sha256(Array("vettid/vms/2/th1".utf8), envInit)
        #expect(th1 == (try d.hex("th1_hex")), "th1")
        #expect(p.th1 == th1, "th1 (lib)")
        let th = Bytes.sha256(Array("vettid/vms/2/th".utf8), envInit, Array(envResp.prefix(1140)))
        #expect(th == (try d.hex("th_hex")), "th")
        let sc = try Schedule.derive(ks: ks, ke: ke, th1: th1, th: th)
        #expect(sc.prk == (try d.hex("prk_hex")), "prk")
        #expect(sc.kI2R == (try d.hex("k_i2r_hex")), "k_i2r")
        #expect(sc.kR2I == (try d.hex("k_r2i_hex")), "k_r2i")
        #expect(sc.kidI2R.bytes == (try d.hex("kid_i2r_hex")), "kid_i2r")
        #expect(sc.kidR2I.bytes == (try d.hex("kid_r2i_hex")), "kid_r2i")
        #expect(sc.rk == (try d.hex("rk_hex")), "rk")
        #expect(sc.epochID == (try d.hex("epoch_id_hex")), "epoch_id")
        // 0.10.3: the commitment in hs.init, n_R in hs.resp, n_I revealed in hs.fin; the SAS over th and both nonces.
        let nI = try inp.hex("n_I_hex")
        let nR = try inp.hex("n_R_hex")
        #expect(Schedule.sasCommit(nI) == (try d.hex("sas_commit_hex")), "sas_commit")
        #expect(p.body.sasCommit == (try d.hex("sas_commit_hex")), "sas_commit in hs.init")
        #expect(Schedule.checkSasCommit(try #require(p.body.sasCommit), nI))
        #expect(try Schedule.sas(prk: sc.prk, th: th, nI: nI, nR: nR) == (try d.str("sas")))
        #expect(try HsResp.parse(rin.body, .connection).sasNonce == nR, "n_R in hs.resp")

        let sigR = try d.b64("sig_R_b64")
        #expect(Schedule.verifyResp(vault.ik.publicKey, th: th, sig: sigR))
        #expect(String(bytes: try Padding.unpad(rpad), encoding: .utf8)?.contains(try d.str("sig_R_b64")) == true)
        let sigI = try d.b64("sig_I_b64")
        #expect(Schedule.verifyFin(ini.ik.publicKey, th: th, sig: sigI))
        #expect(try Schedule.signResp(vault.ik, th: th) == sigR, "sig_R (Ed25519 is deterministic)")
        #expect(try Schedule.signFin(ini.ik, th: th) == sigI, "sig_I (Ed25519 is deterministic)")

        let fe = try Envelope.parse(envFin)
        #expect(fe.mode == .session)
        #expect(fe.recipientKid == sc.kidI2R)
        #expect(fe.senderKid == sc.kidR2I)
        #expect(Array(envFin[20..<44]) == (try inp.hex("fin_nonce_hex")), "hs.fin nonce")
        let fin = try Inner.decode(try Envelope.openSession(fe, key: sc.kI2R), .session)
        #expect(fin.type == "hs.fin")
        #expect(fin.seq == 1)
        #expect(fin.id == (try inp.str("fin_id")))
        let hf = try HsFin.parse(fin.body, .connection)
        #expect(hf.sig == sigI, "hs.fin sig")
        #expect(hf.sasNonce == nI, "n_I in hs.fin")
    }

    /// The whole handshake run through Initiator / PendingInit / Responder, byte for byte.
    @Test func handshakeSendingSide() throws {
        let d = try VectorDoc.load("handshake.json")
        let inp = try d.sub("inputs")
        let body = try HsInit.parse(Array(try d.str("hs_init_body").utf8))
        let respBody = try StrictJson.parseObject(try d.str("hs_resp_inner")).obj("body")
        let now = try Timestamps.parseMillis(try inp.str("ts"))

        // The scripted randomness (§16): the ephemeral key seed, n_I, then the hs.init encapsulation.
        let cfg = InitiatorConfig(
            purpose: .connection,
            ctx: body.ctx,
            identity: ini.ik,
            staticKem: ini.kem.publicKey,
            relay: try ini.relayAddr,
            token: body.token,
            reconnectToken: body.reconnectToken,
            responderIk: vault.ik.publicKey,
            responderEk: vault.kem.publicKey,
            responderRelayKey: vault.relay.publicKey,
            policy: .vaultToVault,
            id: try inp.str("init_id"),
            finID: try inp.str("fin_id"),
            now: now
        )
        let initiator = try deterministic(
            try inp.hex("initiator_eph_seed_hex"), try inp.hex("n_I_hex"), try inp.hex("init_encapsulation_randomness_hex")
        ) { try Initiator.create(cfg) }
        #expect(initiator.envelope == (try d.b64("hs_init_envelope_b64")), "hs.init envelope")

        let pending = try PendingInit.open(initiator.envelope, lookup: lookup, now: now)
        // n_R, then the hs.resp encapsulation.
        let respCfg = ResponderConfig(
            identity: vault.ik,
            token: try respBody.string("token"),
            policy: .vaultToVault,
            collectSender: ini.relay.publicKey,
            id: try inp.str("resp_id"),
            now: now
        )
        let (responder, resp) = try deterministic(try inp.hex("n_R_hex"), try inp.hex("resp_encapsulation_randomness_hex")) {
            try pending.respond(respCfg)
        }
        #expect(resp == (try d.b64("hs_resp_envelope_b64")), "hs.resp envelope")

        let result = try deterministic(try inp.hex("fin_nonce_hex")) {
            try initiator.handleResp(resp, collectSender: vault.relay.publicKey, now: now)
        }
        #expect(result.fin == (try d.b64("hs_fin_envelope_b64")), "hs.fin envelope")
        #expect(result.epoch.id == (try d.hex("epoch_id_hex")), "epoch_id")
        #expect(result.sas == (try d.str("sas")))

        let fr = try responder.handleFin(result.fin, collectSender: ini.relay.publicKey, now: now)
        #expect(fr.inner.type == "hs.fin")
        #expect(fr.sas == (try d.str("sas")))
        #expect(fr.epoch.id == result.epoch.id, "epoch ids")

        // The new epoch carries traffic both ways.
        let msg = Inner(id: "01JB2Z6V9K3M4N5P6Q7R8S9T13", type: "test.ping", ts: now)
        let back = try fr.epoch.open(try Envelope.parse(try result.epoch.seal(msg)))
        #expect(back.seq == 2) // hs.fin was seq 1
        let forth = try result.epoch.open(try Envelope.parse(try fr.epoch.seal(msg)))
        #expect(forth.seq == 1)
    }

    @Test func invite() throws {
        let d = try VectorDoc.load("invite.json")
        let blob = try d.b64("blob_b64")
        let sealed = try deterministic(try d.hex("k_b_hex"), try d.hex("nonce_hex")) {
            try InviteBundle.seal(Array(try d.str("bundle_json").utf8))
        }
        #expect(sealed.blob == blob, "blob")
        #expect(sealed.key == (try d.hex("k_b_hex")), "k_b")
        #expect(sealed.hash == (try d.hex("h_hex")), "h")
        let q = try InviteQr.parseLink(try d.str("link"))
        #expect(try q.marshal() == Array(try d.str("qr_json").utf8))
        #expect(try q.link() == (try d.str("link")))
        let b = try InviteBundle.open(blob, qr: q, now: try Timestamps.parseSeconds(try d.str("now")))
        #expect(b.vault.kem == vault.kem.publicKey)
        #expect(try b.marshal() == Array(try d.str("bundle_json").utf8))
        #expect(b.hintName == "Test Vault")
        // The commitment is checked before anything is decrypted; the kind and expiry must match the QR.
        var tampered = blob
        tampered[30] ^= 1
        expectCrypto(.protocolViolation) { _ = try InviteBundle.open(tampered, qr: q, now: try Timestamps.parseSeconds(try d.str("now"))) }
        expectCrypto(.time) { _ = try InviteBundle.open(blob, qr: q, now: b.exp) }
        let otherKind = InviteQr(kind: .app, relay: q.relay, claimID: q.claimID, hash: q.hash, key: q.key, exp: q.exp)
        let now = try Timestamps.parseSeconds(try d.str("now"))
        expectCrypto(.protocolViolation) { _ = try InviteBundle.open(blob, qr: otherKind, now: now) }
    }
}
// swiftlint:enable function_body_length
