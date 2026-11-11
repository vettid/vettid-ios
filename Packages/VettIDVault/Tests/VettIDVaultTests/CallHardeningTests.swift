import Foundation
import Testing
import VettIDCrypto
import VettIDRelay
import VettIDTesting
@testable import VettIDVault

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// Hardening of the call signalling (VAULT-MESSAGING §10.10): what the media stack is handed, which connection an answer
/// may come from, one answer to an offer, and the limits of what the vault sends.
extension VaultDeviceTests {
    struct PlacedCall {
        let call: OutgoingCall
        let ek: [UInt8]
        let callId: String
    }

    static let ssrcLines = "a=ssrc:1234 cname:x\r\na=ssrc-group:FID 1234 5678\r\na=ssrc:5678 msid:a b\r\n"

    /// A `call.offer` body from [peer] for [callId], vouched as the connection's own vault would.
    func offerBody(_ v: FakeVault, _ peer: CallPeer, callId: String, ek: [UInt8], sdp: String) throws -> String {
        let exp = try millis(Date().addingTimeInterval(45))
        let base = JsonBuilder().string("call_id", callId).string("connection_id", "conn-1").string("media", "audio")
            .string("sdp", try CallMedia.sdpWithOffer(sdp, offered: [1])).base64("ek", ek).string("exp", ts(exp))
        let m = CallWire.shareMessage(role: "offer", callId: callId, media: "audio", share: ek)
        return try peer.vouched(try iceBody(base, v, callId), m).build()
    }

    /// Places a call to a connection pinned as [pinned]; the vault accepts it. Returns the call, its `ek` and id.
    func placeCall(_ api: VaultApi, _ d: VaultDevice, _ v: FakeVault, pinned: String) async throws -> PlacedCall {
        let starting = Task { try await api.callStart("conn-1", pinnedFingerprint: pinned, sdp: Self.callSdp) }
        let req = try v.open(try await relay.nextDeposit().payload)
        let b = try StrictJson.parseObject(req.body)
        let callId = try b.string("call_id")
        let exp = try millis(Date().addingTimeInterval(45))
        try await d.handle(try v.seal("call.start", try iceBody(JsonBuilder().string("call_id", callId).string("exp", ts(exp)), v, callId).build(), re: req.id, status: Inner.statusOK))
        return PlacedCall(call: try await starting.value, ek: try b.base64("ek", 1216), callId: callId)
    }

    /// The SDP a device hands to its media stack carries no `a=ssrc` or `a=ssrc-group` line of the other side: a signalled
    /// SSRC would leave every other SSRC of the section outside the frame decryption.
    @Test func theOtherSidesSdpReachesTheMediaStackWithoutSsrcLines() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        let dirty = Self.callSdp + Self.ssrcLines

        // An offer with injected lines.
        let callId = Ulid.new()
        let offerKey = try CallWire.newOfferKey()
        try await d.handle(try v.seal("call.offer", try offerBody(v, peer, callId: callId, ek: offerKey.publicKey.bytes, sdp: dirty)))
        let incoming = try api.callIncoming(try await d.awaitEvent("call.offer"), pinnedFingerprint: peer.pinned)
        #expect(incoming.sdp == Self.callSdp)
        #expect(!incoming.sdp.contains("a=ssrc"))

