import Foundation
import Testing
@testable import VettIDRelay
import VettIDCrypto

// Spec vectors stay on one line each.
// swiftlint:disable line_length

/// RELAY-PROTOCOL 0.9.4 §9 test vectors, which vettid-relay's relayauth/vectors_test.go also pins. Every value is copied
/// verbatim from the spec and must be reproduced byte for byte. Mirrors vettid-android `VectorsTest`.
@Suite struct RelayVectorsTests {
    static let recipientSeed = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    static let recipientPub = "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w="
    static let recipientMailbox = "gr2q7gf5lh6pzfdnurnkvputhp"
    static let senderSeed = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="
    static let senderPub = "gTl3Dqh9F19Wo1Rmw0x+zMuNipG07jeiXfYPW4/Js5Q="
    static let senderMailbox = "ni4ahvpqlgicuhdnv66jxjdssi"

    static let claims = #"{"iss":"gr2q7gf5lh6pzfdnurnkvputhp","sub":"gTl3Dqh9F19Wo1Rmw0x+zMuNipG07jeiXfYPW4/Js5Q=","aud":"https://relay.example.vettid.org","iat":"2026-06-10T00:00:00Z","exp":"2026-07-10T00:00:00Z","jti":"01JXAMPLE0000000000000000","scope":"deposit"}"#
    static let token = "v4.public." + "eyJpc3MiOiJncjJxN2dmNWxoNnB6ZmRudXJua3ZwdXRocCIsInN1YiI6ImdUbDNEcWg5RjE5V28xUm13MHgrek11TmlwRzA3amVpWGZZUFc0L0pzNVE9IiwiYXVkIjoiaHR0cHM6Ly9yZWxheS5leGFtcGxlLnZldHRpZC5vcmciLCJpYXQiOiIyMDI2LTA2LTEwVDAwOjAwOjAwWiIsImV4cCI6IjIwMjYtMDctMTBUMDA6MDA6MDBaIiwianRpIjoiMDFKWEFNUExFMDAwMDAwMDAwMDAwMDAwMCIsInNjb3BlIjoiZGVwb3NpdCJ9rWQjEmgif2o_c9SNTUXzHPPLWKZCPMAPUk3VPpbWkTIY0pfihNHpVZeX-YDM35FN_u1FVYPHj4BrO4sGJQj6BA"
    static let aud = "https://relay.example.vettid.org"

    static let method = "POST"
    static let path = "/v1/mailbox/gr2q7gf5lh6pzfdnurnkvputhp"
    static let body = #"{"payload":"b3BhcXVlLWNpcGhlcnRleHQtYnl0ZXM="}"#
    static let bodyHex = "0237514b3df17b219036f1b8fa6ca70d4ca597eb630933841707380055d7e12a"
    static let timestamp = "2026-06-10T12:00:00Z"
    static let canonical = "POST\n/v1/mailbox/gr2q7gf5lh6pzfdnurnkvputhp\n2026-06-10T12:00:00Z\n0237514b3df17b219036f1b8fa6ca70d4ca597eb630933841707380055d7e12a"
    static let digestB64 = "l+mc5XMNElCBLC49xJH4Lc8LHEAlAK1HunqaS+LZ33k="
    static let sigB64 = "pOZT7Pb981+3K4wWv6Zryb43miSLBfKdCZ4Wc/qNzQyxFtOPrsSSkK1Gj5mF+Zb3z3yC4Bi7AyjIyVkeN+nsDA=="

    static func key(_ seedB64: String) throws -> Ed25519PrivateKey { try Ed25519PrivateKey.fromSeed(try Base64s.decodeStd(seedB64)) }

    static func date(_ s: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = s.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return try #require(f.date(from: s))
    }

    @Test func keysAndMailboxIDs() throws { // §9.1
        for (seed, pub, mbx) in [(Self.recipientSeed, Self.recipientPub, Self.recipientMailbox), (Self.senderSeed, Self.senderPub, Self.senderMailbox)] {
            let k = try Self.key(seed)
            #expect(RelayAuth.encodeKey(k.publicKey) == pub)
            #expect(RelayAuth.mailboxID(k.publicKey) == mbx)
            #expect(RelayAuth.isValidMailboxID(mbx))
        }
        #expect(!RelayAuth.isValidMailboxID("GR2Q7GF5LH6PZFDNURNKVPUTHP"))
        #expect(!RelayAuth.isValidMailboxID("gr2q7gf5lh6pzfdnurnkvputh1"))
        #expect(!RelayAuth.isValidMailboxID("gr2q7gf5lh6pzfdnurnkvputh"))
    }

    @Test func depositToken() throws { // §9.2
        let claims = TokenClaims(
            iss: Self.recipientMailbox, sub: Self.senderPub, aud: Self.aud,
            iat: try Self.date("2026-06-10T00:00:00Z"), exp: try Self.date("2026-07-10T00:00:00Z"),
            jti: "01JXAMPLE0000000000000000", scope: TokenClaims.scopeDeposit
        )
        #expect(claims.json() == Self.claims)
        #expect(try DepositTokens.mint(Self.key(Self.recipientSeed), claims) == Self.token)
        #expect(try Paseto.sign(Self.key(Self.recipientSeed), Array(Self.claims.utf8)) == Self.token)
        let parsed = try DepositTokens.verify(Self.token, issuer: try Base64s.decodeStd(Self.recipientPub))
        #expect(parsed == claims)
        #expect(RelayAuth.encodeKey(try #require(parsed.subKey)) == Self.senderPub)
    }

