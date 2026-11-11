import Foundation
import Testing
import VettIDCrypto
import VettIDRelay
import VettIDTesting
@testable import VettIDVault

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length function_body_length

/// The seven `call.*` types of VAULT-MESSAGING §10.10 as the app sends and receives them (CALLS-PLAN phase C1), against
/// the fake vault. Mirrors the calls cases of vettid-android `VaultDeviceTest`.
extension VaultDeviceTests {
    /// The other member of a call: a device, its vault, and the bodies they would produce.
    struct CallPeer {
        let device = Ed25519PrivateKey.generate()
        let vault = Ed25519PrivateKey.generate()
        /// The connection's identity as the app shows it (§10.8): what a call is checked against.
        let pinned: String

        init() throws { pinned = try IkFingerprint.format(vault.publicKey) }

        /// The vouched signatures of a share, with `peer_ik` as this app's own vault adds it.
        func vouched(_ b: JsonBuilder, _ m: [UInt8], voucher: Ed25519PrivateKey? = nil, peerIk: [UInt8]? = nil) throws -> JsonBuilder {
            let vouchedBy = voucher ?? vault
            return b.base64("device_ik", device.publicKey).base64("device_sig", try CallWire.signShare(deviceIk: device, message: m))
                .base64("vault_sig", try vouchedBy.sign(label: CallWire.labelVouch, CallWire.vouchMessage(deviceIk: device.publicKey, message: m)))
                .base64("peer_ik", peerIk ?? vault.publicKey)
        }
    }

    static let callFp = "0000 1111 2222 3333 4444 5555 6666 7777"
    static let callSdp = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n"
    static let secondAudio = "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n"

    /// A body with the vault-signed (empty) ICE configuration of [callId].
    func iceBody(_ b: JsonBuilder, _ v: FakeVault, _ callId: String, exp: Date = Date().addingTimeInterval(21_600)) throws -> JsonBuilder {
        let cfg = try CallWire.marshalIce(CallWire.IceConfig(callId: callId, exp: Date(timeIntervalSince1970: exp.timeIntervalSince1970.rounded(.down)), servers: []))
        return b.base64("ice_config", cfg).base64("ice_sig", try v.ik.sign(label: CallWire.labelIce, cfg))
    }

    func ts(_ t: Date) -> String { Timestamps.formatMillis(t) }

    func millis(_ t: Date) throws -> Date { try Timestamps.parseMillis(Timestamps.formatMillis(t)) }

    /// An outgoing call: `call.start` is deposited once with a signed share, the answer is verified, and both devices hold
    /// the same two keys.
    @Test func placingACallAndTakingTheAnswer() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        let sdp = Self.callSdp