        // An answer with injected lines.
        let placed = try await placeCall(api, d, v, pinned: peer.pinned)
        let (call, id) = (placed.call, placed.callId)
        let a = try CallWire.answer(ek: placed.ek, callId: id)
        let m = CallWire.shareMessage(role: "answer", callId: id, media: "", share: a.enc)
        let body = try peer.vouched(JsonBuilder().string("call_id", id).string("sdp", CallMedia.sdpWithChoice(dirty, chosen: .aes128Gcm)).base64("enc", a.enc), m).build()
        try await d.handle(try v.seal("call.answer", body))
        let accepted = try api.callAccept(call, event: try await d.awaitEvent("call.answer"))
        #expect(accepted.sdp == Self.callSdp)
        #expect(!accepted.sdp.contains("a=ssrc"))
        accepted.keys.destroy()
    }

    /// The answer must come from the connection that was called: a fully valid answer from another connection (its own
    /// device, its own vault, its own `peer_ik`) is refused, and the call's key is not spent on it.
    @Test func anAnswerIsBoundToTheConnectionThatWasCalled() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        let other = try CallPeer()
        let placed = try await placeCall(api, d, v, pinned: peer.pinned)
        let (call, id) = (placed.call, placed.callId)
        #expect(call.pinnedFingerprint == peer.pinned)
        let a = try CallWire.answer(ek: placed.ek, callId: id)
        let m = CallWire.shareMessage(role: "answer", callId: id, media: "", share: a.enc)
        func answer(by who: CallPeer) throws -> String {
            try who.vouched(JsonBuilder().string("call_id", id).string("sdp", CallMedia.sdpWithChoice(Self.callSdp, chosen: .aes128Gcm)).base64("enc", a.enc), m).build()
        }
        try await d.handle(try v.seal("call.answer", try answer(by: other)))
        let fromOther = try await d.awaitEvent("call.answer")
        #expect(throws: CallMessageError.self) { try api.callAccept(call, event: fromOther) }
        // Not spent: the connection that was called can still answer.
        try await d.handle(try v.seal("call.answer", try answer(by: peer)))
        let accepted = try api.callAccept(call, event: try await d.awaitEvent("call.answer"))
        accepted.keys.destroy()

        // A call is placed to a pinned connection, or not at all.
        await #expect(throws: CallMessageError.self) { _ = try await api.callStart("conn-1", pinnedFingerprint: "", sdp: Self.callSdp) }
        await #expect(throws: CallMessageError.self) { _ = try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: Self.callSdp, media: "screen") }
        await #expect(throws: CallMessageError.self) { _ = try await api.callStart("conn-1", pinnedFingerprint: peer.pinned, sdp: Self.callSdp, media: "") }
        #expect(await relay.noDeposit(within: 0.3), "nothing left the phone")
    }

    /// An offer is answered once: the second `callAnswer` fails and sends nothing.
    @Test func anOfferIsAnsweredOnce() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let peer = try CallPeer()
        let callId = Ulid.new()
        let offerKey = try CallWire.newOfferKey()
        try await d.handle(try v.seal("call.offer", try offerBody(v, peer, callId: callId, ek: offerKey.publicKey.bytes, sdp: Self.callSdp)))
        let call = try api.callIncoming(try await d.awaitEvent("call.offer"), pinnedFingerprint: peer.pinned)
        // A refused answer (bad SDP) sends nothing and does not use the offer up.
        await #expect(throws: CallMessageError.self) { _ = try await api.callAnswer(call, sdp: Self.callSdp + "m=video 9 X 96\r\n") }
        #expect(await relay.noDeposit(within: 0.3))
        let keys = try await api.callAnswer(call, sdp: Self.callSdp)
        #expect(try v.open(try await relay.nextDeposit().payload).type == "call.answer")
        await #expect(throws: CallMessageError.self) { _ = try await api.callAnswer(call, sdp: Self.callSdp) }
        #expect(await relay.noDeposit(within: 0.3), "the second answer sent nothing")
        keys.destroy()
    }

    /// The limits of a received `call.ice` (§10.10), in bytes: a long candidate, a long `sdp_mid` and an out of range
    /// `sdp_mline_index` leave that candidate out; more than 16 candidates is refused whole, not cut to 16.
    @Test func aReceivedCallIceIsHeldToTheLimits() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let callId = Ulid.new()
        let got = Task { () -> [CallEvent] in
            var out: [CallEvent] = []
            for await e in api.callEvents() {
                out.append(e)
                if out.count == 3 { break }
            }
            return out
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        func cand(_ c: String, mid: String? = nil, index: Int? = nil) -> String {
            let b = JsonBuilder().string("candidate", c)
            if let mid { b.string("sdp_mid", mid) }
            if let index { b.raw("sdp_mline_index", String(index)) }
            return b.build()
        }
        // 600 "é" are 600 UTF-16 units but 1,200 bytes.
        let long = String(repeating: "é", count: 600)
        let bad = [cand(long), cand("c", mid: String(repeating: "m", count: 65)), cand("c", index: 1024), cand("c", index: -1), cand("ok", mid: String(repeating: "m", count: 64), index: 1023)]
        try await d.handle(try v.seal("call.ice", #"{"call_id":"\#(callId)","candidates":"# + JsonBuilder.array(bad) + "}"))
        try await d.handle(try v.seal("call.ice", #"{"call_id":"\#(callId)","candidates":"# + JsonBuilder.array((0..<17).map { cand("c\($0)") }) + "}"))
        try await d.handle(try v.seal("call.ice", #"{"call_id":"\#(callId)","candidates":"# + JsonBuilder.array((0..<16).map { cand("c\($0)") }) + "}"))
        try await d.handle(try v.seal("call.ringing", #"{"call_id":"\#(callId)"}"#))
        let events = await got.value
        #expect(events.count == 3)
        guard events.count == 3 else { return }
        if case .ice(let i) = events[0] {
            #expect(i.candidates == [CallCandidate("ok", sdpMid: String(repeating: "m", count: 64), sdpMLineIndex: 1023)])
        } else { Issue.record("expected the one candidate that is within the limits") }
        if case .ice(let i) = events[1] { #expect(i.candidates.count == 16, "the 17-candidate message was refused whole") } else { Issue.record("expected the 16-candidate message") }
        if case .ringing = events[2] {} else { Issue.record("expected call.ringing: the 17-candidate message must give no event") }
    }

    /// `call.list`: an entry with an unknown `direction` or `state`, or a timestamp that is none, cannot be read and is
    /// counted as skipped; a limit above 200 is refused before anything is sent.
    @Test func callListSkipsEntriesItCannotReadAndRefusesALimitAbove200() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        await #expect(throws: CallMessageError.self) { _ = try await api.callList(limit: 201) }
        #expect(await relay.noDeposit(within: 0.3))
        func entry(_ id: String, dir: String = "in", state: String = "ended", started: String = "2026-10-12T10:00:00.000Z", extra: String = "") -> String {
            #"{"call_id":"\#(id)","connection_id":"k","direction":"\#(dir)","media":"audio","state":"\#(state)","started_at":"\#(started)"\#(extra)}"#
        }
        let entries = [entry("good"), entry("d", dir: "sideways"), entry("s", state: "weird"), entry("t", started: "yesterday"),
                       entry("a", extra: #","answered_at":"soon""#), entry("e", extra: #","ended_at":5"#), entry("ok2", dir: "out", state: "active", extra: #","answered_at":"2026-10-12T10:00:05.000Z""#)]
        let list = Task { try await api.callList(limit: 200) }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"limit":200}"#)
        try await d.handle(try v.seal("call.list", #"{"calls":["# + entries.joined(separator: ",") + "]}", re: req.id, status: Inner.statusOK))
        let got = try await list.value
        #expect(got.calls.map(\.callId) == ["good", "ok2"])
        #expect(got.skipped == 5)
    }
}

// swiftlint:enable line_length
