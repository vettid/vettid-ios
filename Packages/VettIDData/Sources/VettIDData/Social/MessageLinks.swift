import Foundation

/// A tappable link in a message: where it is in the text, the URL handed to the system after the member confirmed, and
/// the host the confirmation names ("Open link to <host>?", IOS-PLAN §6.8).
public struct MessageLink: Equatable, Sendable {
    /// The link's characters in the message text.
    public let range: Range<String.Index>
    public let url: URL
    /// The host as the system will reach it: lower case, an internationalized name in its ASCII (`xn--`) form, so that a
    /// look-alike name shows as what it is.
    public let host: String
}

/// The link rule of messages (VAULT-MESSAGING §10.5 "Links", IOS-PLAN §6.8): the text is plain text and only `https://`
/// URLs are tappable; every other scheme, custom app schemes (`someapp://`, `vettid://`) and `http://` included, stays
/// text and is never opened. vettid-android has the rule in ANDROID-PLAN §4 (Conversation) but no code for it yet; this
/// is written from the specification. Choices (chosen; not in the spec), all on the side of showing text:
/// - the scheme is matched without regard to case (`HTTPS://` is `https://`, RFC 3986 §3.1) and handed on in lower case;
/// - a link starts at the start of the text or after a character that is not a letter, digit or one of `+-.` (so that
///   `xhttps://` is not cut out of a word), and ends before whitespace, a control character or `<>"`;
/// - trailing punctuation (`.,:;!?'"*`, typographic quotes) is not part of it, nor a closing `)`, `]` or `}` without its
///   opening one in the link (a link written in parentheses);
/// - a URL without a host, with a name and password before its host (`https://bank.example@other.example`: the
///   confirmation would name only the second), with an invalid host or a port outside 1–65535 is not a link.
/// - a candidate that is not a link (inside a word, or not a valid URL) is passed over up to its end, so that the text is
///   scanned once: an `https://` later in the same run (`xhttps://a.example/https://b.example`) is not linked either.
public enum MessageLinks {
    static let scheme = "https://"

    /// The tappable links of [text], in order.
    public static func links(in text: String) -> [MessageLink] {
        var found: [MessageLink] = []
        var from = text.startIndex
        while let r = text.range(of: scheme, options: [.caseInsensitive, .literal], range: from..<text.endIndex) {
            from = r.upperBound
            guard text[r].lowercased() == scheme else { continue }
            // A candidate that is not a link is passed over whole, so that the text is scanned once.
            let runEnd = linkEnd(text, from: r.upperBound)
            from = runEnd
            guard startsWord(text, at: r.lowerBound) else { continue }
            let end = trimmed(text, r.lowerBound, runEnd)
            guard end > r.upperBound, let link = link(String(text[r.lowerBound..<end])) else { continue }
            found.append(MessageLink(range: r.lowerBound..<end, url: link.url, host: link.host))
        }
        return found
    }

    /// The URL to hand to the system for [candidate] (a whole link, as a tap gives it back), with the host to name; nil
    /// for anything the rule does not make tappable. Checked again before opening, whatever produced the candidate.
    public static func link(_ candidate: String) -> (url: URL, host: String)? {
        guard candidate.count > scheme.count, candidate.prefix(scheme.count).lowercased() == scheme,
              !candidate.contains(where: { $0.isWhitespace || isControl($0) }),
              let url = URL(string: "https://" + candidate.dropFirst(scheme.count)),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil,
              let raw = url.host(percentEncoded: false), let host = validHost(raw) else { return nil }
        if let port = c.port, !(1...65_535).contains(port) { return nil }
        c.scheme = "https"
        return c.url.map { ($0, host) }
    }

    /// A host name of non-empty labels of letters, digits and `-`, or an IP literal; lower case.
    static func validHost(_ raw: String) -> String? {
        let h = raw.lowercased()
        guard !h.isEmpty else { return nil }
        if h.contains(":") { return h.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } ? h : nil } // IPv6 (in brackets)
        let name = h.hasSuffix(".") ? String(h.dropLast()) : h
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let ok = !labels.isEmpty && labels.allSatisfy { l in
            !l.isEmpty && l.utf8.count <= 63 && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        return ok ? h : nil
    }

    private static func isControl(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }

    /// Whether a link may start at [i]: the start of the text, or after a character that does not continue a word.
    private static func startsWord(_ text: String, at i: String.Index) -> Bool {
        guard i > text.startIndex else { return true }
        let p = text[text.index(before: i)]
        return !(p.isLetter || p.isNumber || p == "+" || p == "-" || p == ".")
    }

    /// The end of the run of characters a link may hold, from [i].
    private static func linkEnd(_ text: String, from i: String.Index) -> String.Index {
        text[i...].firstIndex { $0.isWhitespace || isControl($0) || $0 == "<" || $0 == ">" || $0 == "\"" } ?? text.endIndex
    }

    /// The closing brackets a link keeps only with their opening one in it.
    private static let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    private static let trailing: Set<Character> = [".", ",", ":", ";", "!", "?", "'", "*", "\u{2019}", "\u{201D}", "\u{00BB}"]

    /// [end] moved back over trailing punctuation and unbalanced closing brackets. The brackets are counted once and the
    /// counts kept as characters are dropped, so that the work is linear in the link's length.
    private static func trimmed(_ text: String, _ start: String.Index, _ end: String.Index) -> String.Index {
        var count: [Character: Int] = [:]
        for ch in text[start..<end] where pairs[ch] != nil || pairs.values.contains(ch) { count[ch, default: 0] += 1 }
        var e = end
        while e > start {
            let last = text[text.index(before: e)]
            if trailing.contains(last) {
                e = text.index(before: e)
                continue
            }
            guard let open = pairs[last] else { break }
            let opens = count[open] ?? 0
            let closes = count[last] ?? 0
            guard opens < closes else { break }
            count[last] = closes - 1
            e = text.index(before: e)
        }
        return e
    }
}
