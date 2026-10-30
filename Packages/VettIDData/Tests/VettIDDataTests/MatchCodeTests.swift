import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// A sign-in's `match_code` (VAULT-MESSAGING 0.79.0 §10.4): kept only when it is a string of exactly 2 or 3 ASCII digits
/// on a `signin` challenge, as written ("07" stays "07"); anything else is ignored, and a code is never read from
/// `context`. Mirrors ANDROID-PLAN 0.1.100's tests.
@Suite struct MatchCodeTests {
    let at = Date(timeIntervalSince1970: 1_791_115_200)

    func code(_ value: String?, purpose: String? = #""signin""#, context: String = "Sign in to VettID Member Service") throws -> String? {
        let p = purpose.map { #","purpose":\#($0)"# } ?? ""
        let m = value.map { #","match_code":\#($0)"# } ?? ""
        let o = try StrictJson.parseObject(#"{"request_id":"a1","connection_id":"c1","context":"\#(context)"\#(p)\#(m),"exp":"2026-10-27T12:10:00.000Z"}"#)
        guard case .authentication(let a)? = ApprovalParser.parse("connection.authenticate.pending", o, at: at) else { throw CocoaError(.featureUnsupported) }
        return a.matchCode
    }

    @Test func aValidCodeOnASignInIsKeptAsWritten() throws {
        #expect(try code(#""42""#) == "42")
        #expect(try code(#""07""#) == "07")
        #expect(try code(#""123""#) == "123" && code(#""000""#) == "000")
    }

    @Test func aMalformedCodeIsIgnored() throws {
        for raw in [#""4""#, #""1234""#, #""4a""#, #"" 42""#, #""42 ""#, #""4 2""#, #""""#, #""-42""#, #""+42""#, #""4.2""#] {
            #expect(try code(raw) == nil, "\(raw)")
        }
        // Other scripts' digits: Arabic-Indic, fullwidth, superscript.
        for raw in ["\"\u{0664}\u{0662}\"", "\"\u{FF14}\u{FF12}\"", "\"\u{2074}\u{00B2}\""] {
            #expect(try code(raw) == nil, "\(raw)")
        }
        // Not a string: a JSON number, null, an array.
        #expect(try code("42") == nil && code("null") == nil && code(#"["42"]"#) == nil)
    }

    /// Only a sign-in carries a code: on an approval, without a purpose or with an unknown one, it is ignored.
    @Test func onlyASignInCarriesACode() throws {
        #expect(try code(#""42""#, purpose: #""approval""#) == nil)
        #expect(try code(#""42""#, purpose: nil) == nil)
        #expect(try code(#""42""#, purpose: #""payment""#) == nil)
    }

    /// A note that names a code is only text: without the field there is no code.
    @Test func aCodeIsNeverTakenFromTheNote() throws {
        #expect(try code(nil, context: "Sign in to VettID Member Service, match code 42") == nil)
        #expect(try code(#""17""#, context: "match code 42") == "17")
    }

    /// The feed's words, which a notification uses, never carry the number: it is for the member who opened the prompt, and a
    /// notification can be read on a locked phone.
    @Test func theFeedNeverCarriesTheCode() {
        var sam = ConnectionInfo(id: "c1", name: "", state: .active)
        sam.firstName = "Sam"
        let coded = PendingApproval.authentication(AuthenticationRequest(requestID: "s1", connectionID: "c1", context: "Sign in", receivedAt: at, exp: nil, purpose: .signin, matchCode: "42"))
        let names = FeedNames(connections: ["c1": sam], approvals: ["auth:s1": coded])
        let item = FeedItem(itemID: "i", seq: 1, kind: "connection.authenticate.requested", at: "2026-10-27T12:00:00Z", status: "active", priority: "high", connectionID: "c1", ref: "s1")
        let texts = [FeedKinds.title(item, names), FeedKinds.title(item, names, details: false), FeedKinds.supporting(item, names) ?? ""]
        #expect(texts[0].hasPrefix("Sign in to"))
        for text in texts { #expect(!text.contains("42"), "\(text)") }
    }
}

// swiftlint:enable line_length
