import Foundation
import Testing
@testable import VettIDCrypto

// Fixtures are long literals.
// swiftlint:disable line_length

/// The suite registry, the negotiation through the SDP, the direction keys and the frame format (CALLS-PLAN §12).
/// Mirrors vettid-android `CallMediaTest`, test by test.
@Suite struct CallMediaTests {
    let offer = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n"
    let opus = "a=rtpmap:111 opus/48000/2\r\n"
    let s1 = MediaSuite.aes128Gcm
    let s2 = MediaSuite.aes256Gcm
    let kCall = (0..<32).map { UInt8(truncatingIfNeeded: $0 * 7) }
    let callId = "01JB2Z6V9K3M4N5P6Q7R8S9T50"

    /// One device of a call: what it ends up with.
    struct Keys {
        let suite: MediaSuite
        let send: [UInt8]
        let receive: [UInt8]
    }

    func keys(_ n: CallMedia.Negotiated, caller: Bool) throws -> Keys {
        let a = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId)
        let b = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCallee, callId: callId)
        return caller ? Keys(suite: n.chosen, send: a, receive: b) : Keys(suite: n.chosen, send: b, receive: a)
    }

    /// A whole negotiation through the SDP, as the two devices run it. [onOffer] and [onAnswer] are someone on the
    /// path changing the SDP. Returns the caller's and the answerer's keys.
    func negotiate(
        _ caller: [MediaSuite], _ answerer: [MediaSuite],
        onOffer: (String) -> String = { $0 }, onAnswer: (String) -> String = { $0 }
    ) throws -> (Keys, Keys) {
        let sent = try CallMedia.offerOf(caller)
        let offerSdp = onOffer(try CallMedia.sdpWithOffer(offer, offered: sent))
        let chosen = try CallMedia.choose(offered: CallMedia.offeredIn(offerSdp), supported: answerer)
        let answerSdp = onAnswer(CallMedia.sdpWithChoice(offer, chosen: chosen.chosen))
        // The caller checks the answer against the list it sent, never against one it reads back.
        let atCaller = try CallMedia.chosenIn(answerSdp, offered: sent)
        return (try keys(atCaller, caller: true), try keys(chosen, caller: false))
    }

    func agree(_ k: (Keys, Keys)) -> Bool {
        k.0.suite == k.1.suite && k.0.send == k.1.receive && k.0.receive == k.1.send
    }

    @Test func theRegistryIsClosedAndItsNumbersAreFixed() throws {
        #expect(MediaSuite.allCases.map(\.id) == [1, 2])
        #expect(MediaSuite.byId(1) == s1)
        #expect(MediaSuite.byId(2) == s2)
        #expect(MediaSuite.byId(3) == nil)
        #expect(MediaSuite.byId(0) == nil)
        #expect(s1.frameKeySize == 16)
        #expect(s2.frameKeySize == 32)
        #expect(MediaSuite.preference == [s2, s1])
        #expect(MediaSuite.default == [s1], "suite 1 by default: what every engine can do and all form 1 allows")
        #expect(MediaSuite.allCases.allSatisfy { !$0.pqDtlsRequired })
        #expect(MediaSuite.allCases.allSatisfy { $0.mediaLabel == "vettid/vms/2/call-media" && $0.frameLabel == "vettid/vms/2/call-frame" })
        #expect(try CallMedia.offerOf([s1, s2]) == [2, 1])
        #expect(try CallMedia.offerOf([s2, s1]) == [2, 1], "the registry's order, not the caller's")
        #expect(try CallMedia.offerOf([s1]) == [1])
        expectCrypto(.suite) { _ = try CallMedia.offerOf([]) }
    }

    /// VAULT-MESSAGING §10.10 "Call forms", rules 1 and 3: no second suite is offered or chosen while any `call.start`
    /// carries form 1.
    @Test func formOneOffersAndChoosesSuiteOneOnly() throws {
        #expect(MediaSuite.formOne([s2, s1]) == [s1])
        #expect(MediaSuite.formOne(MediaSuite.allCases) == [s1])
        #expect(MediaSuite.formOne([s2]).isEmpty)
        #expect(try CallMedia.offerOf(MediaSuite.formOne([s2, s1])) == [1])
        expectCrypto(.suite) { _ = try CallMedia.offerOf(MediaSuite.formOne([s2])) }
        #expect(try CallMedia.choose(offered: [2, 1], supported: MediaSuite.formOne([s2, s1])) == (try CallMedia.Negotiated(chosen: s1, offered: [2, 1])))
        expectCrypto(.suite) { _ = try CallMedia.choose(offered: [2], supported: MediaSuite.formOne([s2, s1])) }
    }

    @Test func aSuiteOneDeviceAndASuiteOneAndTwoDeviceAgreeOnOne() throws {
        // Either may be the caller.
        for k in [try negotiate([s1], [s1, s2]), try negotiate([s1, s2], [s1])] {
            #expect(k.0.suite == s1)
            #expect(agree(k))
        }
    }

    @Test func twoSuiteOneAndTwoDevicesAgreeOnTwo() throws {
        let k = try negotiate([s1, s2], [s1, s2])
        #expect(k.0.suite == s2)
        #expect(agree(k))
        // Not the keys of a suite 1 call with the same call key.
        let one = try negotiate([s1], [s1])
        #expect(k.0.send != one.0.send)
        #expect(try CallFrames.frameKey(k.0.send, suite: s2).count == 32)
        #expect(
            Bytes.hex(try CallFrames.frameKey(try Bytes.unhex("129e7ea015351c448613b72d821141780fbc2681c9562f2b47894d999c609617"), suite: s2))
                == "e2637ed9e4ab88d26b3f34869104e58d355e1eb7b6c5b7d3aea521bda4fd83da"
        )
    }

    @Test func noOneOnThePathCanMoveACallToAWeakerSuite() throws {
        let both = [s1, s2]
        // The offer's list cut down to suite 1: the answerer picks 1 for the list "1", the caller knows it sent "2 1".
        // Both believe suite 1; the keys differ, so nothing decrypts and the call ends.
        let cut = try negotiate(both, both, onOffer: { $0.replacingOccurrences(of: "a=vettid-media-suites:2 1", with: "a=vettid-media-suites:1") })
        #expect(cut.0.suite == s1 && cut.1.suite == s1)
        #expect(!agree(cut))
        // The list reordered: the same.
        let reordered = try negotiate(both, both, onOffer: { $0.replacingOccurrences(of: "a=vettid-media-suites:2 1", with: "a=vettid-media-suites:1 2") })
        #expect(!agree(reordered))
        // The answer's choice rewritten from 2 to 1: the answerer encrypts for suite 2, the caller derives for 1.
        let rewritten = try negotiate(both, both, onAnswer: { $0.replacingOccurrences(of: "a=vettid-media-suite:2", with: "a=vettid-media-suite:1") })
        #expect(rewritten.0.suite == s1 && rewritten.1.suite == s2)
        #expect(!agree(rewritten))
        // A choice the caller never offered, a number nobody knows, or no attribute at all: refused at once.
        expectCrypto(.suite, "not offered") {
            _ = try negotiate([s1], both, onAnswer: { $0.replacingOccurrences(of: "a=vettid-media-suite:1", with: "a=vettid-media-suite:2") })
        }
        expectCrypto(.suite, "unknown") {
            _ = try negotiate(both, both, onAnswer: { $0.replacingOccurrences(of: "a=vettid-media-suite:2", with: "a=vettid-media-suite:9") })
        }
        expectCrypto(.suite, "no choice") { _ = try negotiate(both, both, onAnswer: { CallMedia.sdpWithout($0) }) }
        expectCrypto(.suite, "no offer") { _ = try negotiate(both, both, onOffer: { CallMedia.sdpWithout($0) }) }
    }

    @Test func unknownNumbersInAnOfferAreSkippedAndStayInTheBinding() throws {
        // A newer caller offers a suite 7 this build does not know, then 1.
        let n = try CallMedia.choose(offered: [7, 1], supported: [s1, s2])
        #expect(n == (try CallMedia.Negotiated(chosen: s1, offered: [7, 1])))
        let withSeven = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId)
        let without = try CallMedia.directionKey(
            kCall: kCall, negotiated: CallMedia.Negotiated(chosen: s1, offered: [1]), direction: CallMedia.directionCaller, callId: callId
        )
        #expect(withSeven != without)
        // Nothing in common: no call.
        expectCrypto(.suite) { _ = try CallMedia.choose(offered: [7], supported: [s1, s2]) }
        expectCrypto(.suite) { _ = try CallMedia.choose(offered: [2], supported: [s1]) }
        expectCrypto(.suite) { _ = try CallMedia.Negotiated(chosen: s2, offered: [1]) }
    }

    @Test func theOfferCarriesTheListAsASessionAttribute() throws {
        let sdp = try CallMedia.sdpWithOffer(offer, offered: [1])
        #expect(
            sdp == "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\na=vettid-media-suites:1\r\n"
                + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n"
        )
        #expect(try CallMedia.offeredIn(sdp) == [1])
        #expect(try CallMedia.offeredIn(CallMedia.sdpWithOffer(offer, offered: [2, 1])) == [2, 1])
        #expect(CallMedia.sdpWithout(sdp) == offer)
        #expect(CallMedia.sdpWithout(CallMedia.sdpWithChoice(offer, chosen: s1)) == offer)
        #expect(CallMedia.sdpWithout(offer) == offer)
        // Written twice: once.
        #expect(try CallMedia.sdpWithOffer(sdp, offered: [1]) == sdp)
        // Line feeds alone, and no media section.
        #expect(try CallMedia.sdpWithOffer("v=0\ns=-\nm=audio 9 X 0\n", offered: [1]) == "v=0\ns=-\na=vettid-media-suites:1\nm=audio 9 X 0\n")
        #expect(try CallMedia.sdpWithOffer("v=0\ns=-\n", offered: [1]) == "v=0\ns=-\na=vettid-media-suites:1\n")
        // A list that is not one a device may send.
        expectCrypto(.suite) { _ = try CallMedia.sdpWithOffer(offer, offered: []) }
        expectCrypto(.suite) { _ = try CallMedia.sdpWithOffer(offer, offered: [1, 1]) }
    }

    @Test func aMissingRepeatedMisplacedOrMalformedAttributeMeansNoCall() throws {
        let attr = "a=vettid-media-suites"
        let bad = [
            offer,
            offer.replacingOccurrences(of: "a=group", with: "\(attr):1\r\n\(attr):1\r\na=group"),
            offer + "\(attr):1\r\n", // after the media section
            offer.replacingOccurrences(of: "a=group", with: "\(attr):\r\na=group"),
            offer.replacingOccurrences(of: "a=group", with: "\(attr):01\r\na=group"),
            offer.replacingOccurrences(of: "a=group", with: "\(attr):1  2\r\na=group"),
            offer.replacingOccurrences(of: "a=group", with: "\(attr):1 1\r\na=group"),
            offer.replacingOccurrences(of: "a=group", with: "\(attr):0\r\na=group"),
            offer.replacingOccurrences(of: "a=group", with: "\(attr):70000\r\na=group"),
            offer.replacingOccurrences(of: "a=group", with: "\(attr):1 x\r\na=group"),
            offer.replacingOccurrences(of: "a=group", with: "\(attr):1 2 3 4 5 6 7 8 9\r\na=group"),
        ]
        for sdp in bad { expectCrypto(.suite, "\(sdp)") { _ = try CallMedia.offeredIn(sdp) } }
        expectCrypto(.suite) { _ = try CallMedia.chosenIn(offer, offered: [1]) }
        expectCrypto(.suite) { _ = try CallMedia.chosenIn(CallMedia.sdpWithOffer(offer, offered: [1]), offered: [1]) }
    }

    /// Media in a section the frame cryptors do not cover would play unencrypted.
    @Test func onlyOneAudioSectionWithOpusAloneIsACall() throws {
        try CallMedia.requireOneOpusAudioSection(offer + opus)
        try CallMedia.requireOneOpusAudioSection((offer + opus).replacingOccurrences(of: "\r\n", with: "\n"))
        try CallMedia.requireOneOpusAudioSection(offer.replacingOccurrences(of: " 111\r\n", with: " 111 63\r\n") + opus + "a=rtpmap:63 OPUS/48000/2\r\n")
        let bad = [
            "v=0\r\ns=-\r\n", // no media
            offer + opus + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:1\r\n", // a second audio section
            offer + opus + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000\r\n",
            offer + opus + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n",
            (offer + opus).replacingOccurrences(of: "m=audio", with: "m=video"),
            offer, // no rtpmap for its payload type
            offer.replacingOccurrences(of: " 111\r\n", with: " 111 0\r\n") + opus, // Opus and something else
            offer + "a=rtpmap:111 PCMU/8000\r\n",
            "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF\r\n",
        ]
        for sdp in bad { expectCrypto(.protocolViolation, "\(sdp)") { try CallMedia.requireOneOpusAudioSection(sdp) } }
    }

    /// A signalled SSRC would leave every other SSRC of the section outside the frame decryption.
    @Test func theOtherSidesSdpReachesTheStackWithoutSsrcLines() throws {
        let withSsrc = offer + opus + "a=msid:vettid audio0\r\na=ssrc:1234 cname:x\r\na=ssrc:1234 msid:vettid audio0\r\n"
            + "a=ssrc-group:FID 1234 5678\r\na=ssrc:5678 cname:x\r\n"
        #expect(CallMedia.sdpWithoutSsrc(withSsrc) == offer + opus + "a=msid:vettid audio0\r\n")
        #expect(CallMedia.sdpWithoutSsrc(offer + opus) == offer + opus)
        #expect(CallMedia.sdpWithoutSsrc("v=0\na=ssrc:1 cname:x\na=msid:a b\n") == "v=0\na=msid:a b\n")
        // Still one Opus audio section.
        try CallMedia.requireOneOpusAudioSection(CallMedia.sdpWithoutSsrc(withSsrc))
    }

    @Test func keysOfTheWrongSizeOrDirectionAreRefused() throws {
        let n = try CallMedia.Negotiated(chosen: s1, offered: [1])
        expectCrypto(.key, "k_call size") { _ = try CallMedia.directionKey(kCall: [UInt8](repeating: 0, count: 16), negotiated: n, direction: CallMedia.directionCaller, callId: "c") }
        expectCrypto(.key, "k_call size 33") { _ = try CallMedia.directionKey(kCall: [UInt8](repeating: 0, count: 33), negotiated: n, direction: CallMedia.directionCaller, callId: "c") }
        expectCrypto(.key, "direction") { _ = try CallMedia.directionKey(kCall: [UInt8](repeating: 0, count: 32), negotiated: n, direction: "both", callId: "c") }
        expectCrypto(.key, "call id") { _ = try CallMedia.directionKey(kCall: [UInt8](repeating: 0, count: 32), negotiated: n, direction: CallMedia.directionCaller, callId: "") }
    }

    @Test func theTwoDirectionsHaveDifferentKeys() throws {
        let n = try CallMedia.Negotiated(chosen: s1, offered: [1])
        let a = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId)
        let b = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCallee, callId: callId)
        #expect(a != b)
        #expect(a.count == CallMedia.directionKeySize && b.count == CallMedia.directionKeySize)
    }

    @Test func ivIsSsrcTimestampAndTimestampMinusCounter() throws {
        #expect(CallFrames.iv(ssrc: 0x0A0B_0C0D, timestamp: 0x10000, sendCount: 3) == (try Bytes.unhex("0a0b0c0d" + "00010000" + "0000fffd")))
        // The subtraction wraps at 32 bits (a plain `-` would trap).
        #expect(CallFrames.iv(ssrc: 1, timestamp: 0, sendCount: 1) == (try Bytes.unhex("00000001" + "00000000" + "ffffffff")))
        // The counter wraps at 65535, not 65536.
        #expect(CallFrames.iv(ssrc: 1, timestamp: 500, sendCount: 0) == CallFrames.iv(ssrc: 1, timestamp: 500, sendCount: 0xFFFF))
    }

    @Test func aWrongKeyAChangedHeaderOrAPlainFrameDoesNotOpen() throws {
        for suite in MediaSuite.allCases {
            let key = try CallFrames.frameKey([UInt8](repeating: 7, count: 32), suite: suite)
            let frame = (0..<40).map { UInt8($0) }
            let sealed = try CallFrames.seal(frameKey: key, frame: frame, clearBytes: 1, iv: CallFrames.iv(ssrc: 1, timestamp: 2, sendCount: 3))
            #expect(CallFrames.open(frameKey: key, sealed: sealed, clearBytes: 1) == frame)
            #expect(CallFrames.open(frameKey: try CallFrames.frameKey([UInt8](repeating: 8, count: 32), suite: suite), sealed: sealed, clearBytes: 1) == nil)
            var header = sealed
            header[0] &+= 1
            #expect(CallFrames.open(frameKey: key, sealed: header, clearBytes: 1) == nil, "the clear header is authenticated")
            var body = sealed
            body[5] &+= 1
            #expect(CallFrames.open(frameKey: key, sealed: body, clearBytes: 1) == nil, "the ciphertext is authenticated")
            var tag = sealed
            tag[sealed.count - CallFrames.trailerSize - CallFrames.ivSize - 1] ^= 1
            #expect(CallFrames.open(frameKey: key, sealed: tag, clearBytes: 1) == nil, "the tag is checked")
            var iv = sealed
            iv[sealed.count - CallFrames.trailerSize - 1] ^= 1
            #expect(CallFrames.open(frameKey: key, sealed: iv, clearBytes: 1) == nil, "the IV is the nonce")
            var trailer = sealed
            trailer[sealed.count - CallFrames.trailerSize] = 11
            #expect(CallFrames.open(frameKey: key, sealed: trailer, clearBytes: 1) == nil, "the IV length byte")
            #expect(CallFrames.open(frameKey: key, sealed: frame, clearBytes: 1) == nil)
            #expect(CallFrames.open(frameKey: key, sealed: [0], clearBytes: 1) == nil)
            #expect(CallFrames.open(frameKey: key, sealed: Array(sealed.dropLast()), clearBytes: 1) == nil)
            #expect(CallFrames.open(frameKey: key, sealed: sealed, clearBytes: -1) == nil)
            #expect(CallFrames.open(frameKey: key, sealed: sealed, clearBytes: sealed.count) == nil)
        }
    }

    @Test func frameKeysAndSizesOfTheWrongShapeAreRefused() throws {
        let key = try CallFrames.frameKey([UInt8](repeating: 7, count: 32), suite: s1)
        let iv = CallFrames.iv(ssrc: 1, timestamp: 2, sendCount: 3)
        let frame = [UInt8](repeating: 1, count: 20)
        expectCrypto(.key, "key size") { _ = try CallFrames.seal(frameKey: Array(key.dropLast()), frame: frame, clearBytes: 1, iv: iv) }
        expectCrypto(.key, "iv size") { _ = try CallFrames.seal(frameKey: key, frame: frame, clearBytes: 1, iv: Array(iv.dropLast())) }
        expectCrypto(.key, "clear bytes") { _ = try CallFrames.seal(frameKey: key, frame: frame, clearBytes: 21, iv: iv) }
        expectCrypto(.key, "negative clear bytes") { _ = try CallFrames.seal(frameKey: key, frame: frame, clearBytes: -1, iv: iv) }
        // A key of the other suite's size opens nothing sealed under this one.
        let sealed = try CallFrames.seal(frameKey: key, frame: frame, clearBytes: 1, iv: iv, keyIndex: 3)
        #expect(sealed.last == 3, "the key index is carried")
        #expect(CallFrames.open(frameKey: try CallFrames.frameKey([UInt8](repeating: 7, count: 32), suite: s2), sealed: sealed, clearBytes: 1) == nil)
        #expect(CallFrames.open(frameKey: Array(key.dropLast()), sealed: sealed, clearBytes: 1) == nil)
        // A frame with no clear header, and one that is all header, round-trip.
        let none = try CallFrames.seal(frameKey: key, frame: frame, clearBytes: 0, iv: iv)
        #expect(CallFrames.open(frameKey: key, sealed: none, clearBytes: 0) == frame)
        let all = try CallFrames.seal(frameKey: key, frame: frame, clearBytes: frame.count, iv: iv)
        #expect(CallFrames.open(frameKey: key, sealed: all, clearBytes: frame.count) == frame)
        // The same IV under one key for two frames is what the per-direction keys prevent: no direction shares a key.
        let n = try CallMedia.Negotiated(chosen: s1, offered: [1])
        let a = try CallFrames.frameKey(CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId), suite: s1)
        let b = try CallFrames.frameKey(CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCallee, callId: callId), suite: s1)
        #expect(a != b)
    }
}

// swiftlint:enable line_length