    @Test func signedRequest() throws { // §9.3
        let bh = RelayAuth.bodyHash(Array(Self.body.utf8))
        #expect(Bytes.hex(bh) == Self.bodyHex)
        #expect(RelayAuth.canonical(method: Self.method, path: Self.path, timestamp: Self.timestamp, bodyHash: bh) == Array(Self.canonical.utf8))
        #expect(Base64s.encodeStd(RelayAuth.digest(method: Self.method, path: Self.path, timestamp: Self.timestamp, bodyHash: bh)) == Self.digestB64)
        let sender = try Self.key(Self.senderSeed)
        #expect(Base64s.encodeStd(try RelayAuth.signRequest(sender, method: Self.method, path: Self.path, timestamp: Self.timestamp, bodyHash: bh)) == Self.sigB64)
        let h = try RelayAuth.headers(sender, method: Self.method, path: Self.path, at: try Self.date(Self.timestamp), bodyHash: bh)
        #expect(h == [RelayAuth.headerKey: Self.senderPub, RelayAuth.headerTimestamp: Self.timestamp, RelayAuth.headerSig: Self.sigB64])
    }

    @Test func emptyBodyHash() {
        #expect(Bytes.hex(RelayAuth.bodyHash(nil)) == RelayAuth.emptyBodyHash)
        #expect(Bytes.hex(RelayAuth.bodyHash([])) == RelayAuth.emptyBodyHash)
    }

    @Test func canonicalUppercasesTheMethodInASCII() {
        let bh = RelayAuth.bodyHash(nil)
        #expect(RelayAuth.canonical(method: "get", path: "/v1/mailbox", timestamp: "t", bodyHash: bh) == RelayAuth.canonical(method: "GET", path: "/v1/mailbox", timestamp: "t", bodyHash: bh))
        #expect(RelayAuth.canonical(method: "ı", path: "/", timestamp: "t", bodyHash: bh).starts(with: Array("ı".utf8)))
    }

    /// Millisecond RFC 3339 with trailing zeros trimmed, ASCII digits only: Swift's integer formatting never follows
    /// the device's language, so a Persian, Arabic or Bengali phone signs the same header (vettid-android `WireLocaleTest`).
    @Test func timestampsAreMillisecondRFC3339InASCII() throws {
        for (t, want) in [
            ("2026-06-10T12:00:00Z", "2026-06-10T12:00:00Z"),
            ("2026-06-10T12:00:00.123456Z", "2026-06-10T12:00:00.123Z"),
            ("2026-06-10T12:00:00.100Z", "2026-06-10T12:00:00.1Z"),
            ("2026-06-10T12:00:00.050Z", "2026-06-10T12:00:00.05Z"),
            ("2026-10-04T12:34:56.005Z", "2026-10-04T12:34:56.005Z"),
        ] {
            let got = RelayAuth.timestamp(try Self.date(t))
            #expect(got == want)
            #expect(got.utf8.allSatisfy { (0x20...0x7E).contains($0) })
        }
    }
}

/// Token minting and checking, mirroring vettid-relay relayauth/token_test.go and vettid-android `TokenTest`.
@Suite struct TokenTests {
    let recipient: Ed25519PrivateKey
    let sender: Ed25519PrivateKey
    let now: Date

    init() throws {
        recipient = try RelayVectorsTests.key(RelayVectorsTests.recipientSeed)
        sender = try RelayVectorsTests.key(RelayVectorsTests.senderSeed)
        now = try RelayVectorsTests.date("2026-10-04T12:34:56.789Z")
    }

    @Test func standingTokenIsBackdatedSixtySeconds() throws {
        let t = try DepositTokens.mintStanding(recipient, sender: RelayVectorsTests.senderPub, audience: RelayVectorsTests.aud, now: now, jti: "01JXAMPLE0000000000000001")
        let c = try DepositTokens.verify(t, issuer: recipient.publicKey)
        #expect(c.iat == (try RelayVectorsTests.date("2026-10-04T12:33:56Z")))
        #expect(c.exp == c.iat.addingTimeInterval(30 * 86400))
        #expect(c.iss == RelayVectorsTests.recipientMailbox)
        #expect(c.scope == TokenClaims.scopeDeposit)
        #expect(c.sub == RelayVectorsTests.senderPub)
        // A generated jti is a ULID.
        let g = try DepositTokens.verify(try DepositTokens.mintStanding(recipient, sender: RelayVectorsTests.senderPub, audience: RelayVectorsTests.aud, now: now), issuer: recipient.publicKey)
        #expect(Ulid.isValid(g.jti))
    }

