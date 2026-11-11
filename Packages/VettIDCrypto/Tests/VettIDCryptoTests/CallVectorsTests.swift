import Foundation
import Testing
@testable import VettIDCrypto

// Fixtures are long literals.
// swiftlint:disable line_length optional_data_string_conversion function_parameter_count

/// vettid-vault's call vectors (`calls.json`, VAULT-MESSAGING §10.10): the key agreement from both sides, the shares of
/// both roles and the vault-signed ICE configuration, byte for byte. Then the media keys the app derives from `k_call`
/// (CALLS-PLAN §12), whose expected values vettid-android computed independently from the same vector. Mirrors
/// vettid-android `CallVectorsTest`.
@Suite struct CallVectorsTests {
    let d: VectorDoc
    let callId: String
    let ek: [UInt8]
    let enc: [UInt8]
    let kCall: [UInt8]
    let offerKey: KemPrivateKey
    let caller: Party
    let callee: Party

    struct Party {
        let device: Ed25519PrivateKey
        let vault: Ed25519PrivateKey
        let deviceIk: [UInt8]
        let vaultIk: [UInt8]

        init(_ d: VectorDoc) throws {
            device = try Ed25519PrivateKey.fromSeed(d.hex("device_ik_seed_hex"))
            vault = try Ed25519PrivateKey.fromSeed(d.hex("vault_ik_seed_hex"))
            deviceIk = try d.b64("device_ik_b64")
            vaultIk = try d.b64("vault_ik_b64")
        }
    }

    init() throws {
        d = try VectorDoc.load("calls.json")
        callId = try d.str("call_id")
        ek = try d.b64("ek_b64")
        enc = try d.b64("enc_b64")
        kCall = try d.hex("k_call_hex")
        offerKey = try KemPrivateKey.fromSeed(d.hex("offer_kem_seed_hex"))
        caller = try Party(d.sub("caller"))
        callee = try Party(d.sub("callee"))
    }

    private func same(_ what: String, _ expected: [UInt8], _ got: [UInt8]) {
        #expect(expected == got, "\(what): expected \(Bytes.hex(expected)), got \(Bytes.hex(got))")
    }

    @Test func labels() throws {
        #expect(CallWire.labelCall == (try d.str("label_call")))
        #expect(CallWire.labelCallKey == (try d.str("label_call_key")))
        #expect(CallWire.mediaSalt == (try d.str("media_salt")))
        #expect(CallWire.labelShare == (try d.str("label_share")))
        #expect(CallWire.labelVouch == (try d.str("label_vouch")))
        #expect(CallWire.labelIce == (try d.str("label_ice")))
        #expect(try d.str("info") == CallWire.labelCall + callId)
    }

    @Test func theCallerDerivesTheVectorsKey() throws {
        same("ek", ek, offerKey.publicKey.bytes)
        same("k_call", kCall, try CallWire.accept(offerKey: offerKey, enc: enc, callId: callId))
    }

    /// The HPKE exporter K before `k_call` is derived from it, from both sides.
    @Test func theExporterOfTheVector() throws {
        let info = Array(try d.str("info").utf8)
        let r = try HpkeRecipient.setup(enc: enc, key: offerKey, info: info)
        same("exporter (caller)", try d.hex("exporter_hex"), try r.export(CallWire.labelCallKey, CallWire.keySize))
        let s = try deterministic(try d.hex("answer_randomness_hex")) { try HpkeSender.setup(KemPublicKey.parse(ek), info: info) }
        same("exporter (answerer)", try d.hex("exporter_hex"), try s.export(CallWire.labelCallKey, CallWire.keySize))
    }

