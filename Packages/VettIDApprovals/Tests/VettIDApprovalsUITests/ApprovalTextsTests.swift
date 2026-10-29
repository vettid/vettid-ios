import Foundation
import Testing
import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData

// Expected texts stay on one line each.
// swiftlint:disable line_length

/// The Approvals screens' texts: every key of vettid-android's `feature/approvals` `strings.xml` (word for word, under its
/// names), and what each kind of request says in its row and on its decision screen. Free of SwiftUI, so they run on any
/// platform. Mirrors vettid-android's Approvals screen tests' texts.
@Suite struct ApprovalTextsTests {
    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDApprovalsUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 150)
        let missing = "\u{0}missing"
        for key in keys {
            let text = ApprovalsStrings.bundle.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            #expect(key.hasPrefix("approvals_"), "\(key)")
        }
    }

    @Test func theFormattedTextsAreAndroids() {
        #expect(ApprovalsStrings.title == "Approvals" && ApprovalsStrings.emptyTitle == "Nothing to approve")
        #expect(ApprovalsStrings.batchTitle("Sam", 1) == "Sam asks for 1 thing" && ApprovalsStrings.batchTitle("Sam", 3) == "Sam asks for 3 things")
        #expect(ApprovalsStrings.summaryItems(1) == "1 item" && ApprovalsStrings.summaryItems(2) == "2 items")
        #expect(ApprovalsStrings.grantUses(1) == "They can read it once." && ApprovalsStrings.grantUses(3) == "They can read it 3 times.")
        #expect(ApprovalsStrings.grantDays(1) == "1 day" && ApprovalsStrings.grantDays(7) == "7 days")
        #expect(ApprovalsStrings.outgoingBody("Ada") == "You accepted Ada's invitation. Compare this code with Ada: it must match the code on their phone. Both of you approve, then you are connected.")
        #expect(ApprovalsStrings.ruleNameUntil("medical", "Nov 1") == "your “medical” rule (until Nov 1)")
        #expect(ApprovalsStrings.backoff(12) == "Too many wrong passwords. Try again in 12 s")
        #expect(ApprovalsStrings.criticalDoneBody("Sam") == "Your vault used the item once and sent Sam only the result. Nothing else left your vault.")
        #expect(ApprovalsStrings.pausedTitle("Sam") == "Sam’s requests are paused" && ApprovalsStrings.removeTitle("Sam") == "Remove Sam?")
    }

    @Test func eachKindHasItsTitle() {
        #expect(ApprovalTexts.title(.connection(Samples.incoming())) == "Connection request")
        var remote = ConnectionRequest(pendingID: "p", sas: "1", remote: true, name: nil, receivedAt: Date(), exp: nil)
        remote.state = .pending
        #expect(ApprovalTexts.title(.connection(.incoming(remote))) == "Connection request (link)")
        #expect(ApprovalTexts.title(.connection(Samples.outgoing())) == "Your connection request")
        #expect(ApprovalTexts.title(Samples.auth()) == "Authenticate to a connection" && ApprovalTexts.title(Samples.grant()) == "Request to see your items")
        #expect(ApprovalTexts.title(Samples.critical()) == "Use of a critical item" && ApprovalTexts.title(Samples.share()) == "Share with a connection?")
        #expect(ApprovalTexts.title(Samples.device()) == "Request from a device" && ApprovalTexts.title(Samples.device("device.session.pending")) == "Access session request")
    }

    /// The row's parts, each bidi-isolated (§10.8), as ``ApprovalTexts/supporting(_:name:)`` joins them.
    private func row(_ parts: String...) -> String { parts.map(AccountNames.isolate).joined(separator: " · ") }

    /// A challenge's context comes from the other side: its row shows only the first line, and the text cannot reorder
    /// the name beside it.
    @Test func aRowShowsTheContextsFirstLineIsolated() {
        let ctx = PendingApproval.authentication(
            AuthenticationRequest(requestID: "m1", connectionID: "c1", context: "Pay \u{202E}fake\nsecond line", receivedAt: Date(), exp: nil, purpose: .signin)
        )
        #expect(ApprovalTexts.supporting(ctx, name: "Sam Lee") == row("Sam Lee", "Pay \u{202E}fake"))
        #expect(!ApprovalTexts.supporting(ctx, name: "Sam Lee").contains("second line"))
    }

    @Test func aRowSaysWhoAndWhat() {
        #expect(ApprovalTexts.supporting(.connection(Samples.incoming()), name: nil) == row("Ada Lovelace", "code 042817"))
        #expect(ApprovalTexts.supporting(.connection(Samples.incoming(state: .approved)), name: nil) == row("Ada Lovelace", "code 042817 · waiting for them to approve"))
        #expect(ApprovalTexts.supporting(.connection(Samples.outgoing(sas: nil)), name: nil) == row("Grace Hopper", "waiting for their vault"))
        #expect(ApprovalTexts.supporting(Samples.auth(), name: "Sam Lee") == row("Sam Lee", "Sign-in"))
        #expect(ApprovalTexts.supporting(Samples.grant(), name: nil) == row("A connection", "3 items"))
        #expect(ApprovalTexts.supporting(Samples.critical(), name: "Sam Lee") == row("Sam Lee", "Signing key · Seed"))
        #expect(ApprovalTexts.supporting(Samples.share(), name: nil) == row("2 items"))
        #expect(ApprovalTexts.supporting(Samples.device(), name: nil) == row("Laptop", "sign"))
    }

    @Test func aDecisionSaysWhatItDoes() {
        #expect(ApprovalTexts.body(.connection(Samples.incoming()), name: nil) == "\u{2068}Ada Lovelace\u{2069} used your invitation. Compare this code with \u{2068}Ada Lovelace\u{2069}: it must match the code on their phone.")
        #expect(ApprovalTexts.body(.connection(Samples.outgoing(sas: nil)), name: nil) == "Your vault is still setting up a secure session with theirs. The safety code appears here once it is done.")
        #expect(ApprovalTexts.body(.connection(Samples.outgoing()), name: nil)?.hasPrefix("You accepted \u{2068}Grace Hopper\u{2069}'s invitation link.") == true)
        #expect(ApprovalTexts.body(Samples.auth(), name: "Sam Lee") == "\u{2068}Sam Lee\u{2069} asks you to prove it is you. Approving signs their challenge with your credential key.")
        #expect(ApprovalTexts.body(Samples.grant(), name: nil) == "A connection asks to see items from your vault.")
        #expect(ApprovalTexts.body(Samples.share(), name: "Sam Lee") == "A share rule asks whether to share these items with \u{2068}Sam Lee\u{2069}.")
        #expect(ApprovalTexts.body(Samples.device(), name: nil) == "A desktop or agent of yours asks for a decision.")
        #expect(ApprovalTexts.approveLabel(.connection(Samples.incoming())) == "The codes match: connect")
        #expect(ApprovalTexts.approveLabel(.connection(Samples.incoming(state: .approved))) == nil)
        #expect(ApprovalTexts.approveLabel(.connection(Samples.outgoing())) == "The codes match: approve")
        #expect(ApprovalTexts.approveLabel(.connection(Samples.outgoing(sas: nil))) == nil && ApprovalTexts.approveLabel(Samples.device()) == nil)
        #expect(ApprovalTexts.approveLabel(Samples.critical()) == "Allow this one use" && ApprovalTexts.approveLabel(Samples.share()) == "Share the ticked items")
        #expect(ApprovalTexts.denyLabel(Samples.share()) == "Do not share" && ApprovalTexts.denyLabel(Samples.auth()) == "Deny")
    }

    /// VAULT-MESSAGING §10.4 "The screens per purpose" (0.65.0), word for word: a sign-in asks "Sign in to <name>?", warns
    /// and offers "Approve" and "Not me"; an approval says who asks and offers "Approve" and "Deny"; without a purpose, as
    /// before.
    @Test func aChallengeSaysItsPurpose() {
        #expect(ApprovalsStrings.authSigninTitle("Sam Lee") == "Sign in to Sam Lee?")
        #expect(ApprovalsStrings.authSigninBody == "Only approve if you are signing in right now.")
        #expect(ApprovalsStrings.authSigninDeny == "Not me" && ApprovalsStrings.authPurposeApprove == "Approve")
        #expect(ApprovalsStrings.authApprovalTitle("Sam Lee") == "Sam Lee asks you to approve")
        let sam = AccountNames.isolate("Sam Lee")
        let signin = Samples.auth("s1", purpose: .signin), approval = Samples.auth("p1", purpose: .approval)
        #expect(ApprovalTexts.title(signin, name: "Sam Lee") == "Sign in to \(sam)?" && ApprovalTexts.title(signin) == "Sign in to a connection?")
        #expect(ApprovalTexts.body(signin, name: "Sam Lee") == "Only approve if you are signing in right now.")
        #expect(ApprovalTexts.approveLabel(signin) == "Approve" && ApprovalTexts.denyLabel(signin) == "Not me")
        #expect(ApprovalTexts.supporting(signin, name: "Sam Lee") == row("Sam Lee", "Sign-in"))
        #expect(ApprovalTexts.title(approval, name: "Sam Lee") == "\(sam) asks you to approve" && ApprovalTexts.title(approval) == "A connection asks you to approve")
        #expect(ApprovalTexts.body(approval, name: "Sam Lee") == nil && ApprovalTexts.summary(approval) == "Sign-in")
        #expect(ApprovalTexts.approveLabel(approval) == "Approve" && ApprovalTexts.denyLabel(approval) == "Deny")
        // Without a purpose (absent or unknown, read as absent): as before 0.65.0, even with a name.
        let none = Samples.auth()
        #expect(ApprovalTexts.title(none, name: "Sam Lee") == "Authenticate to a connection" && ApprovalTexts.approveLabel(none) == "Authenticate")
        #expect(ApprovalTexts.body(none, name: "Sam Lee") == "\u{2068}Sam Lee\u{2069} asks you to prove it is you. Approving signs their challenge with your credential key.")
        #expect(ApprovalTexts.denyLabel(none) == "Deny")
    }

    @Test func failuresAndResults() {
        let now = Date()
        #expect(ApprovalTexts.failure(.backoff, retryUntil: now.addingTimeInterval(9.2), limit: nil, now: now) == "Too many wrong passwords. Try again in 10 s")
        #expect(ApprovalTexts.failure(.backoff, retryUntil: now.addingTimeInterval(-1), limit: nil, now: now) == "You can try again now")
        #expect(ApprovalTexts.failure(.backoff, retryUntil: nil, limit: nil, now: now) == FailureKind.backoff.message(timeScale: 1))
        let limit = VaultLimit("grants_given", max: 3)
        #expect(ApprovalTexts.failure(.limit, retryUntil: nil, limit: limit, now: now) == limit.message)
        #expect(ApprovalTexts.failure(.network, retryUntil: nil, limit: limit, now: now) == FailureKind.network.message(timeScale: 1))
        #expect(ApprovalTexts.criticalResult("ok", name: nil).title == "Done")
        #expect(ApprovalTexts.criticalResult("unsuitable", name: nil).body.hasPrefix("This field cannot be used this way"))
        #expect(ApprovalTexts.criticalResult("unavailable", name: nil) == ("Not used", "The item or field is no longer available to them. They were told."))
    }

    @Test func grantsSharesAndChoices() {
        #expect(ApprovalTexts.grantEntry(Samples.entry("i1")) == "\u{2068}Passport\u{2069}")
        #expect(ApprovalTexts.grantEntry(Samples.entry("i2", available: false)) == "\u{2068}Their words\u{2069} (not in your vault)")
        #expect(ApprovalTexts.grantEntry(GrantEntry(kind: "category", ref: "health_card", label: nil, available: false)) == "Any Health card item (you choose which)")
        #expect(ApprovalTexts.usesOptions(requested: 3) == [nil, 1, 10] && ApprovalTexts.usesOptions(requested: nil) == [nil, 3, 10])
        #expect(ApprovalTexts.expiryOptions(requested: nil) == [nil, 86_400, 2_592_000])
        #expect(ApprovalTexts.expiryLabel(nil, requested: 3_600) == "1 day" && ApprovalTexts.usesLabel(nil, requested: 3) == "They can read it 3 times.")
        #expect(ApprovalTexts.kind("otp") == "One-time code" && ApprovalTexts.kind("x") == "Other" && ApprovalTexts.operation("auth") == "Sign in (authenticate)")
        guard case .share(var d) = Samples.share() else { return }
        let lines = ShareExplanations.of(d.items[1], d)
        #expect(lines == [.asksFirst(ruleID: "r9"), .alreadyShared] && ShareExplanations.of(d.items[0], d).isEmpty)
        // A rule the question does not know reads "another of your rules"; a known one is named by its tags (§10.12).
        let none: [String: RuleNames.Name] = [:]
        #expect(ApprovalTexts.shareLine(lines[0], in: d, names: none, who: "Sam") == "Also covered by another of your rules, which asks you first")
        #expect(ApprovalTexts.shareLine(lines[1], in: d, names: none, who: "Sam") == "Already shared with Sam by another rule. Not sharing it stops that sharing.")
        d.rules = [ShareRule(ruleID: "r9", connectionID: "c1", tags: ["medical"], mode: .ask), ShareRule(ruleID: "r3", connectionID: "c1", tags: ["id", "travel"], match: .all)]
        let names = RuleNames.of(d.rules)
        #expect(ApprovalTexts.shareLine(lines[0], in: d, names: names, who: "Sam") == "Also covered by your “medical” rule, which asks you first")
        #expect(ApprovalTexts.shareLine(.alsoCovered(ruleID: "r3"), in: d, names: names, who: "Sam") == "Also covered by your “id + travel” rule")
        #expect(ApprovalTexts.peerDeclined(PeerDecline(requestID: "r", name: nil, outgoing: true, at: Date())) == "Someone declined your connection request")
        #expect(ApprovalTexts.peerDeclined(PeerDecline(requestID: "r", name: "Ada", outgoing: false, at: Date())) == "\u{2068}Ada\u{2069} declined the connection")
        #expect(ApprovalTexts.pausedTitle(ConnectionInfo(id: "c", name: "", state: .active)) == "A connection’s requests are paused")
        #expect(ApprovalTexts.batchTitle(asks: 2, name: nil) == "A connection asks for 2 things")
    }

    /// A received name that closes the isolation and reverses what follows (PDI then RLO) is cleaned first (VAULT-MESSAGING
    /// §10.8; mirrors vettid-android #220): the bodies and the batch title hold one isolate and no RLO.
    @Test func aHostileNameCannotReverseTheWordsAroundIt() {
        let hostile = "Bank\u{2069}\u{202E}"
        let safe = "\u{2068}Bank\u{2069}"
        #expect(ApprovalTexts.body(Samples.auth(), name: hostile) == "\(safe) asks you to prove it is you. Approving signs their challenge with your credential key.")
        #expect(ApprovalTexts.body(Samples.grant(), name: hostile) == "\(safe) asks to see items from your vault.")
        #expect(ApprovalTexts.batchTitle(asks: 2, name: hostile) == "\(safe) asks for 2 things")
        #expect(ApprovalTexts.peerDeclined(PeerDecline(requestID: "r", name: hostile, outgoing: false, at: Date())) == "\(safe) declined the connection")
        #expect(ApprovalTexts.peerDeclined(PeerDecline(requestID: "r", name: "\u{2069}\u{202E}", outgoing: false, at: Date())) == "Someone declined the connection")
        for t in [ApprovalTexts.body(Samples.auth(), name: hostile), ApprovalTexts.batchTitle(asks: 2, name: hostile)] {
            #expect(t?.filter { $0 == "\u{2069}" }.count == 1 && t?.contains("\u{202E}") == false)
        }
    }

    /// The sign-in and approval titles: a hostile name keeps one isolate and no override; a name of nothing visible reads
    /// "a connection" (VAULT-MESSAGING §10.8; mirrors vettid-android #220).
    @Test func theChallengeTitlesCleanTheirName() {
        let signin = Samples.auth(purpose: .signin), approval = Samples.auth(purpose: .approval)
        let hostile = "Bank\u{2069}\u{202E}"
        #expect(ApprovalTexts.title(signin, name: hostile) == ApprovalsStrings.authSigninTitle("\u{2068}Bank\u{2069}"))
        #expect(ApprovalTexts.title(approval, name: hostile) == ApprovalsStrings.authApprovalTitle("\u{2068}Bank\u{2069}"))
        for t in [ApprovalTexts.title(signin, name: hostile), ApprovalTexts.title(approval, name: hostile)] {
            #expect(t.filter { $0 == "\u{2069}" }.count == 1 && !t.contains("\u{202E}"))
        }
        let invisible = "\u{200B}\u{202E}"
        #expect(ApprovalTexts.title(signin, name: invisible) == ApprovalsStrings.authSigninTitle(ApprovalsStrings.aConnectionInline))
        #expect(ApprovalTexts.title(approval, name: invisible) == ApprovalsStrings.authApprovalTitle(ApprovalsStrings.aConnection))
    }
}

// swiftlint:enable line_length
