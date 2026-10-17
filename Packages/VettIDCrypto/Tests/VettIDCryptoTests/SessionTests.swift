import Foundation
import Testing
@testable import VettIDCrypto

/// Handshake, epochs and rekeys beyond the vectors: the failure rules of §6.3 and §6.5. Mirrors vettid-android
/// `SessionTest`.
struct SessionTests {
    private let now = Date(timeIntervalSince1970: 1_790_856_000) // 2026-10-01T12:00:00Z

    private struct Party {
        let ik: Ed25519PrivateKey
        let kem: KemPrivateKey
        let relaySigner: Ed25519PrivateKey
        let relay: RelayAddr

        init() throws {
            ik = Ed25519PrivateKey.generate()
            kem = try KemPrivateKey.generate()
            relaySigner = Ed25519PrivateKey.generate()
            relay = RelayAddr(url: "https://relay.vettid.org", mailbox: Mailbox.id(relaySigner.publicKey), pk: relaySigner.publicKey)
        }

        func lookup(_ kid: Kid) -> KemPrivateKey? { kid == kem.publicKey.kid ? kem : nil }
    }

    private let app: Party
    private let vault: Party
    /// A PASETO-shaped test token ("test"), assembled so that it never looks like a credential.
    private let token = "v4.public." + "dGVzdA"

    init() throws {
        app = try Party()
        vault = try Party()
    }

    private func appInit(_ policy: Policy = .vaultToDevice, apiKey: [UInt8]? = nil) throws -> Initiator {
        try Initiator.create(
            InitiatorConfig(
                purpose: .app, ctx: "vault-0001", identity: app.ik, staticKem: app.kem.publicKey, relay: app.relay,
                token: token, apiKey: apiKey, responderIk: vault.ik.publicKey, responderEk: vault.kem.publicKey,
                responderRelayKey: vault.relaySigner.publicKey, policy: policy, now: now
            )
        )
    }

    private func respCfg(_ identity: Ed25519PrivateKey? = nil) -> ResponderConfig {
        ResponderConfig(
            identity: identity ?? vault.ik, token: token, policy: .vaultToDevice, collectSender: app.relaySigner.publicKey, now: now
        )
    }

    private func open(_ i: Initiator) throws -> PendingInit { try PendingInit.open(i.envelope, lookup: vault.lookup, now: now) }

