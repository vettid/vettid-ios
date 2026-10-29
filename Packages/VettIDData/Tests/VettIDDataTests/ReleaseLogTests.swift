import Foundation
import Testing
@testable import VettIDData

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// What's new (ANDROID-PLAN "What's new"): which URL may be fetched, and what of `index.json` is used. Mirrors
/// vettid-android `ReleaseLogTest`.
@Suite struct ReleaseLogTests {
    let prod = "https://vettid.org/.well-known/vettid/pcr-manifest.json"
    let staging = "https://staging.vettid.org/.well-known/vettid/pcr-manifest.json"

    static func pcr(_ n: UInt64) -> String { String(repeating: String(format: "%02x", n), count: 48) }

    func rel(_ n: UInt64, _ notes: String? = nil, pcr0: String? = nil) -> ReleaseView {
        ReleaseView(number: n, pcr0: pcr0 ?? Self.pcr(n), status: "active", endsAt: nil, notes: notes ?? "https://vettid.org/security/releases/\(n)/")
    }

    // MARK: - The URL rules

    /// The log's GET says only `VettID-iOS` (VAULT-MESSAGING 0.75.0 §13.6).
    @Test func theFetchSaysOnlyVettIDiOS() throws {
        let r = ReleaseLogFetcher.request(try #require(URL(string: "https://example.org/log.json")))
        #expect(r.value(forHTTPHeaderField: "User-Agent") == "VettID-iOS" && r.httpMethod == "GET")
    }

    @Test func theLogUrlIsTheOnlyNotesThatFetch() {
        #expect(ReleaseLog.indexURL(prod, target: rel(5)) == "https://vettid.org/security/releases/index.json")
        #expect(ReleaseLog.indexURL(staging, target: rel(9, "https://staging.vettid.org/security/releases/9/")) == "https://staging.vettid.org/security/releases/index.json")
    }

    @Test func anyOtherNotesMeanNoFetch() {
        let other = [
            "https://github.com/vettid/vettid-vault/releases/tag/staging-s8",
            "https://vettid.org/security/releases/5", // no trailing slash
            "https://vettid.org/security/releases/6/", // another release's entry
            "https://vettid.org/security/releases/05/",
            "https://vettid.org/security/releases/5/index.html",
            "https://vettid.org/security/releases/5/?x=1",
            "https://vettid.org/security/releases/5/#top",
            "http://vettid.org/security/releases/5/", // not https
            "https://VETTID.org/security/releases/5/",
            "https://vettid.org:8443/security/releases/5/",
            "https://evil.example/security/releases/5/",
            "https://vettid.org.evil.example/security/releases/5/",
            "https://user@vettid.org/security/releases/5/",
            "https://staging.vettid.org/security/releases/5/", // another channel's log
            " https://vettid.org/security/releases/5/",
            "",
        ]
        for n in other { #expect(ReleaseLog.indexURL(prod, target: rel(5, n)) == nil, "\(n)") }
        // The staging build only fetches from staging.vettid.org.
        #expect(ReleaseLog.indexURL(staging, target: rel(5)) == nil)
        #expect(ReleaseLog.indexURL("not a url", target: rel(5)) == nil)
        #expect(ReleaseLog.indexURL(prod, target: rel(0, "https://vettid.org/security/releases/0/")) == nil)
    }

    @Test func theHostIsThePinnedManifests() {
        #expect(ReleaseLog.host(prod) == "vettid.org")
        #expect(ReleaseLog.host(staging) == "staging.vettid.org")
        #expect(ReleaseLog.origin("http://localhost:18080/.well-known/vettid/pcr-manifest.json") == "http://localhost:18080")
        #expect(ReleaseLog.origin(prod) == "https://vettid.org")
    }

    @Test func onlyHttpsNotesOpen() {
        #expect(ReleaseLog.openable("https://vettid.org/security/releases/5/"))
        #expect(ReleaseLog.openable("https://github.com/vettid/vettid-vault/releases/tag/staging-s8"))
        #expect(!ReleaseLog.openable("http://vettid.org/security/releases/5/"))
        #expect(!ReleaseLog.openable("javascript:alert(1)"))
        #expect(!ReleaseLog.openable(""))
    }

    // MARK: - index.json

    func entry(_ n: UInt64, pcr0: String? = nil, summary: String? = nil, changes: String = #"["one", "two"]"#, security: String = #""none""#, extra: String = "") -> String {
        #"{"release": \#(n), "status": "active", "published_at": "2026-10-01T00:00:00Z", "pcr0": "\#(pcr0 ?? Self.pcr(n))", "pcr1": "aa", "pcr2": "bb", "seal_key": "arn:aws:kms:x", "notes": "https://vettid.org/security/releases/\#(n)/", "summary": \#(summary ?? "\"Release \(n) summary\""), "changes": \#(changes), "security": \#(security), "listed": true\#(extra)}"#
    }

    func index(_ entries: String...) -> [UInt8] { Array(#"{"serial": 12, "releases": [\#(entries.joined(separator: ","))]}"#.utf8) }

    @Test func theEntryMatchesNumberAndPcr0() throws {
        let (e, earlier) = try #require(ReleaseLog.parse(index(entry(6), entry(5), entry(4)), target: rel(5), between: []))
        #expect(e.release == 5)
        #expect(e.summary == "Release 5 summary")
        #expect(e.changes == ["one", "two"])
        #expect(e.security == .none)
        #expect(e.securityText == nil)
        #expect(earlier.isEmpty)
    }

    @Test func anotherPcr0IsNoEntry() {
        #expect(ReleaseLog.parse(index(entry(5, pcr0: Self.pcr(7))), target: rel(5), between: []) == nil)
        #expect(ReleaseLog.parse(index(entry(10, pcr0: Self.pcr(10).uppercased())), target: rel(10), between: []) == nil)
        #expect(ReleaseLog.parse(index(entry(4)), target: rel(5), between: []) == nil)
        // The number as a string is not the number.
        #expect(ReleaseLog.parse(index(entry(5).replacingOccurrences(of: #""release": 5"#, with: #""release": "5""#)), target: rel(5), between: []) == nil)
        #expect(ReleaseLog.parse(index(entry(5).replacingOccurrences(of: #""release": 5"#, with: #""release": true"#)), target: rel(1), between: []) == nil)
        // A number with a fraction or an exponent is not an integer, as `longOrNull` reads it.
        #expect(ReleaseLog.parse(index(entry(5).replacingOccurrences(of: #""release": 5"#, with: #""release": 5.0"#)), target: rel(5), between: []) == nil)
        #expect(ReleaseLog.parse(index(entry(5).replacingOccurrences(of: #""release": 5"#, with: #""release": 5e0"#)), target: rel(5), between: []) == nil)
    }

    @Test func aDocumentThatIsNoLogIsNoEntry() {
        for body in ["", "null", "[]", "{}", #"{"releases": {}}"#, "<html>", #"{"releases": [1, "x"]}"#] {
            #expect(ReleaseLog.parse(Array(body.utf8), target: rel(5), between: []) == nil, "\(body)")
        }
        // Malformed fields of the entry: none.
        #expect(ReleaseLog.parse(index(entry(5, summary: "5")), target: rel(5), between: []) == nil)
        #expect(ReleaseLog.parse(index(entry(5, summary: #""  ""#)), target: rel(5), between: []) == nil)
        #expect(ReleaseLog.parse(index(entry(5, changes: #""one""#)), target: rel(5), between: []) == nil)
        #expect(ReleaseLog.parse(index(entry(5, changes: #"["one", 2]"#)), target: rel(5), between: []) == nil)
        #expect(ReleaseLog.parse(index(entry(5, security: #""critical""#)), target: rel(5), between: []) == nil)
    }

    @Test func theSecurityLine() throws {
        let (e, _) = try #require(ReleaseLog.parse(index(entry(5, security: #""urgent""#, extra: #", "security_text": "Fixes a flaw in the PIN check.""#)), target: rel(5), between: []))
        #expect(e.security == .urgent)
        #expect(e.securityText == "Fixes a flaw in the PIN check.")
        let (r, _) = try #require(ReleaseLog.parse(index(entry(5, security: #""recommended""#)), target: rel(5), between: []))
        #expect(r.security == .recommended)
    }

    @Test func fieldsAreCutAtTheLimits() throws {
        let long = String(repeating: "x", count: 500)
        let changes = "[" + Array(repeating: "\"\(long)\"", count: 25).joined(separator: ",") + "]"
        let body = index(entry(5, summary: "\"\(long)\"", changes: changes, security: #""urgent""#, extra: #", "security_text": "\#(String(repeating: "y", count: 1500))""#))
        let (e, _) = try #require(ReleaseLog.parse(body, target: rel(5), between: []))
        #expect(e.summary.unicodeScalars.count == ReleaseLog.maxSummary)
        #expect(e.summary.hasSuffix("…"))
        #expect(e.changes.count == ReleaseLog.maxChanges)
        #expect(e.changes.allSatisfy { $0.unicodeScalars.count == ReleaseLog.maxChange && $0.hasSuffix("…") })
        #expect(e.securityText?.unicodeScalars.count == ReleaseLog.maxSecurityText)
        // At the limit nothing is cut.
        #expect(ReleaseLog.plain(String(repeating: "a", count: 160), 160) == String(repeating: "a", count: 160))
    }

    @Test func textIsPlain() {
        #expect(ReleaseLog.plain("  a\n\tb\u{0}\u{202E}c  ", 100) == "a b c")
        #expect(ReleaseLog.plain("<b>x</b> https://evil.example", 100) == "<b>x</b> https://evil.example")
        // A cut never splits a character's scalars apart into invalid text.
        let s = ReleaseLog.plain("ab" + String(repeating: "😀", count: 10), 5)
        #expect(s == "ab😀😀…")
    }

    @Test func earlierReleasesAreMatchedTheSameWay() throws {
        let body = index(entry(7), entry(6, summary: #""Six""#), entry(5, summary: #""Five""#), entry(4, pcr0: Self.pcr(9)), entry(3))
        let (e, earlier) = try #require(ReleaseLog.parse(body, target: rel(7), between: [rel(4), rel(5), rel(6)]))
        #expect(e.release == 7)
        // Newest first; 4's PCR0 differs from the manifest's: left out; 3 is not between.
        #expect(earlier == [EarlierRelease(release: 6, summary: "Six"), EarlierRelease(release: 5, summary: "Five")])
    }

    /// The client fetches only the allowed URL, keeps a found entry, and never keeps a failure.
    @Test func theClientFetchesOnlyTheLogAndKeepsWhatItFound() async {
        final class Fetches: @unchecked Sendable {
            let lock = NSLock()
            var urls: [String] = []
            var body: [UInt8]?
        }
        let f = Fetches()
        let client = ReleaseNotesClient(manifestURL: prod) { url in
            f.lock.withLock {
                f.urls.append(url.absoluteString)
                return f.body
            }
        }
        #expect(await client.whatsNew(target: rel(5, "https://github.com/x"), between: []) == .unavailable)
        #expect(f.urls.isEmpty)
        #expect(await client.whatsNew(target: rel(5), between: []) == .unavailable)
        f.lock.withLock { f.body = index(entry(5)) }
        guard case .available(let host, let e, _) = await client.whatsNew(target: rel(5), between: []) else {
            Issue.record("no entry")
            return
        }
        #expect(host == "vettid.org" && e.release == 5)
        f.lock.withLock { f.body = nil }
        #expect(await client.whatsNew(target: rel(5), between: []) != .unavailable)
        #expect(f.urls == Array(repeating: "https://vettid.org/security/releases/index.json", count: 2))
    }

    @Test func onlyJsonAnswersAreRead() {
        #expect(ReleaseLogFetcher.isJSON("application/json"))
        #expect(ReleaseLogFetcher.isJSON("application/vnd.vettid+json"))
        #expect(!ReleaseLogFetcher.isJSON("text/html"))
        #expect(!ReleaseLogFetcher.isJSON(nil))
    }
}

// swiftlint:enable line_length
