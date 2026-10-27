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
        let auth = { (id: String, p: AuthenticationPurpose) in
            PendingApproval.authentication(AuthenticationRequest(requestID: id, connectionID: "c1", context: "Sign in", receivedAt: Date(), exp: nil, purpose: p))
        }
        return FeedNames(connections: ["c1": sam], approvals: ["auth:s1": auth("s1", .signin), "auth:p1": auth("p1", .approval), "auth:n1": auth("n1", .absent)])
    }()

    static func item(_ ref: String) -> FeedItem {
        FeedItem(itemID: "i", seq: 1, kind: "connection.authenticate.requested", at: "2026-10-27T12:00:00Z", status: "active", priority: "high", connectionID: "c1", ref: ref)
    }

    /// The feed's (and so a notification's) words per purpose; the vault's item carries no purpose, so one whose
    /// approval is gone reads as before.
    @Test func theFeedSaysThePurpose() {
        let title = { (ref: String) in FeedKinds.title(Self.item(ref), Self.names) }
        let line = { (ref: String) in FeedKinds.supporting(Self.item(ref), Self.names) }
        #expect(title("s1") == "Sign in to Sam Lee?" && line("s1") == "Only approve if you are signing in right now.")
        #expect(title("p1") == "Sam Lee asks you to approve" && line("p1") == nil)
        #expect(title("n1") == "Sam Lee asks you to confirm it is you" && line("n1") == nil)
        #expect(title("gone") == "Sam Lee asks you to confirm it is you" && line("gone") == nil)
        #expect(FeedKinds.title(Self.item("s1"), Self.names, details: false) == "Sign in to Sam Lee?")
        // A sign-in is never presented as urgent (§10.4): the vault makes its item `high`, not `urgent`.
        #expect(!FeedKinds.urgent(Self.item("s1")))
    }

    @Test func theTextsAreTheSpecs() {
        #expect(DataStrings.feedAuthenticateSignin("Sam") == "Sign in to Sam?")
        #expect(DataStrings.feedAuthenticateSigninBody == "Only approve if you are signing in right now.")
        #expect(DataStrings.feedAuthenticateApproval("Sam") == "Sam asks you to approve")
    }
}

// swiftlint:enable line_length
