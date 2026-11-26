import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData

// Texts stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.116 AA5 (and 0.1.137 AA8's "Referred again" and "Refused or expired", for the ops AA5 has): an agent's held
/// request says what it asks in vettid-android's words, each name isolated. Mirrors vettid-android `DeviceAsksScreenTest`'s texts.
@Suite struct HeldTextsTests {
    private func request(role: String = "agent", name: String? = "Bot", exp: Date? = nil) -> PendingApproval {
        .device(DeviceRequest(type: "approval.pending", id: "h1", deviceName: name, role: role, receivedAt: Date(), exp: exp, deviceID: "A"))
    }

    private func iso(_ s: String) -> String { AccountNames.isolate(s) }

    @Test func eachShowHasItsTitleAndBody() {
        let a = request()
        let bot = iso("Bot")
        let use = HeldShow.use(item: "GitHub", field: "Token", data: .text("x"), bytes: 1)
        #expect(ApprovalTexts.title(a, held: use) == "\(bot) wants to use \(iso("GitHub")) without seeing it")
        #expect(ApprovalTexts.body(a, name: nil, held: use) == "Field: \(iso("Token")). Your vault uses the value for the agent and gives it only the result. For a short or guessable value, such as a PIN or a common password, the agent could work the value out from that result.")
        let get = HeldShow.get(item: "GitHub", fields: ["Token"])
        #expect(ApprovalTexts.title(a, held: get) == "\(bot) wants to see \(iso("GitHub"))" && ApprovalTexts.body(a, name: nil, held: get) == nil)
        #expect(ApprovalTexts.title(a, held: .catalog) == "\(bot) wants to list the items it may use")
        #expect(ApprovalTexts.body(a, name: nil, held: .catalog) == "It sees their names and field labels, never their values.")
        #expect(ApprovalTexts.title(a, held: .noItem(use: true, loading: false)) == "\(bot) wants to use an item you no longer have without seeing it")
        #expect(ApprovalTexts.title(a, held: .noItem(use: false, loading: false)) == "\(bot) wants to see an item you no longer have")
        #expect(ApprovalTexts.title(a, held: .noItem(use: false, loading: true)) == "\(bot) wants to see Loading…")
        #expect(ApprovalTexts.body(a, name: nil, held: .noItem(use: false, loading: false)) == "This phone can't find that item or field any more, so you can only deny the request.")
        #expect(ApprovalTexts.body(a, name: nil, held: .noItem(use: false, loading: true)) == "Loading…")
        #expect(ApprovalTexts.title(a, held: .other) == "\(bot) asks to approve a request" && ApprovalTexts.title(a, held: .desktop) == "\(bot) asks to approve a request")
        #expect(ApprovalTexts.body(a, name: nil, held: .desktop) == "Desktop requests can't be shown in this version of VettID, so you can only deny them.")
        #expect(ApprovalTexts.body(a, name: nil, held: .other) == "This version of VettID can't show this request, so you can only deny it.")
        // A run with a `cwd` waiting on its rule (chosen; not in the spec, for the owner's approval), and one whose settings carry
        // folders.
        #expect(ApprovalTexts.cwdLine(.checking) == "Checking where this may run…" && ApprovalTexts.cwdLine(.failed) == "This can't be shown yet. Try again.")
        #expect(ApprovalTexts.cwdLine(.notAllowed) == "This version of VettID can't show this request, so you can only deny it.")
        // The item list could not be read: neither "an item you no longer have" nor "Loading…".
        #expect(ApprovalTexts.title(a, held: .itemsUnread) == ApprovalTexts.title(a, held: .other))
        #expect(ApprovalTexts.body(a, name: nil, held: .itemsUnread) == "Your items could not be read, so this phone can't say what the request is about. Until they are read, you can only deny it.")
    }

    @Test func aRequestWithoutANameIsNamedByItsKind() {
        #expect(ApprovalTexts.title(request(name: nil), held: .catalog) == "An agent wants to list the items it may use")
        #expect(ApprovalTexts.title(request(role: "desktop", name: nil), held: .other) == "A desktop asks to approve a request")
    }

    @Test func theRowSaysTheKindAndHowLongItWaits() {
        let now = Date(timeIntervalSince1970: 1_791_115_200)
        func line(_ role: String, _ seconds: TimeInterval?) -> String {
            guard case .device(let d) = request(role: role, exp: seconds.map { now.addingTimeInterval($0) }) else { return "" }
            return ApprovalTexts.heldSupporting(d, now: now)
        }
        #expect(line("agent", 4 * 60 + 30) == "Agent · Waiting for 4 more minutes")
        #expect(line("agent", 60) == "Agent · Waiting for 1 more minute")
        #expect(line("desktop", 59) == "Desktop · Waiting for less than a minute")
        #expect(line("agent", -5) == "Agent · Waiting for less than a minute")
        #expect(line("other", nil) == "Device" && line("Agent", nil) == "Agent")
    }

    @Test func aDecisionIsSaidAsAndroidSaysIt() {
        let who = "Bot"
        func say(_ o: DeviceOutcome) -> String { ApprovalTexts.outcome(o, who: who) }
        #expect(say(.denied) == "Denied" && say(.noLongerWaiting) == "This request is no longer waiting.")
        #expect(say(.approved(result: "ok")) == "Approved" && say(.approved(result: "not_found")) == "Approved, but your vault answered: \(iso("not_found")).", "a result, not the error")
        #expect(say(.approved(result: nil)) == "Your vault didn't say whether it was done.")
        #expect(say(.approved(result: "forbidden")) == "Approved, but Bot no longer has a permission that covers it, or is paused, so nothing was done.")
        #expect(say(.approved(result: "session_required")) == "Approved, but Bot's access ended first, so nothing was done." && say(.approved(result: "denied")) == say(.approved(result: "session_required")))
        #expect(say(.approved(result: "way_not_allowed")) == "Approved, but this item no longer allows that, so nothing was done.")
        #expect(say(.approved(result: "x")) == "Approved, but your vault answered: \(iso("x")).")
        // A code from the vault is cleaned and cut, never shown as it came.
        let long = say(.approved(result: String(repeating: "a", count: 100) + "\u{202E}"))
        #expect(!long.contains("\u{202E}") && long.contains(String(repeating: "a", count: 64)) && !long.contains(String(repeating: "a", count: 65)))
    }

    @Test func theDetailsOfAHeldRequestAreIsolatedAndNeverTheAgentsOwnLine() {
        // An agent's name that tries to end the sentence early: isolated, so it cannot reorder what is around it.
        let a = request(name: "Bot \u{202E}evil")
        #expect(!ApprovalTexts.title(a, held: .catalog).contains("\u{202E}"))
        #expect(ApprovalTexts.title(a, held: .catalog).hasSuffix("wants to list the items it may use"))
    }
}

// swiftlint:enable line_length
