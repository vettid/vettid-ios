import Foundation
import Testing
@testable import VettID

/// A URL the app was opened with goes where it belongs (IOS-PLAN §6.8): an invitation by the Universal Link of
/// `relay.vettid.org` or by `vettid://connect` to the invitation inbox, the portal's setup link to onboarding, anything
/// else to the files; nothing over 4,096 bytes is taken.
struct OpenedLinkTests {
    let link = String(repeating: "A", count: 120)

    @Test func invitationsGoToTheInviteInbox() throws {
        for s in [
            "https://relay.vettid.org/connect#\(link)", "https://relay.vettid.org/connect/#\(link)", "vettid://connect#\(link)",
            "https://my-relay.example/connect#\(link)",
        ] {
            #expect(OpenedLink.route(try #require(URL(string: s))) == .invite(s), "\(s.prefix(40))")
        }
    }

    @Test func theSetupLinkGoesToOnboarding() throws {
        let s = "https://account.vettid.org/vault/enroll/#s=ABCDEFGH"
        #expect(OpenedLink.route(try #require(URL(string: s))) == .setup(s))
    }

    @Test func otherAndOverlongUrlsAreNotLinks() throws {
        let long = "https://relay.vettid.org/connect#" + String(repeating: "A", count: OpenedLink.maxLength)
        for s in ["https://relay.vettid.org/other#\(link)", "file:///tmp/manifest.json", long] {
            #expect(OpenedLink.route(try #require(URL(string: s))) == .other)
        }
    }
}