    @Test func openTokenBackdatesAtMostHalfItsLifetime() throws {
        let short = try DepositTokens.verify(try DepositTokens.mintOpen(recipient, audience: RelayVectorsTests.aud, now: now, ttl: 60), issuer: recipient.publicKey)
        #expect(short.iat == (try RelayVectorsTests.date("2026-10-04T12:34:26Z")))
        #expect(short.exp.timeIntervalSince(short.iat) == 60)
        #expect(short.isOpen && short.sub == TokenClaims.openSub && short.subKey == nil)
        let long = try DepositTokens.verify(try DepositTokens.mintOpen(recipient, audience: RelayVectorsTests.aud, now: now, ttl: 600), issuer: recipient.publicKey)
        #expect(long.iat == (try RelayVectorsTests.date("2026-10-04T12:33:56Z")))
    }

    @Test func quotaFollowsScopeInClaims() throws {
        let t = try DepositTokens.mintStanding(recipient, sender: RelayVectorsTests.senderPub, audience: RelayVectorsTests.aud, now: now, ttl: 365 * 86400, jti: "j1", quota: Quota(msgs: 4, bytes: 65536))
        let m = try #require(String(bytes: try Paseto.verify(t, pub: recipient.publicKey), encoding: .utf8))
        #expect(m.hasSuffix(#""scope":"deposit","quota":{"msgs":4,"bytes":65536}}"#))
        #expect(try DepositTokens.verify(t, issuer: recipient.publicKey).quota == Quota(msgs: 4, bytes: 65536))
    }

    @Test func rejectsWrongKeyTamperingFootersAndGarbage() throws {
        let t = RelayVectorsTests.token
        let i = t.index(t.startIndex, offsetBy: 40)
        let flipped = String(t[..<i]) + (t[i] == "A" ? "B" : "A") + String(t[t.index(after: i)...])
        let mid = t.index(t.startIndex, offsetBy: 50)
        for bad in [flipped, t + ".Zm9v", "v3.public." + t.dropFirst(10), String(t[..<mid]) + "\n" + String(t[mid...]), "v4.public.AAAA", String(repeating: "A", count: 5000)] {
            #expect(throws: TokenError.invalid) { _ = try Paseto.verify(bad, pub: recipient.publicKey) }
        }
        #expect(throws: TokenError.invalid) { _ = try Paseto.verify(t, pub: sender.publicKey) }
    }

    @Test func claimsAreValidatedStructurally() throws {
        func signed(_ json: String) throws -> String { try Paseto.sign(recipient, Array(json.utf8)) }
        let base = #""iss":"gr2q7gf5lh6pzfdnurnkvputhp","aud":"a","iat":"2026-06-10T00:00:00Z","exp":"2026-07-10T00:00:00Z","jti":"j""#
        // An open token must have sub "*"; a sender-bound one a key; an unknown scope, a missing jti or a bad iss is refused.
        for bad in [
            "{\(base),\"sub\":\"x\",\"scope\":\"deposit_open\"}",
            "{\(base),\"sub\":\"*\",\"scope\":\"deposit\"}",
            "{\(base),\"sub\":\"*\",\"scope\":\"admin\"}",
            #"{"iss":"gr2q7gf5lh6pzfdnurnkvputhp","sub":"*","aud":"a","iat":"2026-06-10T00:00:00Z","exp":"2026-07-10T00:00:00Z","scope":"deposit_open"}"#,
            #"{"iss":"not-a-mailbox","sub":"*","aud":"a","iat":"2026-06-10T00:00:00Z","exp":"2026-07-10T00:00:00Z","jti":"j","scope":"deposit_open"}"#,
            "{\(base),\"sub\":\"*\",\"scope\":\"deposit_open\",\"quota\":{\"msgs\":-1}}",
            "{\(base.replacingOccurrences(of: "2026-06-10T00:00:00Z", with: "yesterday")),\"sub\":\"*\",\"scope\":\"deposit_open\"}",
        ] {
            #expect(throws: TokenError.invalid, "\(bad)") { _ = try DepositTokens.verify(try signed(bad), issuer: recipient.publicKey) }
        }
        let ok = try DepositTokens.verify(try signed("{\(base),\"sub\":\"*\",\"scope\":\"deposit_open\",\"extra\":1}"), issuer: recipient.publicKey)
        #expect(ok.isOpen)
        // Times with an offset or fractional seconds, as RFC 3339 allows.
        let offset = try DepositTokens.verify(try signed("{\(base.replacingOccurrences(of: "2026-06-10T00:00:00Z", with: "2026-06-10T02:00:00.5+02:00")),\"sub\":\"*\",\"scope\":\"deposit_open\"}"), issuer: recipient.publicKey)
        #expect(offset.iat == (try RelayVectorsTests.date("2026-06-10T00:00:00.500Z")))
    }

    @Test func decodeKeyIsStrict() {
        #expect(RelayAuth.decodeKey(RelayVectorsTests.senderPub)?.count == 32)
        #expect(RelayAuth.decodeKey(String(RelayVectorsTests.senderPub.dropLast())) == nil)
        #expect(RelayAuth.decodeKey(Base64s.encodeStd([UInt8](repeating: 0, count: 31)) + "A") == nil)
    }
}

// swiftlint:enable line_length
