import Foundation
import Testing
import VettIDCrypto
import VettIDData

/// Invitation links (VAULT-MESSAGING §6.4, 0.10.2) and the link the app was opened with. Mirrors vettid-android
/// `InviteLinksTest` (its transfer codes come with the transfer).
@MainActor
@Suite struct InviteLinksTests {
    let now = Date(timeIntervalSince1970: 1_791_115_200) // 2026-10-04T12:00:00Z
    var exp: UInt64 { UInt64(now.timeIntervalSince1970) + 600 }

    func qr(_ kind: InviteKind = .connection, exp e: UInt64? = nil, relay: String = "https://relay.vettid.test") -> InviteQr {
        InviteQr(
            kind: kind, relay: relay, claimID: "abcdefghijklmnopqrstuvwxyz", hash: [UInt8](repeating: 1, count: 32),
            key: [UInt8](repeating: 2, count: 32), exp: e ?? exp
        )
    }

    @Test func acceptsTheLinkTheQrJsonAndLinksInsideText() throws {
        let q = qr()
        let link = try q.link()
        let json = try #require(String(bytes: try q.marshal(), encoding: .utf8))
        let expected = InviteLinks.Parsed.ok(link: link, exp: Date(timeIntervalSince1970: TimeInterval(exp)))
        for text in [
            link, "  \(link)\n", json, "https://vettid.org/connect#\(link)", "https://example.org/i?c=\(link)",
            "Connect with me on VettID: paste this:\n\n\(link)",
            // 0.10.2: the URL on the invitation's relay, any host, and the relay page's vettid: link.
            "https://relay.vettid.org/connect#\(link)", "https://my-home-relay.example/connect#\(link)", "vettid://connect#\(link)",
            "Join me: https://relay.vettid.test/connect#\(link) (VettID)",
        ] {
            #expect(InviteLinks.parse(text, now: now) == expected, "\(text.prefix(30))")
        }
        #expect(try InviteLinks.qrPayload(link) == json)
        #expect(try InviteLinks.expiry(link) == Date(timeIntervalSince1970: TimeInterval(exp)))
    }

    @Test func refusesOtherKindsExpiredAndGarbage() throws {
        #expect(InviteLinks.parse(try qr(.desktop).link(), now: now) == .notAConnection)
        #expect(InviteLinks.parse(try qr(.app).link(), now: now) == .notAConnection)
        #expect(InviteLinks.parse(try qr(exp: UInt64(now.timeIntervalSince1970)).link(), now: now) == .expired)
        #expect(InviteLinks.parse("", now: now) == .invalid)
        #expect(InviteLinks.parse("hello there", now: now) == .invalid)
        #expect(InviteLinks.parse(#"{"v":2,"t":"c"}"#, now: now) == .invalid)
        // A link with characters changed no longer parses (or parses to another claim): never the original.
        let link = try qr().link()
        let tampered = String(link.dropLast(4)) + "AAAA"
        #expect(InviteLinks.parse(tampered, now: now) != .ok(link: link, exp: Date(timeIntervalSince1970: TimeInterval(exp))))
    }

    @Test func buildsTheUrlFromThePayloadsRelay() throws {
        let link = try qr().link()
        #expect(InviteLinks.url(link) == "https://relay.vettid.test/connect#\(link)")
        let slash = try qr(relay: "https://r.example/base/").link()
        #expect(InviteLinks.url(slash) == "https://r.example/base/connect#\(slash)")
        #expect(InviteLinks.url(try qr(.desktop).link()) == nil)
        #expect(InviteLinks.url("garbage") == nil)
        // The URL host is not trusted: a link on another host still names the payload's relay.
        guard case .ok(let parsed, _) = InviteLinks.parse("https://evil.example/connect#\(link)", now: now) else {
            Issue.record("not parsed")
            return
        }
        #expect(try InviteQr.parseLink(parsed).relay == "https://relay.vettid.test")
        let info = InviteInfo(inviteID: "i", link: link, qr: "{}", exp: now, remote: false)
        #expect(info.url == "https://relay.vettid.test/connect#\(link)")
    }

    @Test func recognisesConnectUrls() {
        #expect(InviteLinks.isConnectURL("vettid://connect#abc"))
        #expect(InviteLinks.isConnectURL("https://relay.vettid.org/connect#abc"))
        #expect(InviteLinks.isConnectURL("https://self-hosted.example/connect/#abc"))
        #expect(!InviteLinks.isConnectURL("https://account.vettid.org/auth/#t=x"))
        #expect(!InviteLinks.isConnectURL("https://account.vettid.org/vault/enroll/#s=x"))
        #expect(!InviteLinks.isConnectURL("vettid://other#abc"))
        #expect(!InviteLinks.isConnectURL("not a uri"))
    }

    @Test func theInboxHandsTheLinkOverOnceAndNeverDumpsIt() {
        let inbox = InviteLinkInbox()
        #expect(inbox.link == nil)
        inbox.offer("https://relay.vettid.org/connect#PAYLOAD123")
        #expect(inbox.link == "https://relay.vettid.org/connect#PAYLOAD123")
        var dumped = ""
        dump(inbox, to: &dumped)
        for text in [dumped, String(reflecting: inbox), "\(inbox)"] {
            #expect(!text.contains("PAYLOAD123") && !text.contains("connect"), "\(text)")
        }
        inbox.consume()
        #expect(inbox.link == nil)
    }

    @Test func inviteLifetimes() {
        #expect(InviteTtl.allCases.map(\.seconds) == [600, 3_600, 86_400, 604_800])
        #expect(InviteTtl.allCases.filter(\.remote) == [.oneHour, .oneDay, .sevenDays])
    }
}