    /// Runs a full app pairing handshake and returns (app epoch, vault epoch).
    private func pair(_ policy: Policy = .vaultToDevice) throws -> (Epoch, Epoch) {
        let i = try appInit(policy)
        let (r, resp) = try open(i).respond(respCfg())
        let res = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now)
        let fr = try r.handleFin(res.fin, collectSender: app.relaySigner.publicKey, now: now)
        // 0.10.3: both sides know the same 6-digit SAS only after the nonces are exchanged.
        #expect(res.sas?.count == 6)
        #expect(res.sas == fr.sas)
        return (res.epoch, fr.epoch)
    }

    private func ping(_ id: String = "01JB2Z6V9K3M4N5P6Q7R8S9T0V", type: String = "x.y") -> Inner {
        Inner(id: id, type: type, ts: now)
    }

    @Test func sasCommitmentFields() throws {
        let i = try appInit()
        // hs.init commits to n_I (32 bytes of SHA-256); the responder's n_R follows in hs.resp.
        #expect(i.body.sasCommit?.count == 32)
        let (_, resp) = try open(i).respond(respCfg())
        let res = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now)
        #expect(res.resp.sasNonce?.count == 32)
        // One hs.resp per hs.init: once hs.fin is out (n_I revealed), another hs.resp is refused.
        expectCrypto(.used) { _ = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now) }
    }

    @Test func sasCommitMismatchAbortsTheHandshake() throws {
        let i = try appInit()
        let (r, resp) = try open(i).respond(respCfg())
        let res = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now)
        // A correctly signed hs.fin whose n_I does not open sas_commit (only the initiator can send one).
        let th = Schedule.th(i.envelope, Array(resp.prefix(1140)))
        let bad = try HsFin(sig: try Schedule.signFin(app.ik, th: th), sasNonce: rep(0x55, 32)).marshal(.app)
        let forged = try res.epoch.seal(Inner(id: "01JB2Z6V9K3M4N5P6Q7R8S9T0W", type: "hs.fin", ts: now, body: bad))
        expectCrypto(.protocolViolation) { _ = try r.handleFin(forged, collectSender: app.relaySigner.publicKey, now: now) }
        // The state is destroyed: the genuine hs.fin is refused afterwards.
        expectCrypto(.used) { _ = try r.handleFin(res.fin, collectSender: app.relaySigner.publicKey, now: now) }
    }

    @Test func aTransfersAppKeyTravelsInHsInitOnlyForPurposeApp() throws {
        // §6.2 (0.15.0): `api_key`, the new app's P-256 SPKI DER, after `device_attest` and before `sas_commit`.
        let spki = (0..<91).map { UInt8($0) }
        let i = try appInit(apiKey: spki)
        let json = try #require(String(bytes: try i.body.marshal(), encoding: .utf8))
        #expect(json.contains("\"api_key\":\"\(Base64s.encodeStd(spki))\""))
        let apiKeyAt = try #require(json.range(of: "\"api_key\""))
        let sasCommitAt = try #require(json.range(of: "\"sas_commit\""))
        #expect(apiKeyAt.lowerBound < sasCommitAt.lowerBound)
        #expect(try HsInit.parse(try i.body.marshal()).apiKey == spki)
        // The vault still answers it like any app pairing.
        #expect(try open(i).body.apiKey == spki)
        // Absent for every other purpose.
        let b = try appInit().body
        #expect(b.apiKey == nil)
        let conn = HsInit(
            purpose: .connection, ctx: b.ctx, from: b.from, eph: b.eph, token: b.token, suites: b.suites,
            apiKey: spki, sasCommit: b.sasCommit
        )
        expectCrypto(.format) { _ = try conn.marshal() }
    }

    @Test func sasFieldsPresentExactlyForSasPurposes() throws {
        let body = try appInit().body
        // Without sas_commit, an app hs.init is malformed.
        let stripped = HsInit(purpose: body.purpose, ctx: body.ctx, from: body.from, eph: body.eph, token: body.token, suites: body.suites)
        expectCrypto(.format) { _ = try stripped.marshal() }
        // hs.fin of a SAS purpose must reveal n_I; one of a rekey must not.
        let sig = rep(0, 64)
        expectCrypto(.format) { _ = try HsFin(sig: sig).marshal(.connection) }
        expectCrypto(.format) { _ = try HsFin(sig: sig, sasNonce: rep(0, 32)).marshal(.rekey) }
        expectCrypto(.format) { _ = try HsFin(sig: sig, sasNonce: rep(0, 31)).marshal(.app) }
        #expect(!(Purpose.rekey.hasSas || Purpose.reconnect.hasSas))
    }

    @Test func pairingRoundTripAndTraffic() throws {
        let (a, v) = try pair()
        let m = ping(type: "vault.status")
        #expect(try v.open(try Envelope.parse(try a.seal(m))).type == "vault.status")
        #expect(try a.open(try Envelope.parse(try v.seal(m))).seq == 1)
        // A message cannot be opened by the direction that sent it.
        expectCrypto(.protocolViolation) { _ = try a.open(try Envelope.parse(try a.seal(m))) }
    }

    @Test func badSigRAbortsAfterDecryption() throws {
        let i = try appInit()
        // A responder signing with another ik: sig_R does not verify under the pinned key.
        let (_, resp) = try open(i).respond(respCfg(Ed25519PrivateKey.generate()))
        expectCrypto(.signature) { _ = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now) }
        // The handshake is destroyed: even a genuine answer is refused now.
        expectCrypto(.used) { _ = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now) }
    }

    @Test func junkDoesNotCancelThePendingHandshake() throws {
        let i = try appInit()
        let (_, resp) = try open(i).respond(respCfg())
        // Wrong collect sender, garbage, a message to another key: dropped, the handshake stays pending.
        expectCrypto(.protocolViolation) { _ = try i.handleResp(resp, collectSender: app.relaySigner.publicKey, now: now) }
        expectCrypto(.format) { _ = try i.handleResp(rep(0, 100), collectSender: vault.relaySigner.publicKey, now: now) }
        let stray = try Inner.encode(Inner(id: "01JB2Z6V9K3M4N5P6Q7R8S9T0V", type: "hs.resp", ts: now), .sealed)
        let other = try Envelope.sealSealed(try KemPrivateKey.generate().publicKey, senderKid: Kid.anonymous, padded: stray).0
        expectCrypto(.protocolViolation) { _ = try i.handleResp(other, collectSender: vault.relaySigner.publicKey, now: now) }
        _ = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now)
    }

    @Test func responderChecks() throws {
        let i = try appInit()
        // hs.init's collect sender must be from.relay.pk.
        let wrongSender = ResponderConfig(
            identity: vault.ik, token: token, policy: .vaultToDevice, collectSender: vault.relaySigner.publicKey
        )
        expectCrypto(.protocolViolation) { _ = try open(i).respond(wrongSender) }
        // No key for the kid.
        expectCrypto(.protocolViolation) { _ = try PendingInit.open(i.envelope, lookup: { _ in nil }, now: now) }
        // Too old for a durable type.
        expectCrypto(.time) { _ = try PendingInit.open(i.envelope, lookup: vault.lookup, now: now.addingTimeInterval(17 * 86_400)) }
        // A forged hs.fin is dropped and the pending responder survives.
        let (r, resp) = try open(i).respond(respCfg())
        let res = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now)
        var forged = res.fin
        forged[forged.count - 1] &+= 1
        expectCrypto(.decrypt) { _ = try r.handleFin(forged, collectSender: app.relaySigner.publicKey, now: now) }
        expectCrypto(.protocolViolation) { _ = try r.handleFin(res.fin, collectSender: vault.relaySigner.publicKey, now: now) }
        _ = try r.handleFin(res.fin, collectSender: app.relaySigner.publicKey, now: now)
    }

    private func rekeyInitiator(_ current: Epoch) throws -> Initiator {
        try Initiator.create(
            InitiatorConfig(
                purpose: .rekey, ctx: "", identity: app.ik, staticKem: app.kem.publicKey, relay: app.relay,
                responderIk: vault.ik.publicKey, responderEk: nil, responderRelayKey: vault.relaySigner.publicKey,
                current: current, policy: .vaultToDevice, now: now
            )
        )
    }

    private var rekeyRespCfg: ResponderConfig {
        ResponderConfig(
            identity: vault.ik, policy: .vaultToDevice, collectSender: app.relaySigner.publicKey,
            recordRelayKey: app.relaySigner.publicKey, knownInitiatorIk: app.ik.publicKey, now: now
        )
    }

    @Test func rekeyInSessionMode() throws {
        let (a, v) = try pair()
        let keyringA = Keyring()
        keyringA.activate(a, now: now)
        let keyringV = Keyring()
        keyringV.activate(v, now: now)
        let i = try rekeyInitiator(a)
        #expect(try Envelope.parse(i.envelope).mode == .session)
        let p = try PendingInit.openRekey(i.envelope, current: v, now: now)
        #expect(p.body.ctx == a.ctx)
        let (r, resp) = try p.respond(rekeyRespCfg)
        let res = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now)
        let v2 = try r.handleFin(res.fin, collectSender: app.relaySigner.publicKey, now: now).epoch
        #expect(a.id != res.epoch.id)

        // A message sealed in the old epoch before activation still opens after it (receive keys kept).
        let late = try v.seal(ping())
        keyringA.activate(res.epoch, now: now)
        keyringV.activate(v2, now: now)
        #expect(!a.canSend())
        expectCrypto(.protocolViolation) { _ = try a.seal(ping()) }
        #expect(try keyringA.open(try Envelope.parse(late), now: now).inner.type == "x.y")
        #expect(try keyringV.open(try Envelope.parse(try res.epoch.seal(ping())), now: now).inner.type == "x.y")
        // After 16 days the old receive key is gone.
        let later = now.addingTimeInterval(17 * 86_400)
        keyringA.prune(now: later)
        expectCrypto(.protocolViolation) { _ = try keyringA.open(try Envelope.parse(late), now: later) }
        // A rekey hs.init is accepted only under the current epoch.
        expectCrypto(.protocolViolation) { _ = try PendingInit.openRekey(i.envelope, current: v2, now: now) }
    }

    /// The responder of a rekey survives a restart between hs.resp and hs.fin (as the vault's st.Awaiting): its export
    /// restores to a responder that completes the handshake. A message of the new epoch that comes before hs.fin is
    /// ``CryptoError/early(_:)`` (keep it for later) and leaves the handshake pending.
    @Test func aRekeyResponderExportsAndAMessageAheadOfHsFinIsEarly() throws {
        let (a, v) = try pair()
        let i = try rekeyInitiator(a)
        let (r, resp) = try PendingInit.openRekey(i.envelope, current: v, now: now).respond(rekeyRespCfg)
        let state = try r.export()
        r.abort() // the process ends; only the export is left
        let restored = try Responder.import(state)
        let res = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now)
        let early = try res.epoch.seal(ping("01JB2Z6V9K3M4N5P6Q7R8S9T0X", type: "message.new"))
        expectCrypto(.early) { _ = try restored.handleFin(early, collectSender: app.relaySigner.publicKey, now: now) }
        let v2 = try restored.handleFin(res.fin, collectSender: app.relaySigner.publicKey, now: now).epoch
        #expect(res.epoch.id == v2.id)
        #expect(try v2.open(try Envelope.parse(early)).type == "message.new")
        // Done: nothing to export any more; a damaged export does not restore.
        expectCrypto(.used) { _ = try restored.export() }
        #expect(throws: CryptoError.self) { _ = try Responder.import(Array("{}".utf8)) }
    }

    @Test func reconnectFollowsTheRotationChain() throws {
        let (a, _) = try pair()
        // The vault rotated its ik and kem since the last epoch.
        let newIk = Ed25519PrivateKey.generate()
        let newKem = try KemPrivateKey.generate()
        let rot = try Rotation.create(old: vault.ik, new: newIk, newKem: newKem.publicKey)
        let i = try Initiator.create(
            InitiatorConfig(
                purpose: .reconnect, ctx: a.ctx, identity: app.ik, staticKem: app.kem.publicKey, relay: app.relay,
                token: token, reconnectToken: token, responderIk: vault.ik.publicKey, responderEk: newKem.publicKey,
                responderRelayKey: vault.relaySigner.publicKey, policy: .vaultToVault, now: now
            )
        )
        let p = try PendingInit.open(i.envelope, lookup: { $0 == newKem.publicKey.kid ? newKem : nil }, now: now)
        let (r, resp) = try p.respond(
            ResponderConfig(
                identity: newIk, token: token, reconnectToken: token, rotations: [rot], policy: .vaultToVault,
                collectSender: app.relaySigner.publicKey, recordRelayKey: app.relaySigner.publicKey,
                knownInitiatorIk: app.ik.publicKey, expectedCtx: a.ctx, now: now
            )
        )
        let res = try i.handleResp(resp, collectSender: vault.relaySigner.publicKey, now: now)
        #expect(Ed25519.equalPublic(newIk.publicKey, res.responderIk))
        #expect(res.responderKem == newKem.publicKey)
        _ = try r.handleFin(res.fin, collectSender: app.relaySigner.publicKey, now: now)
        // A broken chain is refused.
        let forged = try Rotation.create(old: Ed25519PrivateKey.generate(), new: newIk, newKem: newKem.publicKey)
        expectCrypto(.signature) { _ = try Rotation.resolveChain(vault.ik.publicKey, [forged]) }
        expectCrypto(.signature) { _ = try Rotation.create(old: newIk, new: newIk, newKem: newKem.publicKey) }
        // A rotation survives its JSON form.
        #expect(try Rotation.parse(try StrictJson.parseObject(rot.marshal())).marshal() == rot.marshal())
    }

    @Test func keyringExportKeepsCurrentAndRetainedEpochs() throws {
        let (a1, v1) = try pair()
        let (a2, v2) = try pair()
        let k = Keyring()
        k.activate(a1, now: now)
        k.activate(a2, now: now.addingTimeInterval(60)) // a1 retired: receive key kept for 16 days, send key gone
        let restored = try Keyring.import(try k.export())
        let m = ping()
        // Both the old and the current epoch still open what the peer sends.
        #expect(try restored.open(try Envelope.parse(try v1.seal(m)), now: now.addingTimeInterval(120)).inner.type == "x.y")
        #expect(try restored.open(try Envelope.parse(try v2.seal(m)), now: now.addingTimeInterval(120)).inner.type == "x.y")
        // Only the current one sends; the retained one expires with its retention.
        #expect(try v2.open(try Envelope.parse(try #require(restored.current()).seal(m))).type == "x.y")
        let expired = now.addingTimeInterval(Epoch.receiveKeyRetention + 120)
        expectCrypto(.protocolViolation) { _ = try restored.open(try Envelope.parse(try v1.seal(m)), now: expired) }
        #expect(try Keyring.import(try Keyring().export()).current() == nil)
    }

    @Test func epochPolicyExportAndImport() throws {
        let (a, v) = try pair()
        #expect(!a.needsRekey(now: now.addingTimeInterval(6 * 86_400)))
        #expect(a.needsRekey(now: now.addingTimeInterval(7 * 86_400)))
        _ = try a.seal(ping())
        let restored = try Epoch.import(try a.export())
        #expect(try v.open(try Envelope.parse(try restored.seal(ping()))).seq == 3) // hs.fin, m, then this: the counter survives
        #expect(restored.description == "Epoch[redacted]")
        let (b, _) = try pair(Policy(maxAge: 86_400, maxMessages: 2))
        // hs.fin was the first message sent in the epoch; the second reaches the bound.
        #expect(!b.needsRekey(now: now))
        _ = try b.seal(ping())
        #expect(b.needsRekey(now: now))
        // Simultaneous rekeys: the lower th1 wins.
        #expect(Epoch.ourRekeyWins([0, 1], [0, 2]))
        #expect(!Epoch.ourRekeyWins([1], [0]))
    }

    @Test func relayShapes() throws {
        try Relay.validateURL("https://relay.vettid.org")
        try Relay.validateURL("http://127.0.0.1:8080")
        try Relay.validateURL("http://localhost:8080/base")
        try Relay.validateURL("http://[::1]:8080")
        let bad = [
            "http://relay.vettid.org", "https://u@relay.vettid.org", "https://relay.vettid.org?x", "https://relay.vettid.org#f",
            "ftp://relay.vettid.org", "https://", "relay.vettid.org", "https://relay .org", "http://127.0.0.256", "http://127.0.0",
        ]
        for u in bad { expectCrypto(.format, "\(u)") { try Relay.validateURL(u) } }
        #expect(Relay.isValidToken("v4.public.abc-_.x"))
        #expect(!Relay.isValidToken("v4.public."))
        #expect(!Relay.isValidToken("v4.local.abc"))
        #expect(!Relay.isValidToken("v4.public.a+b"))
    }

    @Test func deviceAttestBothPlatforms() throws {
        let ios = try DeviceAttest.iosAttestation(keyID: rep(1, 32), attestation: rep(2, 600))
        let iosJSON = #"{"platform":"ios","key_id":"\#(Base64s.encodeStd(rep(1, 32)))","# +
            #""attestation":"\#(Base64s.encodeStd(rep(2, 600)))"}"#
        #expect(ios.marshal() == iosJSON)
        #expect(try DeviceAttest.parse(Array(ios.marshal().utf8)) == ios)
        let android = try DeviceAttest.androidChain([rep(3, 10), rep(4, 10)])
        #expect(try DeviceAttest.parse(Array(android.marshal().utf8)) == android)
        expectCrypto(.format) { _ = try DeviceAttest.parse(Array(#"{"platform":"windows"}"#.utf8)) }
        expectCrypto(.format) { _ = try DeviceAttest.parse(Array(#"{"platform":"ios","key_id":"AQ=="}"#.utf8)) }
        expectCrypto(.format) { _ = try DeviceAttest.androidChain([]) }
        expectCrypto(.format) { _ = try DeviceAttest.iosAttestation(keyID: [], attestation: [1]) }
        // An app hs.init carries it; other purposes may not.
        let i = try appInit()
        let withAttest = HsInit(
            purpose: .app, ctx: "vault-0001", from: i.body.from, eph: i.body.eph, token: token, deviceAttest: ios,
            sasCommit: i.body.sasCommit
        )
        #expect(try HsInit.parse(try withAttest.marshal()).deviceAttest == ios)
    }

    @Test func capabilities() throws {
        func parse(_ json: String) throws -> [String] { try Capabilities.parse(try StrictJson.parseObject(json)) }
        #expect(try parse("{}") == [])
        #expect(try parse(#"{"capabilities":["recovery_offered","recovery_r"]}"#) == ["recovery_offered", "recovery_r"])
        expectCrypto(.format) { _ = try parse(#"{"capabilities":["recovery_r","recovery_offered"]}"#) } // not sorted
        expectCrypto(.format) { _ = try parse(#"{"capabilities":["a","a"]}"#) } // duplicate
        expectCrypto(.format) { _ = try parse(#"{"capabilities":["Upper"]}"#) }
        expectCrypto(.format) { _ = try parse(#"{"capabilities":[""]}"#) }
        expectCrypto(.format) { _ = try parse(#"{"capabilities":"recovery_r"}"#) }
    }
}
