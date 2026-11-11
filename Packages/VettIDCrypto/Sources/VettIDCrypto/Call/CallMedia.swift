import Foundation

// The bytes are UTF-8 split of a `String` at ASCII bytes, so `String(decoding:)` loses nothing here.
// swiftlint:disable optional_data_string_conversion

/// From `k_call` to the keys that encrypt a call's media frames (CALLS-PLAN §12).
///
/// The caller lists the ``MediaSuite``s it can use in its SDP offer, the preferred one first; the answerer names the
/// one it chose in its SDP answer (``sdpWithOffer(_:offered:)``, ``sdpWithChoice(_:chosen:)``); the vaults pass the SDP
/// through unchanged. The SDP is not signed, so the choice and the caller's list are bound into the key derivation
/// instead: two devices that do not agree on both derive different keys, and no media plays. Someone who changes the
/// attribute on the way can therefore end a call but cannot move it to a weaker suite.
///
/// Each direction has its own key (``directionKey(kCall:negotiated:direction:callId:)``), so that the frame cipher's
/// nonce, which holds no randomness, can never repeat under one key across the two senders. Mirrors vettid-android
/// `CallMedia`.
public enum CallMedia {
    /// Session-level SDP attribute of an offer: the caller's suites, decimal, separated by one space.
    public static let attrOffered = "vettid-media-suites"
    /// Session-level SDP attribute of an answer: the one suite the answerer chose.
    public static let attrChosen = "vettid-media-suite"
    /// Frames the calling device sends.
    public static let directionCaller = "caller"
    /// Frames the answering device sends.
    public static let directionCallee = "callee"
    /// A direction key: the key material given to the frame cryptor. 32 bytes for every suite.
    public static let directionKeySize = 32
    public static let maxSuites = 8
    private static let maxSuite = 65535
    private static let rtpmap = "a=rtpmap:"
    /// `m=<media> <port> <proto> <fmt>`: at least one format.
    private static let mLineMin = 4

    /// What the two devices agreed: [chosen] is one of [offered], the caller's list exactly as it was sent (numbers
    /// this build does not know included: they are part of what the keys are bound to).
    public struct Negotiated: Equatable, Sendable {
        public let chosen: MediaSuite
        public let offered: [Int]

        public init(chosen: MediaSuite, offered: [Int]) throws {
            guard CallMedia.validList(offered), offered.contains(chosen.id) else {
                throw CryptoError.suite("media suite not offered")
            }
            self.chosen = chosen
            self.offered = offered
        }
    }

    static func validList(_ l: [Int]) -> Bool {
        (1...maxSuites).contains(l.count) && l.allSatisfy { (1...maxSuite).contains($0) } && Set(l).count == l.count
    }

    /// `HKDF-SHA-256(ikm = k_call, salt = the suite's media label, info = chosen || 0x00 || offered || 0x00 ||
    /// direction || 0x00 || call_id, L = 32)`: `chosen` in decimal, `offered` as decimal numbers joined by one space,
    /// [direction] ``directionCaller`` or ``directionCallee`` (who sends the frames). All ASCII.
    public static func directionKey(kCall: [UInt8], negotiated n: Negotiated, direction: String, callId: String) throws -> [UInt8] {
        guard kCall.count == CallWire.keySize else { throw CryptoError.key("k_call size") }
        guard direction == directionCaller || direction == directionCallee else { throw CryptoError.key("direction") }
        guard !callId.isEmpty else { throw CryptoError.key("call id") }
        let offered = n.offered.map(String.init).joined(separator: " ")
        let info = Array("\(n.chosen.id)\u{0}\(offered)\u{0}\(direction)\u{0}\(callId)".utf8)
        return try Hkdf.derive(ikm: kCall, salt: Array(n.chosen.mediaLabel.utf8), info: info, length: directionKeySize)
    }

    /// The list a caller sends: [supported] in the registry's order of preference.
    public static func offerOf(_ supported: [MediaSuite]) throws -> [Int] {
        let list = MediaSuite.ordered(supported).map(\.id)
        guard !list.isEmpty else { throw CryptoError.suite("no media suite") }
        return list
    }

    /// The answerer's choice: the first of the caller's suites, in the caller's order, that the answerer supports.
    /// Numbers the answerer does not know are skipped. None in common: no call.
    public static func choose(offered: [Int], supported: [MediaSuite]) throws -> Negotiated {
        guard validList(offered) else { throw CryptoError.suite("media suites") }
        guard let chosen = offered.lazy.compactMap({ id in MediaSuite.byId(id).flatMap { supported.contains($0) ? $0 : nil } }).first
        else { throw CryptoError.suite("no common media suite") }
        return try Negotiated(chosen: chosen, offered: offered)
    }

    /// [sdp] with the caller's suite list as a session-level attribute.
    public static func sdpWithOffer(_ sdp: String, offered: [Int]) throws -> String {
        guard validList(offered) else { throw CryptoError.suite("media suites") }
        return withAttribute(sdp, attrOffered, offered.map(String.init).joined(separator: " "))
    }

    /// [sdp] with the answerer's choice as a session-level attribute.
    public static func sdpWithChoice(_ sdp: String, chosen: MediaSuite) -> String {
        withAttribute(sdp, attrChosen, String(chosen.id))
    }

    /// The caller's list in an SDP offer. Missing, repeated or malformed: no call.
    public static func offeredIn(_ sdp: String) throws -> [Int] {
        let list = try attribute(sdp, attrOffered).split(separator: " ", omittingEmptySubsequences: false).map { try number(String($0)) }
        guard validList(list) else { throw CryptoError.suite("media suites") }
        return list
    }