    /// The HPKE export is wiped in the buffer its owner holds, not in a copy of it (arrays copy on write), and `Answered`
    /// shows no key to a description, a debug description or `dump`.
    @Test func theExportIsWipedInTheOwnersBufferAndAnsweredShowsNoKey() throws {
        var k = (0..<32).map { UInt8($0 + 1) }
        let base = k.withUnsafeBufferPointer { $0.baseAddress }
        let out = try CallWire.mediaKey(&k, callId)
        #expect(out.count == CallWire.keySize && out.contains { $0 != 0 })
        #expect(k.allSatisfy { $0 == 0 }, "the owner's array is zero")
        #expect(k.withUnsafeBufferPointer { $0.baseAddress } == base, "wiped in place")
        var a = CallWire.Answered(enc: [0x5B], kCall: out)
        var shown = ""
        dump(a, to: &shown)
        for text in ["\(a)", String(describing: a), String(reflecting: a), shown] {
            #expect(!text.contains("kCall") && !text.contains(Bytes.hex(out)) && !text.contains("\(out)"))
        }
        Bytes.wipe(&a.kCall)
        #expect(a.kCall.allSatisfy { $0 == 0 })
        // The ICE types show no credential either.
        let server = CallWire.IceServer(urls: ["turn:x:1"], username: "USERSECRET", credential: "CREDSECRET")
        let config = CallWire.IceConfig(callId: callId, exp: Date(timeIntervalSince1970: 1), servers: [server])
        for x in [server, config] as [Any] {
            var d = ""
            dump(x, to: &d)
            for text in ["\(x)", String(reflecting: x), d] { #expect(!text.contains("CREDSECRET") && !text.contains("USERSECRET")) }
        }
    }

    @Test func theAnswererProducesTheVectorsEncAndKey() throws {
        let a = try deterministic(try d.hex("answer_randomness_hex")) { try CallWire.answer(ek: ek, callId: callId) }
        same("enc", enc, a.enc)
        same("k_call", kCall, a.kCall)
    }

    @Test func aFreshAnswerAgreesAndIsBoundToTheCallAndTheKey() throws {
        let a = try CallWire.answer(ek: ek, callId: callId)
        #expect(a.enc.count == Suite.encSize)
        #expect(a.enc != enc)
        same("k_call", a.kCall, try CallWire.accept(offerKey: offerKey, enc: a.enc, callId: callId))
        // Another call id, or another offer key: a different key, or no key.
        let otherCall = try? CallWire.accept(offerKey: offerKey, enc: a.enc, callId: String(callId.dropLast()) + "1")
        #expect(otherCall == nil || otherCall != a.kCall)
        let otherKey = try? CallWire.accept(offerKey: try CallWire.newOfferKey(), enc: a.enc, callId: callId)
        #expect(otherKey == nil || otherKey != a.kCall)
    }

    @Test func badSizesAndAnEmptyCallIdAreRefused() throws {
        expectCrypto(.key) { _ = try CallWire.answer(ek: Array(ek.dropLast()), callId: callId) }
        expectCrypto(.key) { _ = try CallWire.answer(ek: ek + [0], callId: callId) }
        expectCrypto(.key) { _ = try CallWire.answer(ek: ek, callId: "") }
        expectCrypto(.key) { _ = try CallWire.accept(offerKey: offerKey, enc: Array(enc.dropLast()), callId: callId) }
        expectCrypto(.key) { _ = try CallWire.accept(offerKey: offerKey, enc: enc, callId: "") }
    }

    private func share(_ name: String, _ role: String, _ media: String, _ value: [UInt8], by: Party, other: Party) throws {
        let s = try d.sub(name)
        #expect(try s.str("role") == role)
        #expect(try s.str("media") == media)
        let m = CallWire.shareMessage(role: role, callId: callId, media: media, share: value)
        same("\(name) message", try s.b64("message_b64"), m)
        let deviceSig = try CallWire.signShare(deviceIk: by.device, message: m)
        same("\(name) device_sig", try s.b64("device_sig_b64"), deviceSig)
        same("\(name) vouch message", try s.b64("vouch_message_b64"), CallWire.vouchMessage(deviceIk: by.deviceIk, message: m))
        let vaultSig = try by.vault.sign(label: CallWire.labelVouch, CallWire.vouchMessage(deviceIk: by.deviceIk, message: m))
        same("\(name) vault_sig", try s.b64("vault_sig_b64"), vaultSig)
        try CallWire.verifyShare(vaultIk: by.vaultIk, deviceIk: by.deviceIk, message: m, deviceSig: deviceSig, vaultSig: vaultSig)

        // Another vault's key, another device's key, a changed share, the other role, a vouch that is the device's own
        // signature: none verifies.
        expectCrypto(.signature, "another vault") {
            try CallWire.verifyShare(vaultIk: other.vaultIk, deviceIk: by.deviceIk, message: m, deviceSig: deviceSig, vaultSig: vaultSig)
        }
        expectCrypto(.signature, "another device") {
            try CallWire.verifyShare(vaultIk: by.vaultIk, deviceIk: other.deviceIk, message: m, deviceSig: deviceSig, vaultSig: vaultSig)
        }
        var changed = m
        changed[changed.count - 1] &+= 1
        expectCrypto(.signature, "a changed share") {
            try CallWire.verifyShare(vaultIk: by.vaultIk, deviceIk: by.deviceIk, message: changed, deviceSig: deviceSig, vaultSig: vaultSig)
        }
        let swapped = role == CallWire.roleOffer ? CallWire.roleAnswer : CallWire.roleOffer
        let otherRole = CallWire.shareMessage(role: swapped, callId: callId, media: media, share: value)
        expectCrypto(.signature, "the other role") {
            try CallWire.verifyShare(vaultIk: by.vaultIk, deviceIk: by.deviceIk, message: otherRole, deviceSig: deviceSig, vaultSig: vaultSig)
        }
        expectCrypto(.signature, "no vouch") {
            try CallWire.verifyShare(vaultIk: by.vaultIk, deviceIk: by.deviceIk, message: m, deviceSig: deviceSig, vaultSig: deviceSig)
        }
        // A signature of the wrong size is a failure, not a crash.
        expectCrypto(.signature, "short signature") {
            try CallWire.verifyShare(vaultIk: by.vaultIk, deviceIk: by.deviceIk, message: m, deviceSig: Array(deviceSig.dropLast()), vaultSig: vaultSig)
        }
    }

    @Test func theOfferShare() throws {
        try share("offer_share", CallWire.roleOffer, CallWire.mediaAudio, ek, by: caller, other: callee)
    }

    @Test func theAnswerShare() throws {
        try share("answer_share", CallWire.roleAnswer, "", enc, by: callee, other: caller)
    }

    @Test func theIceConfigurations() throws {
        let exp = try d.num("ice_exp")
        let before = Date(timeIntervalSince1970: Double(exp) - 1)
        for name in ["ice", "ice_no_servers"] {
            let v = try d.sub(name)
            let config = try v.b64("ice_config_b64")
            let sig = try v.b64("ice_sig_b64")
            #expect(try v.str("config") == String(decoding: config, as: UTF8.self))
            same("\(name) sig", sig, try caller.vault.sign(label: CallWire.labelIce, config))
            let c = try CallWire.verifyIce(vaultIk: caller.vaultIk, config: config, sig: sig, callId: callId, now: before)
            #expect(c.callId == callId)
            #expect(UInt64(c.exp.timeIntervalSince1970) == exp)
            same("\(name) canonical", config, try CallWire.marshalIce(c))
            let atExp = Date(timeIntervalSince1970: Double(exp))
            expectCrypto(.time, "at exp") { _ = try CallWire.verifyIce(vaultIk: caller.vaultIk, config: config, sig: sig, callId: callId, now: atExp) }
            expectCrypto(.signature, "another vault") { _ = try CallWire.verifyIce(vaultIk: callee.vaultIk, config: config, sig: sig, callId: callId, now: before) }
            expectCrypto(.protocolViolation, "another call") {
                _ = try CallWire.verifyIce(vaultIk: caller.vaultIk, config: config, sig: sig, callId: String(callId.dropLast()) + "1", now: before)
            }
            var tampered = config
            tampered[tampered.count - 2] ^= 1
            expectCrypto(.signature, "a changed configuration") { _ = try CallWire.verifyIce(vaultIk: caller.vaultIk, config: tampered, sig: sig, callId: callId, now: before) }
        }
        let servers = try CallWire.parseIce(try d.sub("ice").b64("ice_config_b64")).servers
        #expect(servers.count == 2)
        #expect(servers[0].urls == ["stun:turn.example.org:3478"])
        #expect(servers[0].credential == nil)
        #expect(servers[1].username == "1800000000:\(callId)")
        #expect(!"\(servers[1])".contains(try #require(servers[1].credential)), "a credential is never printed")
        #expect(try CallWire.parseIce(try d.sub("ice_no_servers").b64("ice_config_b64")).servers.isEmpty)
    }

    @Test func anIceConfigurationThatIsNotCanonicalOrNotValidIsRefused() throws {
        let ok = String(decoding: try d.sub("ice").b64("ice_config_b64"), as: UTF8.self)
        let bad = [
            ok.replacingOccurrences(of: #"{"v":1,"call_id""#, with: #"{ "v":1,"call_id""#),
            ok.replacingOccurrences(of: #""v":1,"#, with: #""v":2,"#),
            ok.replacingOccurrences(of: "stun:turn.example.org:3478", with: "http://turn.example.org"),
            ok.replacingOccurrences(of: "stun:turn.example.org:3478", with: "stun:"),
            ok.replacingOccurrences(of: "stun:turn.example.org:3478", with: "stun:a b"),
            ok.replacingOccurrences(of: #","credential":"c2VjcmV0""#, with: ""),
            ok.replacingOccurrences(of: #""credential":"c2VjcmV0""#, with: #""credential":"""#),
            ok.replacingOccurrences(of: #"{"urls":["stun:turn.example.org:3478"]},"#, with: #"{"urls":[]},"#),
            ok.replacingOccurrences(of: #""ice_servers":["#, with: #""extra":1,"ice_servers":["#),
            ok.replacingOccurrences(of: #""exp":1800000000"#, with: #""exp":0"#),
        ]
        for b in bad {
            #expect(b != ok, "\(b)")
            do {
                _ = try CallWire.parseIce(Array(b.utf8))
                Issue.record("accepted: \(b)")
            } catch is CryptoError {
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        let servers = [CallWire.IceServer](repeating: CallWire.IceServer(urls: ["stun:x"]), count: CallWire.maxIceServers + 1)
        let many = CallWire.IceConfig(callId: callId, exp: Date(timeIntervalSince1970: 1), servers: servers)
        expectCrypto(.format) { _ = try CallWire.marshalIce(many) }
        // Too large to be read at all.
        expectCrypto(.format) { _ = try CallWire.parseIce([UInt8](repeating: 0x20, count: CallWire.maxIceConfig + 1)) }
    }

    // MARK: - The media keys (CALLS-PLAN §12)

    private let s1 = MediaSuite.aes128Gcm
    private func one() throws -> CallMedia.Negotiated { try CallMedia.Negotiated(chosen: s1, offered: [1]) }

    @Test func theDirectionKeysAndFrameKeysOfTheVector() throws {
        let caller = try CallMedia.directionKey(kCall: kCall, negotiated: one(), direction: CallMedia.directionCaller, callId: callId)
        let callee = try CallMedia.directionKey(kCall: kCall, negotiated: one(), direction: CallMedia.directionCallee, callId: callId)
        same("caller", try Bytes.unhex("df07dfb74e30ab8b952a864b0214911649859b9d371d50cc04daa84d5c952c08"), caller)
        same("callee", try Bytes.unhex("8e8b93784e37abb2257c2d42e47a0839e5aee933610f511c218199ebb7da637e"), callee)
        same("caller frame key", try Bytes.unhex("df487affce123283952f691628c1c2de"), try CallFrames.frameKey(caller, suite: s1))
        same("callee frame key", try Bytes.unhex("81e8788d323103611d582bd089af9be4"), try CallFrames.frameKey(callee, suite: s1))
    }

    @Test func theChoiceAndTheOfferedListAreInTheKey() throws {
        func k(_ n: CallMedia.Negotiated) throws -> String {
            Bytes.hex(try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId))
        }
        let two = try CallMedia.Negotiated(chosen: .aes256Gcm, offered: [2, 1])
        #expect(try k(two) == "129e7ea015351c448613b72d821141780fbc2681c9562f2b47894d999c609617")
        // A list cut down to the weaker suite on the way: the caller (who offered 2 and 1) and the answerer (who saw
        // only 1) derive different keys for the same choice.
        let cut = try CallMedia.Negotiated(chosen: s1, offered: [2, 1])
        #expect(try k(cut) == "eb7c3d3b7c0d8d3a42b85e908c9f9dbf5b76a56a11e91d0e9138134c7328aec0")
        #expect(try k(cut) != k(one()))
        let otherCall = Bytes.hex(try CallMedia.directionKey(kCall: kCall, negotiated: one(), direction: CallMedia.directionCaller, callId: String(callId.dropLast()) + "1"))
        #expect(try k(one()) != otherCall)
    }

    @Test func aSealedAudioFrameOfTheVector() throws {
        let key = try CallFrames.frameKey(
            CallMedia.directionKey(kCall: kCall, negotiated: one(), direction: CallMedia.directionCaller, callId: callId), suite: s1
        )
        let frame = try Bytes.unhex("78797a7b7c7d7e7f808182838485868788898a8b")
        let iv = CallFrames.iv(ssrc: 0x1122_3344, timestamp: 960, sendCount: 0)
        same("iv", try Bytes.unhex("11223344000003c0000003c0"), iv)
        let sealed = try CallFrames.seal(frameKey: key, frame: frame, clearBytes: CallFrames.audioClearSize, iv: iv)
        same(
            "sealed",
            try Bytes.unhex("780a14a5d44d9ba28ccf9ad78a82e7855c69d9584297c8aef4c5bf19d8a503b6d6aae36a11223344000003c0000003c00c00"),
            sealed
        )
        #expect(sealed.count == frame.count + CallFrames.overhead)
        #expect(CallFrames.open(frameKey: key, sealed: sealed, clearBytes: CallFrames.audioClearSize) == frame)
        // The other direction's key does not open it.
        let other = try CallFrames.frameKey(
            CallMedia.directionKey(kCall: kCall, negotiated: one(), direction: CallMedia.directionCallee, callId: callId), suite: s1
        )
        #expect(CallFrames.open(frameKey: other, sealed: sealed, clearBytes: CallFrames.audioClearSize) == nil)
    }
}

// swiftlint:enable line_length optional_data_string_conversion function_parameter_count
