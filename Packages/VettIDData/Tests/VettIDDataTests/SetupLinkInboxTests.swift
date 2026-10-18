import Testing
import VettIDData

/// The setup link handed from the scene to onboarding (vettid-android `SetupLinkInbox`).
@MainActor
@Suite struct SetupLinkInboxTests {
    @Test func offeredThenConsumed() {
        let inbox = SetupLinkInbox()
        #expect(inbox.link == nil)
        inbox.offer("https://account.vettid.org/vault/enroll/#s=x")
        #expect(inbox.link == "https://account.vettid.org/vault/enroll/#s=x")
        inbox.consume()
        #expect(inbox.link == nil)
    }

    /// The link carries the setup secret: neither `dump` (which would show the macro's storage) nor
    /// `String(reflecting:)` shows it.
    @Test func theLinkIsNeverDumped() {
        let inbox = SetupLinkInbox()
        inbox.offer("https://account.vettid.org/vault/enroll/#s=SECRET123")
        var dumped = ""
        dump(inbox, to: &dumped)
        for text in [dumped, String(reflecting: inbox), "\(inbox)"] {
            #expect(!text.contains("SECRET123") && !text.contains("vault/enroll"), "\(text)")
        }
    }
}