    /// The answerer's choice in an SDP answer, as the caller reads it: it must be a suite the caller [offered] (its own
    /// list, as it sent it, never one read back from anywhere) and one this build knows.
    public static func chosenIn(_ sdp: String, offered: [Int]) throws -> Negotiated {
        let id = try number(attribute(sdp, attrChosen))
        guard offered.contains(id) else { throw CryptoError.suite("media suite not offered") }
        guard let suite = MediaSuite.byId(id) else { throw CryptoError.suite("unknown media suite") }
        return try Negotiated(chosen: suite, offered: offered)
    }

    /// [sdp] without either attribute: what a device hands to its media stack.
    public static func sdpWithout(_ sdp: String) -> String {
        lines(sdp).filter { !starts($0, "a=\(attrOffered):") && !starts($0, "a=\(attrChosen):") }.joined(separator: eol(sdp))
    }

    /// [sdp] without its `a=ssrc:` and `a=ssrc-group:` lines: what a device hands to its media stack as the **other
    /// side's** description. A receiver that is told an SSRC gets its frame decryption for that one stream only, and
    /// the stack then plays RTP that arrives on any other SSRC of the section through a default stream with no frame
    /// decryption at all. Told none, the receiver's frame decryption is the section's default and covers the first
    /// and every later stream.
    public static func sdpWithoutSsrc(_ sdp: String) -> String {
        lines(sdp).filter { !starts($0, "a=ssrc:") && !starts($0, "a=ssrc-group:") }.joined(separator: eol(sdp))
    }

    /// The only shape of SDP a VettID device makes or takes today: **exactly one media section, audio, Opus alone**. A
    /// device prepares frame encryption for one audio section before it applies the other side's SDP; any further
    /// section (a second audio section, video, a data channel) would be media that no frame cryptor covers, so an offer
    /// or an answer with one is refused before it reaches the media stack.
    public static func requireOneOpusAudioSection(_ sdp: String) throws {
        let all = lines(sdp)
        let media = all.filter { starts($0, "m=") }
        guard media.count == 1 else { throw CryptoError.protocolViolation("sdp: \(media.count) media sections") }
        let parts = media[0].dropFirst(2).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= mLineMin, parts[0] == "audio" else { throw CryptoError.protocolViolation("sdp: not one audio section") }
        let payloads = parts.dropFirst(mLineMin - 1)
        var opus = Set<String>()
        for l in all where starts(l, rtpmap) {
            let kv = l.dropFirst(rtpmap.count).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let codec = kv.count > 1 ? String(kv[1]) : ""
            if codec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first?.lowercased() == "opus" {
                opus.insert(String(kv[0]))
            }
        }
        guard payloads.allSatisfy({ opus.contains($0) }) else { throw CryptoError.protocolViolation("sdp: a codec other than Opus") }
    }

    private static func number(_ s: String) throws -> Int {
        let u = Array(s.utf8)
        guard !u.isEmpty, u.count <= 5, u[0] != UInt8(ascii: "0"), u.allSatisfy({ (0x30...0x39).contains($0) }), let n = Int(s) else {
            throw CryptoError.suite("media suite number")
        }
        return n
    }

    private static func starts(_ line: String, _ prefix: String) -> Bool { line.utf8.starts(with: prefix.utf8) }

    /// Lines split at `\r\n` or `\n` (a lone `\r` stays in its line), a trailing empty line included, as the source
    /// text had them. Done on the UTF-8 bytes: Swift's `Character` joins `\r\n`.
    private static func lines(_ sdp: String) -> [String] {
        let b = Array(sdp.utf8)
        var out: [String] = []
        var start = 0
        var i = 0
        while i < b.count {
            if b[i] == 0x0D, i + 1 < b.count, b[i + 1] == 0x0A {
                out.append(String(decoding: b[start..<i], as: UTF8.self))
                i += 2
                start = i
            } else if b[i] == 0x0A {
                out.append(String(decoding: b[start..<i], as: UTF8.self))
                i += 1
                start = i
            } else {
                i += 1
            }
        }
        out.append(String(decoding: b[start...], as: UTF8.self))
        return out
    }

    private static func eol(_ sdp: String) -> String {
        let b = Array(sdp.utf8)
        for i in 0..<max(b.count - 1, 0) where b[i] == 0x0D && b[i + 1] == 0x0A { return "\r\n" }
        return "\n"
    }

    /// The value of the one session-level `a=<name>:` line (before the first `m=`).
    private static func attribute(_ sdp: String, _ name: String) throws -> String {
        let all = lines(sdp)
        let prefix = "a=\(name):"
        // The attribute anywhere else, or twice, is not something a VettID device wrote.
        let found = all.prefix { !starts($0, "m=") }.filter { starts($0, prefix) }
        guard found.count == 1, all.filter({ starts($0, prefix) }).count == 1 else { throw CryptoError.suite("media suite attribute") }
        return String(decoding: Array(found[0].utf8).dropFirst(prefix.utf8.count), as: UTF8.self)
    }

    private static func withAttribute(_ sdp: String, _ name: String, _ value: String) -> String {
        var l = lines(sdp).filter { !starts($0, "a=\(attrOffered):") && !starts($0, "a=\(attrChosen):") }
        let at = l.firstIndex { starts($0, "m=") } ?? ((l.lastIndex { !$0.isEmpty } ?? -1) + 1)
        l.insert("a=\(name):\(value)", at: at)
        return l.joined(separator: eol(sdp))
    }
}

// swiftlint:enable optional_data_string_conversion
