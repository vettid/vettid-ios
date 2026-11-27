import Foundation
import Testing
@testable import VettIDCrypto

// Fixtures are long literals.
// swiftlint:disable line_length

/// (C2) Form 2 of the call shares and key confirmation (VAULT-MESSAGING 0.88.16 §10.10 "Call forms", "Key
/// confirmation", §16): vettid-vault's `calls.json` byte for byte, both members' vault identity keys in `m2`, in `k_call`
/// and in `confirm`, and the §16 values of the form 2 direction and frame keys. Mirrors vettid-android
/// `CallForm2VectorsTest`.
@Suite struct CallForm2VectorsTests {
    let d: VectorDoc
    let callId: String
    let ek: [UInt8]
    let enc: [UInt8]
    let offerKey: KemPrivateKey
    let caller: CallVectorsTests.Party
    let callee: CallVectorsTests.Party
    let parties: CallWire.Parties
    let offered: [Int]
    let chosen: Int

    init() throws {
        d = try VectorDoc.load("calls.json")
        callId = try d.str("call_id")
        ek = try d.b64("ek_b64")
        enc = try d.b64("enc_b64")
        offerKey = try KemPrivateKey.fromSeed(d.hex("offer_kem_seed_hex"))
        caller = try CallVectorsTests.Party(d.sub("caller"))
        callee = try CallVectorsTests.Party(d.sub("callee"))
        parties = try CallWire.Parties(caller: caller.vaultIk, callee: callee.vaultIk)
        offered = try d.sub("offer_share2").o.array("suites").map { Int(try $0.asUint(min: 1, max: 65535)) }
        chosen = Int(try d.sub("answer_share2").num("suite"))
    }

    private func same(_ what: String, _ expected: [UInt8], _ got: [UInt8]) {
        #expect(expected == got, "\(what): expected \(Bytes.hex(expected)), got \(Bytes.hex(got))")
    }

    @Test func labelsAndLists() throws {
        #expect(CallWire.labelConfirm == (try d.str("label_confirm")))
        #expect(offered == [2, 1])
        #expect(offered == (try d.sub("answer_share2").o.array("offered").map { Int(try $0.asUint(min: 1, max: 65535)) }))
        #expect(CallWire.suiteList(offered) == "2 1")
        #expect(CallWire.suiteList([1]) == "1")
    }