        // An engine that can do suites 2 and 1: form 1 offers suite 1 only (VAULT-MESSAGING §10.10 "Call forms", rule 3).
        let starting = Task { try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: sdp, suites: MediaSuite.allCases) }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(req.type == "call.start")
        #expect(req.exp == nil)
        #expect(try savedState(store).outbox.isEmpty, "never in the outbox")
        let b = try StrictJson.parseObject(req.body)
        let callId = try b.string("call_id")
        #expect(Ulid.isValid(callId))
        #expect(try b.string("connection_id") == "conn-1")
        #expect(try b.string("media") == "audio")
        #expect(try CallMedia.offeredIn(b.string("sdp")) == [1])
        let ek = try b.base64("ek", 1216)
        #expect(Ed25519.verify(secrets.identity.publicKey, label: CallWire.labelShare, CallWire.shareMessage(role: "offer", callId: callId, media: "audio", share: ek), try b.base64("ek_sig", 64)))
        let exp = try millis(Date().addingTimeInterval(45))
        try await d.handle(try v.seal("call.start", try iceBody(JsonBuilder().string("call_id", callId).string("exp", ts(exp)), v, callId).build(), re: req.id, status: Inner.statusOK))
        let call = try await starting.value
        #expect(call.callId == callId)
        #expect(call.exp == exp)
        #expect(call.ice.servers.isEmpty)

        // The callee's device answers: enc, its choice of suite in the SDP, the vouched share.
        let a = try CallWire.answer(ek: ek, callId: callId)
        let expected = try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1])
        let fromCaller = try CallMedia.directionKey(kCall: a.kCall, negotiated: expected, direction: CallMedia.directionCaller, callId: callId)
        let fromCallee = try CallMedia.directionKey(kCall: a.kCall, negotiated: expected, direction: CallMedia.directionCallee, callId: callId)
        let m = CallWire.shareMessage(role: "answer", callId: callId, media: "", share: a.enc)
        let other = try CallPeer()
        func answer(
            sdpAnswer: String? = nil, enc: [UInt8]? = nil, voucher: Ed25519PrivateKey? = nil, peerIk: [UInt8]? = nil
        ) throws -> String {
            let reply = sdpAnswer ?? CallMedia.sdpWithChoice(sdp, chosen: .aes128Gcm)
            return try peer.vouched(JsonBuilder().string("call_id", callId).string("sdp", reply).base64("enc", enc ?? a.enc), m, voucher: voucher, peerIk: peerIk).build()
        }
        func take(_ body: String) async throws -> VaultMessage {
            try await d.handle(try v.seal("call.answer", body))
            return try await d.awaitEvent("call.answer")
        }

        // The device's signature is good, but the vouch is another vault's; or the whole answer is another vault's,
        // consistent in itself, with its own `peer_ik`: not the connection the member called.
        for bad in [try answer(voucher: other.vault), try answer(voucher: other.vault, peerIk: other.vault.publicKey)] {
            let ev = try await take(bad)
            #expect(throws: CallMessageError.self) { try api.callAccept(call, event: ev) }
        }
        let right = try await take(try answer())

        // A share that was swapped on the way, an answer without the suite, a suite that was not offered, an answer for
        // another call: unusable. And an answer with a second media section: its audio would play outside the frame
        // encryption.
        let twoSections = CallMedia.sdpWithChoice(sdp + Self.secondAudio, chosen: .aes128Gcm)
        let swappedShare = try answer(enc: CallWire.answer(ek: ek, callId: callId).enc)
        let others = [swappedShare, try answer(sdpAnswer: sdp), try answer(sdpAnswer: CallMedia.sdpWithChoice(sdp, chosen: .aes256Gcm)), try answer(sdpAnswer: twoSections)]
        for bad in others {
            let ev = try await take(bad)
            #expect(throws: CallMessageError.self, "\(bad.prefix(60))") { try api.callAccept(call, event: ev) }
        }
        let elsewhere = try await take(try answer().replacingOccurrences(of: callId, with: String(callId.dropLast()) + "1"))
        #expect(throws: CallMessageError.self) { try api.callAccept(call, event: elsewhere) }
        // None of that spent the call's key: the right answer still works.
        let accepted = try api.callAccept(call, event: try await take(try answer()))
        #expect(accepted.sdp == sdp, "the media stack gets the SDP without VettID's attribute")
        #expect(accepted.keys.suite == .aes128Gcm)
        #expect(try accepted.keys.send() == fromCaller)
        #expect(try accepted.keys.receive() == fromCallee)
        #expect(!"\(accepted.keys)".contains(Bytes.hex(fromCaller)), "no key in a log line")
        accepted.keys.destroy()
        #expect(throws: VaultStateError.self) { try accepted.keys.send() }
        #expect(throws: VaultStateError.self) { try accepted.keys.receive() }
        // The ephemeral key is gone with the answer: the same answer taken again (a replay) finds no key.
        #expect(throws: CryptoError.self) { try call.key().seed() }
        #expect(throws: CallMessageError.self) { try api.callAccept(call, event: right) }

        // A refusal is the vault's code.
        let refused = Task { try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: sdp) }
        let r2 = try v.open(try await relay.nextDeposit().payload)
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(Inner(id: Ulid.new(), type: r2.type, ts: Date(), re: r2.id, status: Inner.statusError, error: InnerError("busy")))))
        do {
            _ = try await refused.value
            Issue.record("expected busy")
        } catch let e as VaultOpError {
            #expect(e.code == "busy")
        }

        // An ICE configuration signed by anyone but this device's vault, or for another call, is refused.
        #expect(await relay.noDeposit(within: 0.3), "the vault refused: there is no call to end")
        let forged = Task { try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: sdp) }
        let r3 = try v.open(try await relay.nextDeposit().payload)
        let id3 = try StrictJson.parseObject(r3.body).string("call_id")
        let cfg = try CallWire.marshalIce(CallWire.IceConfig(callId: id3, exp: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 600), servers: [CallWire.IceServer(urls: ["turn:evil.example:3478"], username: "u", credential: "p")]))
        let forgedBody = JsonBuilder().string("call_id", id3).string("exp", ts(exp)).base64("ice_config", cfg).base64("ice_sig", try peer.vault.sign(label: CallWire.labelIce, cfg)).build()
        try await d.handle(try v.seal("call.start", forgedBody, re: r3.id, status: Inner.statusOK))
        do {
            _ = try await forged.value
            Issue.record("expected a refusal")
        } catch is CallMessageError {
        }
        // The vault did place that call: it is rung off, or the other phone would ring for 45 s for nobody.
        let rungOff = try v.open(try await relay.nextDeposit().payload)
        #expect(rungOff.type == "call.end")
        #expect(String(bytes: rungOff.body, encoding: .utf8) == #"{"call_id":"\#(id3)","reason":"hangup"}"#)

        // The answer names another call than the one asked for: refused, and rung off.
        let wrongCall = Task { try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: sdp) }
        let r4 = try v.open(try await relay.nextDeposit().payload)
        let id4 = try StrictJson.parseObject(r4.body).string("call_id")
        let otherId = String(id4.dropLast()) + (id4.hasSuffix("1") ? "2" : "1")
        try await d.handle(try v.seal("call.start", try iceBody(JsonBuilder().string("call_id", otherId).string("exp", ts(exp)), v, otherId).build(), re: r4.id, status: Inner.statusOK))
        await #expect(throws: CallMessageError.self) { _ = try await wrongCall.value }
        #expect(try v.open(try await relay.nextDeposit().payload).type == "call.end")

        // The device's own SDP is held to the same shape.
        await #expect(throws: CallMessageError.self) { _ = try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: sdp + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n") }
        // Guard: a form 1 `call.start` never offers anything but [1]. An engine of suite 2 alone has nothing form 1 may
        // offer: refused before anything leaves.
        await #expect(throws: CallMessageError.self) { _ = try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: sdp, suites: [.aes256Gcm]) }
        #expect(await relay.noDeposit(within: 0.3), "nothing left the phone")
    }

    /// An incoming call: the offer is checked before it may ring; the answer carries a signed share and the keys match the
    /// caller's.
    @Test func takingAnOfferAndAnsweringIt() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        let sdp = Self.callSdp
        let callId = Ulid.new()
        let offerKey = try CallWire.newOfferKey()
        let ek = offerKey.publicKey.bytes
        let m = CallWire.shareMessage(role: "offer", callId: callId, media: "audio", share: ek)
        let exp = try millis(Date().addingTimeInterval(45))
        func offer(
            offerSdp: String? = nil, share: [UInt8]? = nil, at: Date? = nil, iceExp: Date = Date().addingTimeInterval(21_600),
            signed: [UInt8]? = nil, voucher: Ed25519PrivateKey? = nil, peerIk: [UInt8]? = nil, media: String = "audio"
        ) throws -> String {
            let base = JsonBuilder().string("call_id", callId).string("connection_id", "conn-1").string("media", media)
                .string("sdp", try offerSdp ?? CallMedia.sdpWithOffer(sdp, offered: [1])).base64("ek", share ?? ek).string("exp", ts(try millis(at ?? exp)))
            return try peer.vouched(try iceBody(base, v, callId, exp: iceExp), signed ?? m, voucher: voucher, peerIk: peerIk).build()
        }
        let other = try CallPeer()
        func take(_ body: String) async throws -> VaultMessage {
            try await d.handle(try v.seal("call.offer", body))
            return try await d.awaitEvent("call.offer")
        }

        let bad: [String] = [
            try offer(share: try CallWire.newOfferKey().publicKey.bytes), // a swapped key
            try offer(signed: CallWire.shareMessage(role: "offer", callId: callId, media: "video", share: ek)), // signed for another media
            try offer(voucher: other.vault), // a good device signature, another vault's vouch
            try offer(voucher: other.vault, peerIk: other.vault.publicKey), // another vault's offer, consistent in itself
            try offer(offerSdp: CallMedia.sdpWithOffer(sdp, offered: [2])), // no suite this device can do: refused before it rings
            try offer(offerSdp: sdp), // no media suites
            try offer(offerSdp: CallMedia.sdpWithOffer(sdp + Self.secondAudio, offered: [1])), // a second audio section
            try offer(offerSdp: CallMedia.sdpWithOffer(sdp + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n", offered: [1])), // a data channel
            try offer(offerSdp: CallMedia.sdpWithOffer(sdp.replacingOccurrences(of: "opus/48000/2", with: "PCMU/8000"), offered: [1])), // not Opus
            try offer(at: Date().addingTimeInterval(-1)), // expired
            try offer(at: Date().addingTimeInterval(600)), // too far ahead
            try offer(iceExp: Date().addingTimeInterval(-5)), // an expired ICE configuration
            try offer(media: "screen"), // a media this app does not know
        ]
        for b in bad {
            let ev = try await take(b)
            #expect(throws: CallMessageError.self, "\(b.prefix(60))") { try api.callIncoming(ev, pinnedFingerprint: peer.pinned) }
        }
        // A good offer checked against another connection's identity, or against none, does not ring either.
        let good = try await take(try offer())
        #expect(throws: CallMessageError.self) { try api.callIncoming(good, pinnedFingerprint: other.pinned) }
        #expect(throws: CallMessageError.self) { try api.callIncoming(good, pinnedFingerprint: "") }
        // A device that can do suites 2 and 1 answers a form 1 `2 1` offer with 1, fixed before it rings, and does not
        // ring for a form 1 offer of suite 2 alone (VAULT-MESSAGING §10.10 "Call forms", rule 1).
        let two = try api.callIncoming(try await take(try offer(offerSdp: CallMedia.sdpWithOffer(sdp, offered: [2, 1]))), pinnedFingerprint: peer.pinned, suites: MediaSuite.allCases)
        #expect(two.negotiated == (try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [2, 1])))
        let onlyTwo = try await take(try offer(offerSdp: CallMedia.sdpWithOffer(sdp, offered: [2])))
        #expect(throws: CallMessageError.self) { try api.callIncoming(onlyTwo, pinnedFingerprint: peer.pinned, suites: MediaSuite.allCases) }

        let call = try api.callIncoming(try await take(try offer()), pinnedFingerprint: peer.pinned)
        #expect((44...45).contains(Int(call.ringFor)), "rings for the offer's lifetime by the vault's clock")
        #expect(call.callId == callId)
        #expect(call.connectionId == "conn-1")
        #expect(call.exp == exp)
        #expect(call.sdp == sdp)
        #expect(call.offered == [1])
        #expect("\(call)" == "IncomingCall(\(callId))")

        try await api.callRinging(callId)
        let ringing = try v.open(try await relay.nextDeposit().payload)
        #expect(ringing.type == "call.ringing")
        let ringExp = try #require(ringing.exp)
        #expect(ringExp > Date() && ringExp < Date().addingTimeInterval(31), "ephemeral")

        let keys = try await api.callAnswer(call, sdp: sdp)
        let ans = try v.open(try await relay.nextDeposit().payload)
        #expect(ans.type == "call.answer")
        #expect(try savedState(store).outbox.isEmpty)
        let b = try StrictJson.parseObject(ans.body)
        #expect(try b.string("call_id") == callId)
        let enc = try b.base64("enc", 1120)
        #expect(Ed25519.verify(secrets.identity.publicKey, label: CallWire.labelShare, CallWire.shareMessage(role: "answer", callId: callId, media: "", share: enc), try b.base64("enc_sig", 64)))
        let n = try CallMedia.chosenIn(b.string("sdp"), offered: [1])
        let kCall = try CallWire.accept(offerKey: offerKey, enc: enc, callId: callId)
        #expect(try keys.send() == CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCallee, callId: callId))
        #expect(try keys.receive() == CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId))

        // Candidates: batched by the caller of callIce, at most 16 a message, ephemeral.
        try await api.callIce(callId, [CallCandidate("candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host", sdpMid: "0", sdpMLineIndex: 0), CallCandidate("candidate:2 1 udp 1 192.0.2.2 50001 typ host")])
        let ice = try v.open(try await relay.nextDeposit().payload)
        #expect(ice.type == "call.ice")
        #expect(ice.exp != nil)
        #expect(String(bytes: ice.body, encoding: .utf8) == #"{"call_id":"\#(callId)","candidates":[{"candidate":"candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host","sdp_mid":"0","sdp_mline_index":0},{"candidate":"candidate:2 1 udp 1 192.0.2.2 50001 typ host"}]}"#)
        await #expect(throws: CallMessageError.self) { try await api.callIce(callId, []) }
        await #expect(throws: CallMessageError.self) { try await api.callIce(callId, [CallCandidate](repeating: CallCandidate("c"), count: 17)) }
        await #expect(throws: CallMessageError.self) { try await api.callIce(callId, [CallCandidate(String(repeating: "c", count: 1025))]) }
        await #expect(throws: CallMessageError.self) { try await api.callIce(callId, [CallCandidate("c", sdpMid: String(repeating: "m", count: 65))]) }
        await #expect(throws: CallMessageError.self) { try await api.callIce(callId, [CallCandidate("c", sdpMLineIndex: 1024)]) }
        await #expect(throws: CallMessageError.self) { try await api.callIce(callId, [CallCandidate("c", sdpMLineIndex: -1)]) }
        #expect("\(CallCandidate("candidate:1 1 udp 1 192.0.2.1 50000 typ host"))" == "CallCandidate([redacted])")

        // The other side's candidates and the end of the call, as events: one flow, in the vault's order.
        let got = Task { () -> [CallEvent] in
            var out: [CallEvent] = []
            for await e in api.callEvents() {
                out.append(e)
                if out.count == 4 { break }
            }
            return out
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await d.handle(try v.seal("call.ice", #"{"call_id":"\#(callId)","candidates":[{"candidate":"candidate:9","sdp_mid":"0","sdp_mline_index":0},{"nope":1},{"candidate":"candidate:10","sdp_mid":5}]}"#))
        try await d.handle(try v.seal("message.new", #"{"connection_id":"c1","message_id":"m9","direction":"in","text":"not a call","sent_at":"x"}"#))
        try await d.handle(try v.seal("call.ringing", #"{"call_id":"\#(callId)"}"#))
        try await d.handle(try v.seal("call.ice", #"{"call_id":"\#(callId)","candidates":[]}"#))
        try await d.handle(try v.seal("call.end", #"{"call_id":"\#(callId)","reason":"hangup"}"#))
        try await d.handle(try v.seal("call.offer", try offer()))
        let events = await got.value
        #expect(events.count == 4)
        guard events.count == 4 else { return }
        if case .ice(let i) = events[0] { #expect(i == CallIce(callId: callId, candidates: [CallCandidate("candidate:9", sdpMid: "0", sdpMLineIndex: 0)])) } else { Issue.record("expected call.ice first") }
        if case .ringing(let id) = events[1] { #expect(id == callId) } else { Issue.record("expected call.ringing") }
        if case .ended(let e) = events[2] { #expect(e == CallEnded(callId: callId, reason: "hangup")) } else { Issue.record("expected call.end") }
        if case .offer = events[3] { #expect(events[3].connectionId == "conn-1") } else { Issue.record("expected call.offer") }
    }

    /// Call signalling is deposited once: a relay failure reaches the caller and nothing is kept for a later flush (a
    /// `call.start` sent again after a restart would ring for a call nobody is in). `call.end` is durable, so a hang-up
    /// still frees the vault. A `call.start` without an answer is deposited once, not three times.
    @Test func callSignallingIsNeverSentAgainButAHangUpIs() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let api = VaultApi(device: d)
        let callId = Ulid.new()
        let sdp = Self.callSdp
        relay.refuseStatus = 503
        relay.refuseDeposits = "unavailable"
        await #expect(throws: RelayError.self) { try await api.callRinging(callId) }
        await #expect(throws: RelayError.self) { _ = try await api.callStart("conn-1", pinnedFingerprint: Self.callFp, sdp: sdp) }
        await #expect(throws: RelayError.self) { _ = try await api.callIce(callId, [CallCandidate("c")]) }
        // The relay's answers were lost, as far as the app knows: `call.start` is not kept, but a hang-up for its call is.
        #expect(try savedState(store).outbox.map(\.type) == ["call.end"])
        await #expect(throws: RelayError.self) { try await api.callEnd(callId, reason: CallReason.hangup) }
        #expect(try savedState(store).outbox.count == 2)
        relay.refuseDeposits = nil
        await d.flushOutbox()
        let ends = [try v.open(try await relay.nextDeposit().payload), try v.open(try await relay.nextDeposit().payload)]
        #expect(ends.allSatisfy { $0.type == "call.end" && $0.exp == nil })
        #expect(String(bytes: ends[1].body, encoding: .utf8) == #"{"call_id":"\#(callId)","reason":"hangup"}"#)
        #expect(await relay.noDeposit(within: 0.3), "only the hang-ups were sent again")
        // A reason that is none of §10.10's is refused, whatever else is true.
        await #expect(throws: CallMessageError.self) { try await api.callEnd(callId, reason: "bored") }
        for reason in CallReason.all.sorted() {
            try await api.callEnd(callId, reason: reason)
            let e = try v.open(try await relay.nextDeposit().payload)
            #expect(String(bytes: e.body, encoding: .utf8) == #"{"call_id":"\#(callId)","reason":"\#(reason)"}"#)
        }

        // No answer: one deposit.
        await #expect(throws: VaultStateError.self) { _ = try await d.requestOnce("call.start", timeout: 0.3) }
        #expect(try v.open(try await relay.nextDeposit().payload).type == "call.start")
        #expect(await relay.noDeposit(within: 0.3))

        // `callStart` without an answer: the call may exist in the vault, so its hang-up follows.
        await #expect(throws: VaultStateError.self) { _ = try await api.callStart("conn-1", pinnedFingerprint: Self.callFp, sdp: sdp, timeout: 0.3) }
        let started = try v.open(try await relay.nextDeposit().payload)
        #expect(started.type == "call.start")
        let after = try v.open(try await relay.nextDeposit().payload)
        #expect(after.type == "call.end")
        #expect(String(bytes: after.body, encoding: .utf8) == #"{"call_id":"\#(try StrictJson.parseObject(started.body).string("call_id"))","reason":"hangup"}"#)

        // call.list, and the answer of a vault release without calls.
        let list = Task { try await api.callList(limit: 10) }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"limit":10}"#)
        try await d.handle(try v.seal("call.list", #"{"calls":[{"call_id":"\#(callId)","connection_id":"conn-1","direction":"in","media":"audio","state":"ended","reason":"timeout","started_at":"2026-10-12T10:00:00.000Z","ended_at":"2026-10-12T10:00:45.000Z"},{"call_id":"no-direction"}]}"#, re: req.id, status: Inner.statusOK))
        #expect(try await list.value == CallList(calls: [CallRecord(callId: callId, connectionId: "conn-1", direction: "in", media: "audio", state: "ended", reason: "timeout", startedAt: "2026-10-12T10:00:00.000Z", endedAt: "2026-10-12T10:00:45.000Z")], skipped: 1))
        let unsupported = Task { try await api.callList() }
        let req2 = try v.open(try await relay.nextDeposit().payload)
        #expect(String(bytes: req2.body, encoding: .utf8) == #"{"limit":50}"#)
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(Inner(id: Ulid.new(), type: req2.type, ts: Date(), re: req2.id, status: Inner.statusError, error: InnerError("unsupported_type")))))
        do {
            _ = try await unsupported.value
            Issue.record("expected unsupported_type")
        } catch let e as VaultOpError {
            #expect(e.code == "unsupported_type")
        }
    }

    /// A hand-made `call.offer` or `call.answer` body that is not an object, lacks members, or has the wrong shapes never
    /// rings or opens a call, and never crashes.
    @Test func malformedCallBodiesAreRefused() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        for body in ["{}", #"{"call_id":"x"}"#, #"{"call_id":"01JB2Z6V9K3M4N5P6Q7R8S9T50"}"#, #"{"call_id":"01JB2Z6V9K3M4N5P6Q7R8S9T50","media":"audio"}"#, #"{"call_id":"01JB2Z6V9K3M4N5P6Q7R8S9T50","media":"audio","sdp":"","ek":"AA=="}"#] {
            try await d.handle(try v.seal("call.offer", body))
            let ev = try await d.awaitEvent("call.offer")
            #expect(throws: CallMessageError.self, "\(body)") { try api.callIncoming(ev, pinnedFingerprint: peer.pinned) }
        }
        let call = OutgoingCall(
            callId: "01JB2Z6V9K3M4N5P6Q7R8S9T50", connectionId: "c", media: "audio", exp: Date().addingTimeInterval(45),
            ice: CallWire.IceConfig(callId: "01JB2Z6V9K3M4N5P6Q7R8S9T50", exp: Date().addingTimeInterval(45), servers: []), offered: [1], pinnedFingerprint: peer.pinned,
            offerKey: try CallWire.newOfferKey()
        )
        for body in ["{}", #"{"call_id":"01JB2Z6V9K3M4N5P6Q7R8S9T50","sdp":"x","enc":"!!"}"#] {
            try await d.handle(try v.seal("call.answer", body))
            let ev = try await d.awaitEvent("call.answer")
            #expect(throws: CallMessageError.self, "\(body)") { try api.callAccept(call, event: ev) }
        }
        call.destroy()
    }
}

// swiftlint:enable line_length function_body_length
