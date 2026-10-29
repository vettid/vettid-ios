import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDVault

// Fixtures and expected texts stay on one line each.
// swiftlint:disable line_length

/// A member-authentication challenge's `purpose` (VAULT-MESSAGING §10.4, 0.65.0): read from
/// `connection.authenticate.pending` (`signin`, `approval`, absent, and any other value as absent), kept with the stored
/// event, and the feed's title and second line per purpose, word for word.
@Suite struct AuthenticationPurposeTests {
    let at = Date(timeIntervalSince1970: 1_791_115_200)

    func parsed(_ purpose: String?) throws -> AuthenticationRequest {
        let member = purpose.map { #","purpose":\#($0)"# } ?? ""
        let o = try StrictJson.parseObject(#"{"request_id":"a1","connection_id":"c1","context":"example.org, Firefox on Linux"\#(member),"exp":"2026-10-27T12:10:00.000Z"}"#)
        guard case .authentication(let a)? = ApprovalParser.parse("connection.authenticate.pending", o, at: at) else { throw CocoaError(.featureUnsupported) }
        return a
    }

    @Test func thePurposeIsRead() throws {
        let signin = try parsed(#""signin""#)
        #expect(signin.purpose == .signin && signin.requestID == "a1" && signin.connectionID == "c1" && signin.context == "example.org, Firefox on Linux")
        #expect(try parsed(#""approval""#).purpose == .approval)
    }

    /// Absent, or any other value: a challenge as before 0.65.0.
    @Test func anAbsentOrUnknownPurposeIsNone() throws {
        #expect(try parsed(nil).purpose == .absent)
        #expect(try parsed(#""payment""#).purpose == .absent)
        #expect(try parsed(#""SIGNIN""#).purpose == .absent && parsed(#""""#).purpose == .absent)
        #expect(try parsed("7").purpose == .absent && parsed("null").purpose == .absent)
        #expect(AuthenticationPurpose.of(nil) == .absent && AuthenticationPurpose.of("signin") == .signin && AuthenticationPurpose.of("approval") == .approval)
    }

    static let names: FeedNames = {
        var sam = ConnectionInfo(id: "c1", name: "", state: .active)
        sam.firstName = "Sam"
        sam.lastName = "Lee"
        let unnamed = ConnectionInfo(id: "c2", name: "", state: .active)
        let auth = { (id: String, conn: String, p: AuthenticationPurpose) in
            PendingApproval.authentication(AuthenticationRequest(requestID: id, connectionID: conn, context: "Sign in", receivedAt: Date(), exp: nil, purpose: p))
        }
        return FeedNames(
            connections: ["c1": sam, "c2": unnamed],
            approvals: ["auth:s1": auth("s1", "c1", .signin), "auth:p1": auth("p1", "c1", .approval), "auth:n1": auth("n1", "c1", .absent), "auth:s2": auth("s2", "c2", .signin), "auth:p2": auth("p2", "c2", .approval),
                        "auth:s3": auth("s3", "c3", .signin), "auth:p3": auth("p3", "c3", .approval)]
        )
    }()

    static func item(_ ref: String, connection: String = "c1", count: Int? = nil) -> FeedItem {
        var i = FeedItem(itemID: "i", seq: 1, kind: "connection.authenticate.requested", at: "2026-10-27T12:00:00Z", status: "active", priority: "high", connectionID: connection, ref: ref)
        i.count = count
        return i
    }

    /// The feed's (and so a notification's) words per purpose, the name bidi-isolated (§10.8); the vault's item carries no
    /// purpose, so one whose approval is gone reads as before.
    @Test func theFeedSaysThePurpose() {
        let title = { (ref: String) in FeedKinds.title(Self.item(ref), Self.names) }
        let line = { (ref: String) in FeedKinds.supporting(Self.item(ref), Self.names) }
        let sam = AccountNames.isolate("Sam Lee")
        #expect(title("s1") == "Sign in to \(sam)?" && line("s1") == "Only approve if you are signing in right now.")
        #expect(title("p1") == "\(sam) asks you to approve" && line("p1") == nil)
        #expect(title("n1") == "\u{2068}Sam Lee\u{2069} asks you to confirm it is you" && line("n1") == nil)
        #expect(title("gone") == "\u{2068}Sam Lee\u{2069} asks you to confirm it is you" && line("gone") == nil)
        #expect(FeedKinds.title(Self.item("s1"), Self.names, details: false) == "Sign in to \(sam)?")
    }

    /// A connection without a name, or one no longer listed: "a connection" for either purpose, never "Sign in to A
    /// connection?" and never one purpose naming a removed connection when the other does not.
    @Test func aMissingNameFallsBack() {
        #expect(FeedKinds.title(Self.item("s2", connection: "c2"), Self.names) == "Sign in to a connection?")
        #expect(FeedKinds.title(Self.item("p2", connection: "c2"), Self.names) == "A connection asks you to approve")
        #expect(FeedKinds.title(Self.item("s3", connection: "c3"), Self.names) == "Sign in to a connection?")
        #expect(FeedKinds.title(Self.item("p3", connection: "c3"), Self.names) == "A connection asks you to approve")
    }

    /// A §10.4.1 batch led by a challenge says how many asks, whatever the first one's purpose.
    @Test func aBatchLedByASignInIsABatch() {
        for ref in ["s1", "p1", "n1"] {
            let batch = Self.item(ref, count: 3)
            #expect(FeedKinds.title(batch, Self.names) == "\u{2068}Sam\u{2069} asks for 3 things", "\(ref)")
            #expect(FeedKinds.supporting(batch, Self.names) == "3 things", "\(ref)")
        }
    }

    /// The purpose is read only from a pending approval of the item's own connection.
    @Test func anotherConnectionsApprovalGivesNoPurpose() {
        #expect(FeedKinds.authenticationPurpose(Self.item("s1"), Self.names) == .signin)
        #expect(FeedKinds.authenticationPurpose(Self.item("s1", connection: "c2"), Self.names) == .absent)
        #expect(FeedKinds.title(Self.item("s1", connection: "c2"), Self.names) == "A connection asks you to confirm it is you")
        #expect(FeedKinds.supporting(Self.item("s1", connection: "c2"), Self.names) == nil)
    }

    @Test func theTextsAreTheSpecs() {
        #expect(DataStrings.feedAuthenticateSignin("Sam") == "Sign in to Sam?")
        #expect(DataStrings.feedAuthenticateSigninBody == "Only approve if you are signing in right now.")
        #expect(DataStrings.feedAuthenticateApproval("Sam") == "Sam asks you to approve" && DataStrings.feedAConnectionInline == "a connection")
    }
}

// swiftlint:enable line_length