    private func share2(_ name: String, _ role: String, _ m: [UInt8], by: CallVectorsTests.Party, other: CallVectorsTests.Party) throws {
        let s = try d.sub(name)
        #expect(try s.str("role") == role)
        same("\(name) message", try s.b64("message_b64"), m)
        let deviceSig = try CallWire.signShare(deviceIk: by.device, message: m)
        same("\(name) device_sig", try s.b64("device_sig_b64"), deviceSig)
        same("\(name) vouch message", try s.b64("vouch_message_b64"), CallWire.vouchMessage(deviceIk: by.deviceIk, message: m))
        let vaultSig = try by.vault.sign(label: CallWire.labelVouch, CallWire.vouchMessage(deviceIk: by.deviceIk, message: m))
        same("\(name) vault_sig", try s.b64("vault_sig_b64"), vaultSig)
        try CallWire.verifyShare(vaultIk: by.vaultIk, deviceIk: by.deviceIk, message: m, deviceSig: deviceSig, vaultSig: vaultSig)
        #expect(throws: CryptoError.self) {
            try CallWire.verifyShare(vaultIk: other.vaultIk, deviceIk: by.deviceIk, message: m, deviceSig: deviceSig, vaultSig: vaultSig)
        }
    }

    @Test func theOfferShare2() throws {
        try share2(
            "offer_share2", CallWire.roleOffer2,
            CallWire.offerMessage2(callId: callId, media: CallWire.mediaAudio, offered: offered, parties: parties, ek: ek),
            by: caller, other: callee
        )
    }

    @Test func theAnswerShare2() throws {
        try share2(
            "answer_share2", CallWire.roleAnswer2,
            CallWire.answerMessage2(callId: callId, chosen: chosen, offered: offered, parties: parties, enc: enc),
            by: callee, other: caller
        )
    }

    /// A signature over m2 never verifies for other parties: the parties swapped, or a third vault on either side; and a
    /// form 1 signature never verifies over form 2.
    @Test func m2NamesBothMembers() throws {
        let m = CallWire.offerMessage2(callId: callId, media: CallWire.mediaAudio, offered: offered, parties: parties, ek: ek)
        let sig = try CallWire.signShare(deviceIk: caller.device, message: m)
        let third = try Ed25519PrivateKey.fromSeed(rep(0x33, 32)).publicKey
        for p in [
            try CallWire.Parties(caller: callee.vaultIk, callee: caller.vaultIk),
            try CallWire.Parties(caller: third, callee: callee.vaultIk),
            try CallWire.Parties(caller: caller.vaultIk, callee: third),
        ] {
            let other = CallWire.offerMessage2(callId: callId, media: CallWire.mediaAudio, offered: offered, parties: p, ek: ek)
            #expect(!Ed25519.verify(caller.deviceIk, label: CallWire.labelShare, other, sig))
        }
        let m1 = CallWire.shareMessage(role: CallWire.roleOffer, callId: callId, media: CallWire.mediaAudio, share: ek)
        #expect(!Ed25519.verify(caller.deviceIk, label: CallWire.labelShare, m, try CallWire.signShare(deviceIk: caller.device, message: m1)))
    }

    @Test func theFormTwoCallKeyNamesBothMembers() throws {
        let k2 = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: parties)
        same("k_call2", try d.hex("k_call2_hex"), k2)
        // VAULT-MESSAGING 0.88.16 §16.
        same("k_call2 (spec §16)", try Bytes.unhex("fc69525bf7681cf0aa0bf2109578a36ba249fef9ea06a7f10bf6f44668d5612e"), k2)
        #expect(k2 != (try CallWire.accept(offerKey: offerKey, enc: enc, callId: callId)))
        let a = try deterministic(try d.hex("answer_randomness_hex")) { try CallWire.answer2(ek: ek, callId: callId, parties: parties) }
        same("enc (answer2)", enc, a.enc)
        same("k_call2 (answer2)", k2, a.kCall)
    }

    @Test func keyConfirmation() throws {
        let k2 = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: parties)
        let kc = try CallWire.confirmKey(kCall: k2, callId: callId)
        same("k_confirm", try d.hex("k_confirm_hex"), kc)
        let confirm = CallWire.confirm(kConfirm: kc, chosen: chosen, offered: offered, callId: callId, parties: parties)
        same("confirm", try d.b64("confirm_b64"), confirm)
        func ok(_ c: Int, _ o: [Int], _ p: CallWire.Parties, _ x: [UInt8]?) -> Bool {
            CallWire.verifyConfirm(kConfirm: kc, chosen: c, offered: o, callId: callId, parties: p, confirm: x)
        }
        #expect(ok(chosen, offered, parties, confirm))
        #expect(!ok(chosen + 1, offered, parties, confirm))
        #expect(!ok(chosen, [1, 2], parties, confirm))
        #expect(!ok(chosen, offered, try CallWire.Parties(caller: callee.vaultIk, callee: caller.vaultIk), confirm))
        #expect(!ok(chosen, offered, parties, nil))
        #expect(!ok(chosen, offered, parties, []))
        #expect(!ok(chosen, offered, parties, Array(confirm.prefix(31))))
        #expect(!ok(chosen, offered, parties, confirm + [0]))
        // §16: the other two cases.
        same("confirm 1/1", try Bytes.unhex("79c34a326ba978264d68200745b47606b51e21e76a392d00211d277b4613eb78"),
             CallWire.confirm(kConfirm: kc, chosen: 1, offered: [1], callId: callId, parties: parties))
        same("confirm 2 1/2", try Bytes.unhex("ae9cd7eb039aec21e28e12980d752412c0454713227ad338b2a9192235640976"),
             CallWire.confirm(kConfirm: kc, chosen: 2, offered: [2, 1], callId: callId, parties: parties))
        #expect(throws: CryptoError.self) { try CallWire.confirmKey(kCall: Array(k2.prefix(31)), callId: callId) }
        #expect(throws: CryptoError.self) { try CallWire.confirmKey(kCall: k2, callId: "") }
    }

    /// A call passed on by a third vault C: B derives "C calls B", A "A calls C"; B's confirm never verifies at A.
    @Test func aRelayedCallNeverConfirms() throws {
        let relay = try d.b64("relay_vault_ik_b64")
        same("relay ik (seed 0x56)", try Ed25519PrivateKey.fromSeed(rep(0x56, 32)).publicKey, relay)
        let atB = try CallWire.Parties(caller: relay, callee: callee.vaultIk)
        let atA = try CallWire.Parties(caller: caller.vaultIk, callee: relay)
        let kB = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: atB)
        same("k_call2 relayed (callee)", try d.hex("k_call2_relayed_callee_hex"), kB)
        let confirmB = CallWire.confirm(
            kConfirm: try CallWire.confirmKey(kCall: kB, callId: callId), chosen: chosen, offered: offered, callId: callId, parties: atB
        )
        same("confirm relayed", try d.b64("confirm_relayed_b64"), confirmB)
        let kA = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: atA)
        #expect(kA != kB)
        #expect(!CallWire.verifyConfirm(
            kConfirm: try CallWire.confirmKey(kCall: kA, callId: callId), chosen: chosen, offered: offered, callId: callId,
            parties: atA, confirm: confirmB
        ))
    }

    /// §16 (0.88.16): the form 2 direction and frame keys come from the bound k_call.
    @Test func formTwoMediaKeys() throws {
        let k2 = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: parties)
        let s1 = MediaSuite.aes128Gcm
        let s2 = MediaSuite.aes256Gcm
        let n11 = try CallMedia.Negotiated(chosen: s1, offered: [1])
        func dir(_ n: CallMedia.Negotiated, _ direction: String) throws -> [UInt8] {
            try CallMedia.directionKey(kCall: k2, negotiated: n, direction: direction, callId: callId)
        }
        same("k_dir caller 1/1", try Bytes.unhex("f50365693517abe27d0128be02100c7fa28d4ef8b849a49a760edb0f9bf4c51f"), try dir(n11, CallMedia.directionCaller))
        same("k_dir callee 1/1", try Bytes.unhex("91912e5c6fbdda2784745c28b07102a55c58cddc50cd2aef7d3a211568ced27e"), try dir(n11, CallMedia.directionCallee))
        same("k_dir caller 2 1/1", try Bytes.unhex("157c0c53b1c46a9f90b8497b119546119000c34847440c537ae28cc556d46659"),
             try dir(try CallMedia.Negotiated(chosen: s1, offered: [2, 1]), CallMedia.directionCaller))
        let kDir2 = try dir(try CallMedia.Negotiated(chosen: s2, offered: [2, 1]), CallMedia.directionCaller)
        same("k_dir caller 2 1/2", try Bytes.unhex("4ac64a47eeb6199469d98039e28131e86927ae28adf6c5a302cffc295d27b542"), kDir2)
        same("frame key caller 1/1", try Bytes.unhex("83366919df86b7fc3a43c5c92f8367bd"),
             try CallFrames.frameKey(try dir(n11, CallMedia.directionCaller), suite: s1))
        same("frame key callee 1/1", try Bytes.unhex("f48a7399a6eebe7f53324dc50de746f7"),
             try CallFrames.frameKey(try dir(n11, CallMedia.directionCallee), suite: s1))
        same("frame key caller 2 1/2", try Bytes.unhex("576b179f1a55bbb44af932f3b613a258229eee91098b046dc35f8ea8fa6d9447"),
             try CallFrames.frameKey(kDir2, suite: s2))
    }

    /// §16 (0.88.16): the two confirms that MUST NOT verify, the two keys swapped ("2 1", "1").
    @Test func swappedPartiesNeverConfirm() throws {
        let k2 = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: parties)
        let kc = try CallWire.confirmKey(kCall: k2, callId: callId)
        let swapped = try CallWire.Parties(caller: callee.vaultIk, callee: caller.vaultIk)
        let inHmacOnly = CallWire.confirm(kConfirm: kc, chosen: 1, offered: [2, 1], callId: callId, parties: swapped)
        same("swapped in the HMAC input only", try Bytes.unhex("987cb11aea0528421f48a28898b26e1e1b1d8bf98c9c8dde0b60046eb52f5dec"), inHmacOnly)
        let kSwapped = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: swapped)
        let inKCallToo = CallWire.confirm(
            kConfirm: try CallWire.confirmKey(kCall: kSwapped, callId: callId), chosen: 1, offered: [2, 1], callId: callId, parties: swapped
        )
        same("swapped in k_call too", try Bytes.unhex("b5bd80febcdfa5939a6624ae625e502ebb33dfca7ee9902d207da637371ce5a1"), inKCallToo)
        for c in [inHmacOnly, inKCallToo] {
            #expect(!CallWire.verifyConfirm(kConfirm: kc, chosen: 1, offered: [2, 1], callId: callId, parties: parties, confirm: c))
        }
        same("confirm 2 1/1", try Bytes.unhex("5ed63e824d485ef4e2af8ac7d58936fec1eec26a437b5506722692e5db83357c"),
             CallWire.confirm(kConfirm: kc, chosen: 1, offered: [2, 1], callId: callId, parties: parties))
    }

    /// §16 (0.88.16): the relayed call's k_call and confirm, as printed.
    @Test func theRelayedCallsSpecValues() throws {
        let relay = try d.b64("relay_vault_ik_b64")
        same("relay ik", try Bytes.unhex("88df556413538b002015e9619b01bdb5cc48c7215645792563f5460f7307a763"), relay)
        let atB = try CallWire.Parties(caller: relay, callee: callee.vaultIk)
        let kB = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: atB)
        same("k_call relayed", try Bytes.unhex("658f2ce918bdb72fec26036eea2ad4a8b34e5e813713f301fd70c377639af947"), kB)
        same("confirm relayed", try Bytes.unhex("50abad6efd920a5dc6eb226a5daf8cff00fcca0bbc261d454637f0faf9641f0e"),
             CallWire.confirm(kConfirm: try CallWire.confirmKey(kCall: kB, callId: callId), chosen: 1, offered: [2, 1], callId: callId, parties: atB))
    }

    @Test func partiesMustBeKeysAndShowNone() throws {
        #expect(throws: CryptoError.self) { try CallWire.Parties(caller: [UInt8](repeating: 1, count: 31), callee: callee.vaultIk) }
        #expect(throws: CryptoError.self) { try CallWire.Parties(caller: caller.vaultIk, callee: []) }
        #expect("\(parties)" == "Parties")
    }

    @Test func theFormTwoExportIsWipedToo() throws {
        let a = try deterministic(try d.hex("answer_randomness_hex")) { try CallWire.answer2(ek: ek, callId: callId, parties: parties) }
        #expect("\(a)" == "Answered([redacted])")
        #expect(throws: CryptoError.self) { try CallWire.answer2(ek: Array(ek.prefix(10)), callId: callId, parties: parties) }
        #expect(throws: CryptoError.self) { try CallWire.accept2(offerKey: offerKey, enc: Array(enc.prefix(10)), callId: callId, parties: parties) }
    }
}

// swiftlint:enable line_length
