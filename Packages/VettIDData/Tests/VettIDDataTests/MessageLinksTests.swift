import Foundation
import Testing
@testable import VettIDData

/// The link rule of messages (VAULT-MESSAGING §10.5 "Links", IOS-PLAN §6.8): only `https://` URLs are tappable, with the
/// host the confirmation names; everything else stays text.
@Suite struct MessageLinksTests {
    /// A link of a text: the linked characters, the URL handed on and the host named.
    struct Found {
        var text: String
        var url: String
        var host: String
    }

    func found(_ text: String) -> [Found] {
        MessageLinks.links(in: text).map { Found(text: String(text[$0.range]), url: $0.url.absoluteString, host: $0.host) }
    }

    func linked(_ text: String) -> [String] { found(text).map(\.text) }

    @Test func anHttpsURLIsALinkWithItsHost() {
        let f = found("See https://example.com/path?q=1#frag now")
        #expect(f.count == 1)
        #expect(f.first?.text == "https://example.com/path?q=1#frag")
        #expect(f.first?.url == "https://example.com/path?q=1#frag")
        #expect(f.first?.host == "example.com")
    }

    @Test func everyOtherSchemeStaysText() {
        for text in [
            "http://example.com", "vettid://connect#abc", "someapp://open", "javascript:alert(1)", "ftp://example.com/x",
            "mailto:a@example.com", "tel:+15551234", "data:text/html,hi", "file:///etc/passwd", "www.example.com",
            "intent://x#Intent;scheme=https;end", "https:example.com", "https:/example.com",
        ] {
            #expect(linked(text).isEmpty, "\(text)")
        }
    }

    @Test func theSchemeIsMatchedWithoutCaseAndHandedOnInLowerCase() {
        let f = found("HTTPS://Example.COM/A")
        #expect(f.map(\.text) == ["HTTPS://Example.COM/A"])
        #expect(f.first?.url == "https://Example.COM/A" && f.first?.host == "example.com")
    }

    @Test func aLinkStartsAtAWordBoundary() {
        #expect(linked("xhttps://example.com").isEmpty)
        #expect(linked("9https://example.com").isEmpty)
        #expect(linked("a.https://example.com").isEmpty)
        #expect(linked("(https://example.com)") == ["https://example.com"])
        #expect(linked("go:https://example.com") == ["https://example.com"])
        #expect(linked("«https://example.com»") == ["https://example.com"])
    }

    @Test func trailingPunctuationIsNotPartOfTheLink() {
        #expect(linked("Look: https://example.com/a.") == ["https://example.com/a"])
        #expect(linked("https://example.com/a, and https://example.org!") == ["https://example.com/a", "https://example.org"])
        #expect(linked("\"https://example.com/q?x=1\"") == ["https://example.com/q?x=1"])
        #expect(linked("‘https://example.com/x’") == ["https://example.com/x"])
        #expect(linked("https://example.com/a?!...") == ["https://example.com/a"])
    }

    @Test func bracketsAreKeptOnlyWhenTheLinkOpensThem() {
        #expect(linked("(see https://example.com/wiki/Foo)") == ["https://example.com/wiki/Foo"])
        #expect(linked("https://en.example.org/wiki/Foo_(bar)") == ["https://en.example.org/wiki/Foo_(bar)"])
        #expect(linked("(https://en.example.org/wiki/Foo_(bar))") == ["https://en.example.org/wiki/Foo_(bar)"])
        #expect(linked("[https://example.com/a]") == ["https://example.com/a"])
    }

    @Test func aLinkEndsAtWhitespaceControlsAndAngleBrackets() {
        #expect(linked("https://example.com/a\nhttps://example.org/b") == ["https://example.com/a", "https://example.org/b"])
        #expect(linked("<https://example.com/a>") == ["https://example.com/a"])
        #expect(linked("https://example.com/a\u{202E}gpj.exe") == ["https://example.com/a"], "a direction override ends it")
        #expect(linked("https://example.com/a\u{200B}b") == ["https://example.com/a"], "an invisible character ends it")
    }

    @Test func aURLWithoutAValidHostIsText() {
        for text in [
            "https://", "https:///path", "https://a..b/", "https://.example.com", "https://exa_mple.com",
            "https://example.com:0/", "https://example.com:99999/", "https://example.com:x/",
        ] {
            #expect(linked(text).isEmpty, "\(text)")
        }
    }

    /// A name and password before the host would let the text look like one host while the confirmation names another:
    /// such a URL stays text (chosen; not in the spec).
    @Test func aURLWithANameBeforeItsHostIsText() {
        #expect(linked("https://bank.example@other.example/login").isEmpty)
        #expect(linked("https://user:pw@other.example/").isEmpty)
    }

    /// An internationalized name is named in its ASCII form, so a look-alike shows as what it is.
    @Test func anInternationalHostIsNamedInItsASCIIForm() {
        let f = found("https://bücher.example/päth")
        #expect(f.first?.host == "xn--bcher-kva.example")
        #expect(f.first?.url == "https://xn--bcher-kva.example/p%C3%A4th")
        let cyrillic = found("https://\u{440}\u{430}\u{443}\u{440}\u{430}l.example/")
        #expect(cyrillic.first?.host.hasPrefix("xn--") == true)
    }

    @Test func portsAndIPLiteralsAreLinks() {
        #expect(found("https://example.com:8443/x").first?.host == "example.com")
        #expect(found("https://192.0.2.7/x").first?.host == "192.0.2.7")
        #expect(found("https://[2001:db8::1]:8443/x").first?.host == "2001:db8::1")
    }

    @Test func linksAreFoundInOrderAndTheirRangesAreInTheText() {
        let text = "a https://one.example b https://two.example/x c"
        let links = MessageLinks.links(in: text)
        #expect(links.map(\.host) == ["one.example", "two.example"])
        #expect(links[0].range.upperBound <= links[1].range.lowerBound)
        #expect(text[links[1].range] == "https://two.example/x")
        #expect(MessageLinks.links(in: "").isEmpty && MessageLinks.links(in: "no links here").isEmpty)
    }

    /// The check made again before opening, whatever produced the candidate.
    @Test func aCandidateIsCheckedAgainBeforeOpening() {
        #expect(MessageLinks.link("https://example.com/x")?.host == "example.com")
        #expect(MessageLinks.link("http://example.com/x") == nil)
        #expect(MessageLinks.link("vettid://connect") == nil)
        #expect(MessageLinks.link("https://example.com/a b") == nil)
        #expect(MessageLinks.link(" https://example.com") == nil)
    }

    /// Peer text is scanned in linear time: 16 KiB of each pattern that made the scan quadratic before takes well under
    /// 0.2 s (a debug build).
    @Test func adversarialTextIsScannedQuickly() {
        let size = 16 * 1_024
        func rep(_ s: String) -> String { String(repeating: s, count: size / s.utf8.count) }
        let patterns = [
            "https://a" + String(repeating: ")", count: size - 9), rep("https://u@x/"),
            rep("https://"), rep("https:// "), "https://a" + String(repeating: "(", count: size - 9),
            "https://a" + String(repeating: ".", count: size - 9), rep("xhttps://a"), rep("https://a.example/ "),
        ]
        for text in patterns {
            let start = ContinuousClock.now
            _ = MessageLinks.links(in: text)
            let took = ContinuousClock.now - start
            #expect(took < .milliseconds(200), "\(text.prefix(16)): \(took)")
        }
        #expect(MessageLinks.links(in: rep("https://a.example/ ")).count == size / 19)
        #expect(linked("https://a" + String(repeating: ")", count: 100)) == ["https://a"])
    }
}
