import Foundation
import Testing
import VettIDCrypto
@testable import VettIDVault

/// What a call keeps secret stays secret: `k_call` is wiped in the owner's buffer, and no description, debug description
/// or `dump` of a call type shows a key, a credential, an SDP or a candidate.
@Suite struct CallSecretsTests {
    let callId = "01JB2Z6V9K3M4N5P6Q7R8S9T50"

    /// The wipe runs on the buffer the caller owns, not on a copy of it (arrays copy on write: a wipe of a copy leaves the
    /// key where it was).
    @Test func kCallIsWipedInTheCallersOwnBuffer() throws {
        var k = (0..<32).map { UInt8($0 + 1) }
        let before = (0..<32).map { UInt8($0 + 1) } // its own buffer, not shared with k
        let base = k.withUnsafeBufferPointer { $0.baseAddress }
        let n = try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1])
        let keys = try CallKeys.derive(&k, n, callId: callId, caller: true)
        #expect(k.allSatisfy { $0 == 0 }, "the caller's array is zero")
        #expect(k.withUnsafeBufferPointer { $0.baseAddress } == base, "wiped in place")
        let expected = try CallMedia.directionKey(kCall: before, negotiated: n, direction: CallMedia.directionCaller, callId: callId)
        #expect(try keys.send() == expected, "and the keys were derived from the key before it was wiped")
    }

    private func reveal(_ x: Any) -> String {
        var d = ""
        dump(x, to: &d)
        return "\(x)\n\(String(describing: x))\n\(String(reflecting: x))\n\(d)"
    }

    @Test func noCallTypeShowsASecret() throws {
        let key = (0..<32).map { UInt8(0xA0 + $0 % 16) }
        let keys = CallKeys(suite: .aes128Gcm, send: key, receive: key.reversed())
        let sdp = "v=0\r\na=ice-pwd:ICEPWDSECRET\r\na=fingerprint:sha-256 DTLSFPSECRET\r\nm=audio 9 X 111\r\na=rtpmap:111 opus/48000/2\r\n"
        let ice = CallWire.IceConfig(
            callId: callId, exp: Date(timeIntervalSince1970: 1_800_000_000),
            servers: [CallWire.IceServer(urls: ["turn:turn.example.org:3478"], username: "USERSECRET", credential: "CREDSECRET")]
        )
        let candidate = CallCandidate("candidate:1 1 udp 1 192.0.2.77 50000 typ host", sdpMid: "MIDSECRET", sdpMLineIndex: 0)
        let negotiated = try CallMedia.Negotiated(chosen: .aes128Gcm, offered: [1])
        let incoming = IncomingCall(
            callId: callId, connectionId: "conn-1", media: "audio", sdp: sdp, exp: Date(), ringFor: 45, ice: ice,
            negotiated: negotiated, ek: [UInt8](repeating: 0x5B, count: 8)
        )
        let outgoing = OutgoingCall(
            callId: callId, connectionId: "conn-1", media: "audio", exp: Date(), ice: ice, offered: [1], pinnedFingerprint: "0000",
            offerKey: try CallWire.newOfferKey()
        )
        let accepted = AcceptedCall(callId: callId, sdp: sdp, keys: keys)
        let message = VaultMessage(inner: Inner(id: Ulid.new(), type: "call.offer", ts: Date(), body: Array(sdp.utf8)))
        let all: [Any] = [
            keys, incoming, outgoing, accepted, ice, ice.servers[0], candidate, CallIce(callId: callId, candidates: [candidate]),
            CallEvent.offer(message), CallEvent.answer(message), CallEvent.ice(CallIce(callId: callId, candidates: [candidate])),
        ]
        let secrets = ["ICEPWDSECRET", "DTLSFPSECRET", "USERSECRET", "CREDSECRET", "192.0.2.77", "MIDSECRET",
            "sendKey", "receiveKey", "offerKey", "kCall"]
        for x in all {
            var dumped = ""
            dump(x, to: &dumped)
            #expect(dumped.split(separator: "\n").count == 1, "\(type(of: x)) has no children for a mirror to show: \(dumped.prefix(80))")
            let text = reveal(x)
            for s in secrets { #expect(!text.contains(s), "\(type(of: x)) shows \(s)") }
        }
        outgoing.destroy()
    }
}

extension VaultDeviceTests {
    /// `call.list`: a limit below 1 is refused before anything is sent; `calls` that is not an array is a failed decode; a
    /// missing `calls` is an empty history.
    @Test func callListRefusesABadLimitAndReadsOnlyAnArray() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        await #expect(throws: CallMessageError.self) { _ = try await api.callList(limit: 0) }
        await #expect(throws: CallMessageError.self) { _ = try await api.callList(limit: -5) }
        #expect(await relay.noDeposit(within: 0.3), "nothing was sent")
        for (body, empty) in [(#"{"calls":"x"}"#, false), (#"{"calls":{}}"#, false), ("{}", true), (#"{"calls":[]}"#, true)] {
            let list = Task { try await api.callList(limit: 5) }
            let req = try v.open(try await relay.nextDeposit().payload)
            try await d.handle(try v.seal("call.list", body, re: req.id, status: Inner.statusOK))
            if empty {
                #expect(try await list.value == CallList(calls: [], skipped: 0), "\(body)")
            } else {
                await #expect(throws: CallMessageError.self, "\(body)") { _ = try await list.value }
            }
        }
        // A clean list reports nothing skipped; one bad entry among good ones is counted, never silent.
        let good = #"{"call_id":"c1","connection_id":"k","direction":"in","media":"audio","#
            + #""state":"ended","started_at":"2026-10-12T10:00:00.000Z"}"#
        for (entries, skipped) in [([good], 0), ([good, #"{"call_id":"c2"}"#], 1), ([#"{"x":1}"#, "5", good], 2)] {
            let list = Task { try await api.callList(limit: 5) }
            let req = try v.open(try await relay.nextDeposit().payload)
            let body = #"{"calls":["# + entries.joined(separator: ",") + "]}"
            try await d.handle(try v.seal("call.list", body, re: req.id, status: Inner.statusOK))
            let got = try await list.value
            #expect(got.calls.map(\.callId) == ["c1"] && got.skipped == skipped, "\(entries)")
        }
    }
}
