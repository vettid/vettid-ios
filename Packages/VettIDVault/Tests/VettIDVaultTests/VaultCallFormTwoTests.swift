import Foundation
import Testing
import VettIDCrypto
import VettIDRelay
import VettIDTesting
@testable import VettIDVault

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length function_body_length

/// (C2) Form 2 of the call shares, the key confirmation, `call.keepalive` and `call.list` `v: 2` (VAULT-MESSAGING 0.88.16
/// §10.10 "Call forms", "Key confirmation", "Liveness", "Mixed releases"), against the fake vault. Mirrors the C2 cases
/// of vettid-android `CallApiTest`.
extension VaultDeviceTests {
    /// A form 2 start: both forms, `keepalive`, and the device's signature over `m2` naming this vault and the connection's.
    /// The peer's form 2 answer is taken only when everything in it checks out, `confirm` first among the keys.
    @Test func aFormTwoCallIsPlacedAndItsAnswerConfirmed() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        let sdp = Self.callSdp
        let parties = try CallWire.Parties(caller: v.ik.publicKey, callee: peer.vault.publicKey)

        // An engine of suites 2 and 1 still offers 1 alone: form 1 is in every start (rule 3).
        let starting = Task {
            try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: sdp, suites: MediaSuite.allCases, peerIk: peer.vault.publicKey)
        }
        let req = try v.open(try await relay.nextDeposit().payload)
        let b = try StrictJson.parseObject(req.body)
        let callId = try b.string("call_id")
        let ek = try b.base64("ek", 1216)
        #expect(try CallMedia.offeredIn(b.string("sdp")) == [1], "form 1's attribute stays for an S10 peer")
        #expect(Ed25519.verify(secrets.identity.publicKey, label: CallWire.labelShare, CallWire.shareMessage(role: "offer", callId: callId, media: "audio", share: ek), try b.base64("ek_sig", 64)))
        #expect(try b.array("suites").map { try $0.asUint(min: 1, max: 65535) } == [1])
        #expect(Ed25519.verify(secrets.identity.publicKey, label: CallWire.labelShare, CallWire.offerMessage2(callId: callId, media: "audio", offered: [1], parties: parties, ek: ek), try b.base64("ek_sig2", 64)))
        #expect(try b.bool("keepalive"))
        let exp = try millis(Date().addingTimeInterval(45))
        try await d.handle(try v.seal("call.start", try iceBody(JsonBuilder().string("call_id", callId).string("exp", ts(exp)), v, callId).build(), re: req.id, status: Inner.statusOK))
        let call = try await starting.value
        #expect(call.formTwo)

        // The callee answers in form 2.
        let a = try CallWire.answer2(ek: ek, callId: callId, parties: parties)
        let n = try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1])
        var kc = try CallWire.confirmKey(kCall: a.kCall, callId: callId)
        let confirm = CallWire.confirm(kConfirm: kc, chosen: 1, offered: [1], callId: callId, parties: parties)
        Bytes.wipe(&kc)
        let fromCaller = try CallMedia.directionKey(kCall: a.kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId)
        let fromCallee = try CallMedia.directionKey(kCall: a.kCall, negotiated: n, direction: CallMedia.directionCallee, callId: callId)
        let other = try CallPeer()
        func answer(
            suite: String? = "1", offered: String? = "[1]", confirm c: [UInt8]? = nil, signedChosen: Int = 1, signedOffered: [Int] = [1],
            signedParties: CallWire.Parties? = nil, voucher: CallPeer? = nil
        ) throws -> String {
            let by = voucher ?? peer
            let m = CallWire.answerMessage2(callId: callId, chosen: signedChosen, offered: signedOffered, parties: signedParties ?? parties, enc: a.enc)
            var body = JsonBuilder().string("call_id", callId).string("sdp", sdp).base64("enc", a.enc)
            if let suite { body = body.raw("suite", suite) }
            if let offered { body = body.raw("offered", offered) }
            body = body.base64("confirm", c ?? confirm)
            return try by.vouched(body, m).build()
        }
        func take(_ body: String) async throws -> VaultMessage {
            try await d.handle(try v.seal("call.answer", body))
            return try await d.awaitEvent("call.answer")
        }
        var wrong = confirm
        wrong[0] ^= 1
        let bad: [String] = [
            try answer(suite: nil), // part of form 2
            try answer(confirm: []).replacingOccurrences(of: #","confirm":"""#, with: ""), // no confirm: part of form 2
            try answer(confirm: wrong), // a wrong confirm
            try answer(confirm: Array(confirm.prefix(31))), // a short confirm
            try answer(offered: "[2,1]", signedOffered: [2, 1]), // not the list sent, signed as such
            try answer(suite: "2", signedChosen: 2), // a suite that was not offered
            try answer(suite: "\"1\""), // a suite as a string
            try answer(offered: "[1,1]", signedOffered: [1, 1]), // a repeated suite
            try answer(offered: "[]", signedOffered: []), // no suites
            try answer(suite: "1.0"), // not a plain integer
            try answer(signedParties: try CallWire.Parties(caller: v.ik.publicKey, callee: other.vault.publicKey)), // m2 names another callee
            try answer(signedChosen: 2), // signed over another choice
            try answer(voucher: other), // vouched by a vault that is not the connection's
        ]
        for body in bad {
            let ev = try await take(body)
            #expect(throws: CallMessageError.self, "\(body.prefix(80))") { try api.callAccept(call, event: ev) }
        }
        // None of that spent the call's key, and the right answer gives the form 2 keys.
        let accepted = try api.callAccept(call, event: try await take(try answer()))
        #expect(accepted.sdp == sdp)
        #expect(try accepted.keys.send() == fromCaller)
        #expect(try accepted.keys.receive() == fromCallee)
    }

    /// The parties are fixed at the offer: a start naming one key, answered by a connection whose `peer_ik` is the pinned
    /// one but not that key, is refused ("the answer names another callee"). A form 2 answer to a form 1 offer is refused;
    /// a form 1 answer to a form 2 offer (an S10 vault or an older app on the path) is taken under form 1's rules.
    @Test func formTwoAnswersAreTakenOnlyForTheirOwnOffer() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        let other = try CallPeer()
        let sdp = Self.callSdp
        func place(peerIk: [UInt8]?) async throws -> (OutgoingCall, [UInt8]) {
            let starting = Task { try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: sdp, peerIk: peerIk) }
            let req = try v.open(try await relay.nextDeposit().payload)
            let b = try StrictJson.parseObject(req.body)
            let callId = try b.string("call_id")
            if peerIk == nil {
                #expect(!b.has("suites") && !b.has("ek_sig2") && !b.has("keepalive"), "form 1 only, as to an S10 vault")
            }
            try await d.handle(try v.seal("call.start", try iceBody(JsonBuilder().string("call_id", callId).string("exp", ts(Date().addingTimeInterval(45))), v, callId).build(), re: req.id, status: Inner.statusOK))
            return (try await starting.value, try b.base64("ek", 1216))
        }
        func take(_ body: String) async throws -> VaultMessage {
            try await d.handle(try v.seal("call.answer", body))
            return try await d.awaitEvent("call.answer")
        }
        func form2Answer(_ call: OutgoingCall, _ ek: [UInt8], _ parties: CallWire.Parties) throws -> String {
            let a = try CallWire.answer2(ek: ek, callId: call.callId, parties: parties)
            var kc = try CallWire.confirmKey(kCall: a.kCall, callId: call.callId)
            defer { Bytes.wipe(&kc) }
            let confirm = CallWire.confirm(kConfirm: kc, chosen: 1, offered: [1], callId: call.callId, parties: parties)
            let m = CallWire.answerMessage2(callId: call.callId, chosen: 1, offered: [1], parties: parties, enc: a.enc)
            return try peer.vouched(JsonBuilder().string("call_id", call.callId).string("sdp", sdp).base64("enc", a.enc).raw("suite", "1").raw("offered", "[1]").base64("confirm", confirm), m).build()
        }

        // Placed naming another connection's key: the pinned peer's answer, good in itself, names another callee.
        let (named, ek1) = try await place(peerIk: other.vault.publicKey)
        let asPeer = try CallWire.Parties(caller: v.ik.publicKey, callee: peer.vault.publicKey)
        let ev1 = try await take(try form2Answer(named, ek1, asPeer))
        #expect(throws: CallMessageError.self) { try api.callAccept(named, event: ev1) }

        // A form 1 offer gets a form 2 answer: refused.
        let (formOne, ek2) = try await place(peerIk: nil)
        #expect(!formOne.formTwo)
        let ev2 = try await take(try form2Answer(formOne, ek2, asPeer))
        #expect(throws: CallMessageError.self) { try api.callAccept(formOne, event: ev2) }

        // A form 2 offer gets a form 1 answer: taken under form 1's rules (suite 1, form 1's k_call).
        let (formTwo, ek3) = try await place(peerIk: peer.vault.publicKey)
        let a = try CallWire.answer(ek: ek3, callId: formTwo.callId)
        let m = CallWire.shareMessage(role: "answer", callId: formTwo.callId, media: "", share: a.enc)
        let ev3 = try await take(try peer.vouched(JsonBuilder().string("call_id", formTwo.callId).string("sdp", CallMedia.sdpWithChoice(sdp, chosen: .aes128Gcm)).base64("enc", a.enc), m).build())
        let accepted = try api.callAccept(formTwo, event: ev3)
        let n = try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1])
        #expect(try accepted.keys.send() == CallMedia.directionKey(kCall: a.kCall, negotiated: n, direction: CallMedia.directionCaller, callId: formTwo.callId))
    }

    /// An incoming form 2 offer: every form it carries is checked, part of form 2 never rings, the choice is from the
    /// signed list (the SDP attribute ignored), and the answer is in form 2 with a `confirm` the caller verifies.
    @Test func aFormTwoOfferIsCheckedAndAnsweredInFormTwo() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        let other = try CallPeer()
        let sdp = Self.callSdp
        let callId = Ulid.new()
        let offerKey = try CallWire.newOfferKey()
        let ek = offerKey.publicKey.bytes
        let parties = try CallWire.Parties(caller: peer.vault.publicKey, callee: v.ik.publicKey)
        let exp = try millis(Date().addingTimeInterval(45))
        func offer(
            suites: String? = "[1]", signedSuites: [Int] = [1], signedParties: CallWire.Parties? = nil, sig2: Bool = true, vouch2: Bool = true,
            vouch2By: CallPeer? = nil, sdpSuites: [Int] = [1], media2: String = "audio"
        ) throws -> String {
            let m = CallWire.shareMessage(role: "offer", callId: callId, media: "audio", share: ek)
            var base = JsonBuilder().string("call_id", callId).string("connection_id", "conn-1").string("media", "audio")
                .string("sdp", try CallMedia.sdpWithOffer(sdp, offered: sdpSuites)).base64("ek", ek).string("exp", ts(exp))
            base = try peer.vouched(try iceBody(base, v, callId), m)
            let m2 = CallWire.offerMessage2(callId: callId, media: media2, offered: signedSuites, parties: signedParties ?? parties, ek: ek)
            if let suites { base = base.raw("suites", suites) }
            if sig2 { base = base.base64("device_sig2", try CallWire.signShare(deviceIk: peer.device, message: m2)) }
            if vouch2 {
                let by = (vouch2By ?? peer).vault
                base = base.base64("vault_sig2", try by.sign(label: CallWire.labelVouch, CallWire.vouchMessage(deviceIk: peer.device.publicKey, message: m2)))
            }
            return base.build()
        }
        func take(_ body: String) async throws -> VaultMessage {
            try await d.handle(try v.seal("call.offer", body))
            return try await d.awaitEvent("call.offer")
        }
        let bad: [String] = [
            try offer(suites: nil), // part of form 2
            try offer(sig2: false),
            try offer(vouch2: false),
            try offer(signedParties: try CallWire.Parties(caller: other.vault.publicKey, callee: v.ik.publicKey)), // names another caller
            try offer(signedParties: try CallWire.Parties(caller: peer.vault.publicKey, callee: other.vault.publicKey)), // another callee
            try offer(vouch2By: other), // form 2 vouched by another vault
            try offer(suites: "[1,2]"), // the list is not the one signed
            try offer(media2: "video"), // signed for another media
            try offer(suites: "[\"1\"]", signedSuites: [1]), // a suite as a string
            try offer(suites: "[1,1]", signedSuites: [1, 1]), // repeated
            try offer(suites: "[0]", signedSuites: [0]), // out of range
            try offer(suites: "[1,2,3,4,5,6,7,8,9]", signedSuites: [1, 2, 3, 4, 5, 6, 7, 8, 9]), // more than 8
            try offer(suites: "[2]", signedSuites: [2]), // no suite this device can do
        ]
        for body in bad {
            let ev = try await take(body)
            #expect(throws: CallMessageError.self, "\(body.suffix(80))") { try api.callIncoming(ev, pinnedFingerprint: peer.pinned) }
        }
        // The SDP attribute is ignored in form 2: it says 2, the signed list says 1.
        let call = try api.callIncoming(try await take(try offer(sdpSuites: [2])), pinnedFingerprint: peer.pinned, suites: MediaSuite.allCases)
        #expect(call.formTwo)
        #expect(call.negotiated == (try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1])))
        #expect(call.sdp == sdp, "no VettID attribute reaches the media stack")

        let keys = try await api.callAnswer(call, sdp: sdp, keepalive: true)
        let ans = try v.open(try await relay.nextDeposit().payload)
        #expect(ans.type == "call.answer")
        let b = try StrictJson.parseObject(ans.body)
        #expect(try b.string("sdp") == sdp, "a form 2 answer's SDP carries no VettID attribute")
        #expect(try b.uint("suite", min: 1, max: 65535) == 1)
        #expect(try b.array("offered").map { try $0.asUint(min: 1, max: 65535) } == [1])
        #expect(try b.bool("keepalive"))
        let enc = try b.base64("enc", 1120)
        #expect(Ed25519.verify(secrets.identity.publicKey, label: CallWire.labelShare, CallWire.answerMessage2(callId: callId, chosen: 1, offered: [1], parties: parties, enc: enc), try b.base64("enc_sig", 64)))
        // The caller derives the same form 2 key and verifies confirm.
        var kCall = try CallWire.accept2(offerKey: offerKey, enc: enc, callId: callId, parties: parties)
        let kc = try CallWire.confirmKey(kCall: kCall, callId: callId)
        #expect(CallWire.verifyConfirm(kConfirm: kc, chosen: 1, offered: [1], callId: callId, parties: parties, confirm: try b.base64("confirm", 32)))
        let n = try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1])
        #expect(try keys.send() == CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCallee, callId: callId))
        #expect(try keys.receive() == CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId))
        Bytes.wipe(&kCall)

        // A form 1 offer is answered in form 1, with keepalive only when asked.
        let formOneId = Ulid.new()
        let m1 = CallWire.shareMessage(role: "offer", callId: formOneId, media: "audio", share: ek)
        let base = JsonBuilder().string("call_id", formOneId).string("connection_id", "conn-1").string("media", "audio")
            .string("sdp", try CallMedia.sdpWithOffer(sdp, offered: [1])).base64("ek", ek).string("exp", ts(exp))
        let one = try api.callIncoming(try await take(try peer.vouched(try iceBody(base, v, formOneId), m1).build()), pinnedFingerprint: peer.pinned)
        #expect(!one.formTwo)
        _ = try await api.callAnswer(one, sdp: sdp)
        let b1 = try StrictJson.parseObject(try v.open(try await relay.nextDeposit().payload).body)
        #expect(!b1.has("suite") && !b1.has("offered") && !b1.has("confirm") && !b1.has("keepalive"))
        #expect(try CallMedia.chosenIn(b1.string("sdp"), offered: [1]).chosen == .aes128Gcm)
    }

    /// `call.keepalive` is ephemeral, with `exp` 30 s ahead; `call.list` says the vault is C2 only with `v: 2` and `now`,
    /// and reads each entry's `exp` and `device_id` (an `exp` that is not a time leaves the entry out).
    @Test func keepalivesAndTheVaultsLevel() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let api = VaultApi(device: d)
        let callId = Ulid.new()
        try await api.callKeepalive(callId)
        let k = try v.open(try await relay.nextDeposit().payload)
        #expect(k.type == "call.keepalive")
        #expect(String(bytes: k.body, encoding: .utf8) == #"{"call_id":"\#(callId)"}"#)
        let kExp = try #require(k.exp)
        #expect(kExp > Date().addingTimeInterval(25) && kExp < Date().addingTimeInterval(31))
        #expect(try savedState(store).outbox.isEmpty, "never kept for a later send")

        func list(_ body: String) async throws -> CallList {
            let t = Task { try await api.callList() }
            let req = try v.open(try await relay.nextDeposit().payload)
            try await d.handle(try v.seal("call.list", body, re: req.id, status: Inner.statusOK))
            return try await t.value
        }
        let entry = #"{"call_id":"01JZZZZZZZZZZZZZZZZZZZZZZZ","connection_id":"k","direction":"out","media":"audio","state":"active","started_at":"2026-11-27T10:00:00.000Z","exp":"2026-11-27T10:00:45.000Z","device_id":"dev-1"}"#
        let badExp = #"{"call_id":"x","connection_id":"k","direction":"out","media":"audio","state":"ended","started_at":"2026-11-27T10:00:00.000Z","exp":"soon"}"#
        let c2 = try await list(#"{"v":2,"now":"2026-11-27T10:01:00.000Z","calls":["# + entry + "," + badExp + "]}")
        #expect(c2.formTwo)
        #expect(c2.version == 2)
        #expect(c2.now == (try Timestamps.parseMillis("2026-11-27T10:01:00.000Z")))
        #expect(c2.calls.count == 1 && c2.skipped == 1)
        #expect(c2.calls.first?.deviceId == "dev-1")
        #expect(c2.calls.first?.exp == "2026-11-27T10:00:45.000Z")
        for body in [#"{"calls":[]}"#, #"{"v":2,"calls":[]}"#, #"{"v":1,"now":"2026-11-27T10:01:00.000Z","calls":[]}"#, #"{"v":"2","now":"2026-11-27T10:01:00.000Z"}"#, #"{"v":2,"now":"later"}"#] {
            #expect(try await !list(body).formTwo, "\(body)")
        }
    }
}

// swiftlint:enable line_length function_body_length
