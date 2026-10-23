import Foundation
import Testing
import VettIDCrypto
import VettIDData

/// The old phone's transfer code, on the new phone (VAULT-MESSAGING §6.7.1: pairing kind `p`). Mirrors vettid-android
/// `InviteLinksTest`'s transfer cases.
@MainActor
@Suite struct InviteLinksTransferTests {
    let now = Date(timeIntervalSince1970: 1_791_115_200) // 2026-10-04T12:00:00Z
    var exp: UInt64 { UInt64(now.timeIntervalSince1970) + 600 }

    func qr(_ kind: InviteKind = .app, exp e: UInt64? = nil) -> InviteQr {
        InviteQr(
            kind: kind, relay: "https://relay.vettid.test", claimID: "abcdefghijklmnopqrstuvwxyz",
            hash: [UInt8](repeating: 1, count: 32), key: [UInt8](repeating: 2, count: 32), exp: e ?? exp
        )
    }

    @Test func acceptsTheQrJsonTheLinkAndLinksInsideText() throws {
        let q = qr()
        let link = try q.link()
        let json = try #require(String(bytes: try q.marshal(), encoding: .utf8))
        let expected = InviteLinks.TransferParsed.ok(link: link, exp: Date(timeIntervalSince1970: TimeInterval(exp)))
        for text in [link, "  \(link)\n", json, "https://vettid.org/p#\(link)", "Move VettID: paste this:\n\n\(link)"] {
            #expect(InviteLinks.parseTransfer(text, now: now) == expected, "\(text.prefix(30))")
        }
    }

    @Test func refusesOtherKindsExpiredAndGarbageBeforeAnythingIsSent() throws {
        for kind in [InviteKind.connection, .desktop, .agent] {
            #expect(InviteLinks.parseTransfer(try qr(kind).link(), now: now) == .notATransfer)
            #expect(InviteLinks.parseTransfer(try String(bytes: qr(kind).marshal(), encoding: .utf8) ?? "", now: now) == .notATransfer)
        }
        #expect(InviteLinks.parseTransfer(try qr(exp: UInt64(now.timeIntervalSince1970)).link(), now: now) == .expired)
        #expect(InviteLinks.parseTransfer(try qr(exp: UInt64(now.timeIntervalSince1970) - 1).link(), now: now) == .expired)
        #expect(InviteLinks.parseTransfer("", now: now) == .invalid)
        #expect(InviteLinks.parseTransfer("   ", now: now) == .invalid)
        #expect(InviteLinks.parseTransfer("hello there", now: now) == .invalid)
        #expect(InviteLinks.parseTransfer(#"{"v":2,"t":"p"}"#, now: now) == .invalid)
    }

    /// A connection invitation is not a transfer, and a transfer code is not a connection invitation.
    @Test func theTwoKindsAreNotInterchangeable() throws {
        let transfer = try qr(.app).link()
        let connection = try qr(.connection).link()
        #expect(InviteLinks.parse(transfer, now: now) == .notAConnection)
        #expect(InviteLinks.parseTransfer(connection, now: now) == .notATransfer)
    }
}
