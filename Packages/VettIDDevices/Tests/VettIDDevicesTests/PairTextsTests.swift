import Foundation
import Testing
@testable import VettIDData
@testable import VettIDDevices

// The texts are long literal rows, one per line.
// swiftlint:disable line_length

/// What each step of pairing an agent (ANDROID-PLAN 0.1.53 AA2) and a desktop (vettid-android #291) says and offers: the title, the body
/// and the two buttons, for the agent's words and the desktop's. The screens take their words from ``PairTexts``. Mirrors the text and button
/// checks of vettid-android `PairScreenTest`.
@MainActor
@Suite struct PairTextsTests {
    let exp = Samples.now.addingTimeInterval(600)
    let code = PairingCode(pairingID: "p1", link: "L", exp: Samples.now.addingTimeInterval(600))

    func pending(_ sas: String? = "123456", name: String = "Claude on laptop") -> PendingPairing {
        PendingPairing(pairingID: "p1", name: name, sas: sas, ends: Samples.now.addingTimeInterval(600))
    }

    func state(_ stage: PairingStage, desktop: Bool = false, change: (inout PairState) -> Void = { _ in }) -> PairState {
        var s = PairState()
        s.pairing = PairingState(stage: stage, role: desktop ? .desktop : .agent)
        change(&s)
        return s
    }

    func step(_ stage: PairingStage, desktop: Bool = false, change: (inout PairState) -> Void = { _ in }) -> PairStep {
        PairTexts.step(state(stage, desktop: desktop, change: change))
    }

    // MARK: The code

    @Test func theCodeScreenSaysWhatToDoWithTheCodeAndOffersOnlyCancel() {
        let agent = step(.code(code))
        #expect(agent.title == "Pair an agent")
        #expect(agent.body == "Copy this code to the computer where the agent runs. It works once and expires in 10 minutes.")
        #expect(agent.primary == nil && agent.secondary == "Cancel")
        let desktop = step(.code(code), desktop: true)
        #expect(desktop.title == "Pair a desktop")
        #expect(desktop.body == "Copy this code into VettID on your computer. It works once and expires in 10 minutes.")
        #expect(desktop.primary == nil && desktop.secondary == "Cancel")
    }

    @Test func anExpiredCodeSaysSoAndOffersANewOne() {
        let agent = step(.codeExpired(pairingID: "p1", exp: exp))
        #expect(agent.title == "Pair an agent" && agent.body == "This code expired.")
        #expect(agent.primary == "New code" && agent.secondary == "Cancel")
        #expect(step(.codeExpired(pairingID: "p1", exp: exp), desktop: true).title == "Pair a desktop")
    }

    @Test func aCodeThatCouldNotBeMadeSaysSoPlainly() {
        let s = step(.idle) { $0.pairing.error = .network }
        #expect(s.title == "Pair an agent" && s.body == "A pairing code could not be made. Try again.")
        #expect(s.primary == "Try again" && s.secondary == "Cancel")
        #expect(step(.idle, desktop: true) { $0.pairing.error = .network }.title == "Pair a desktop")
    }

    /// The daily check is due: the vault's own words (the screen adds them, with **Check now**), not "could not be made".
    @Test func aDueDailyCheckOffersTheCheckInsteadOfThePlainFailure() {
        let s = step(.idle) { $0.pairing.error = .ownerCheckRequired }
        #expect(s.body == nil && s.primary == "Try again")
        #expect(DeviceStrings.pairCheckNow == "Check now" && !FailureKind.ownerCheckRequired.message.isEmpty)
    }

    @Test func nothingYetIsJustTheTitle() {
        let s = step(.creating)
        #expect(s.title == "Pair an agent" && s.body == nil && s.primary == nil && s.secondary == nil)
        #expect(step(.idle).title == "Pair an agent" && step(.idle, desktop: true).title == "Pair a desktop")
    }

    // MARK: The comparison

    @Test func theComparisonSaysTheDigitsInTwoGroupsTheNameAndOffersBothAnswers() {
        let s = step(.compare(pending()))
        #expect(s.title == "Compare the code" && s.primary == "The codes match" && s.secondary == "They don't match" && !s.destructive)
        #expect(PairTexts.compareBody(sas: "123456", desktop: false) == "Does the agent show 123 456? Approve only if the codes match.")
        #expect(PairTexts.callsItself("Claude on laptop", desktop: false) == "It calls itself \u{2068}Claude on laptop\u{2069}.")
        #expect(PairTexts.callsItselfNote(desktop: false)
            == "The code proves this phone talks to the agent you just gave the code to. The name is only what the agent says about itself.")
    }

    @Test func theDesktopComparisonNamesTheDesktopAndHasBothAnswers() {
        let s = step(.compare(pending(name: "Work laptop")), desktop: true)
        #expect(s.title == "Compare the code" && s.primary == "The codes match" && s.secondary == "They don't match")
        #expect(PairTexts.compareBody(sas: "654321", desktop: true) == "Does the desktop show 654 321? Approve only if the codes match.")
        #expect(PairTexts.callsItself("Work laptop", desktop: true) == "It calls itself \u{2068}Work laptop\u{2069}.")
        #expect(PairTexts.callsItselfNote(desktop: true)
            == "The code proves this phone talks to the desktop you just gave the code to. The name is only what the desktop says about itself.")
        // Never "agent" in the desktop's words.
        for text in [PairTexts.compareBody(sas: "654321", desktop: true), PairTexts.callsItselfNote(desktop: true), PairTexts.allowBody(desktop: true)] {
            #expect(!text.lowercased().contains("agent"), "\(text)")
        }
    }

    /// A device that gave no name is "an agent" or "a desktop", never an empty "It calls itself ."; one that could pass for the phone or for
    /// VettID is shown with its role.
    @Test func aNameThatIsMissingOrCouldPassForThePhoneOrVettIdIsSaidPlainly() {
        #expect(PairTexts.callsItself("", desktop: false) == "It calls itself an agent.")
        #expect(PairTexts.callsItself("", desktop: true) == "It calls itself a desktop.")
        #expect(PairTexts.callsItself("This phone", desktop: false) == "It calls itself \u{2068}This phone (Agent)\u{2069}.")
        #expect(PairTexts.callsItself("VettID", desktop: true) == "It calls itself \u{2068}VettID (Desktop)\u{2069}.")
        #expect(PairTexts.callsItself("This\u{00A0}phone", desktop: false) == "It calls itself \u{2068}This\u{00A0}phone (Agent)\u{2069}.")
    }

    /// A pairing that cannot be compared (no six digits, or not this role's) offers only **Reject**, in the error colour.
    @Test func aPairingThatCannotBeComparedOffersOnlyReject() {
        for desktop in [false, true] {
            let s = step(.compare(pending(nil)), desktop: desktop)
            #expect(s.primary == "Reject" && s.secondary == nil && s.destructive)
        }
        #expect(DeviceStrings.pairCannotCompare == "This phone can't show a code to compare for this pairing, so it can't be approved. Reject it.")
    }

    // MARK: The sheet

    @Test func theSheetOffersTheAccessLengthsWithOneHourPreselected() {
        #expect(SessionChoice.allCases.map(PairTexts.label) == ["No access yet", "15 minutes", "1 hour", "4 hours", "8 hours", "24 hours"])
        #expect(PairState().session == .hour1)
        #expect(PairTexts.allowBody(desktop: false) == "Agents act only while you allow access, and only within the permissions you give them.")
        #expect(PairTexts.allowBody(desktop: true) == "A desktop acts only while you allow access.")
        #expect(DeviceStrings.pairAllowTitle == "Allow access now?" && DeviceStrings.pairConfirm == "Pair")
    }

    // MARK: The end

    @Test func rejectedSaysTheAgentIsToldOrThatTheVaultCouldNotBe() {
        let told = step(.rejected(told: true))
        #expect(told.title == "Pairing rejected" && told.primary == "Done" && told.secondary == nil)
        #expect(told.body == "The agent is told it was rejected. If you did not expect a code, someone else may have the pairing code; it no longer works.")
        let desktop = step(.rejected(told: true), desktop: true)
        #expect(desktop.body == "The desktop is told it was rejected. If you did not expect a code, someone else may have the pairing code; it no longer works.")
        // The vault could not be told: nothing is paired, and it ends by itself; the same for both roles.
        let unsent = "Nothing is paired. Your vault could not be told, so the pairing ends by itself within 10 minutes. If you did not expect a code, someone else may have the pairing code."
        #expect(step(.rejected(told: false)).body == unsent && step(.rejected(told: false), desktop: true).body == unsent)
    }

    @Test func pairedNamesTheAgentAndOffersItsPageOnlyWhenItsIdIsKnown() {
        let known = step(.paired(name: "Claude on laptop", deviceID: "a1"))
        #expect(known.title == "\u{2068}Claude on laptop\u{2069} is paired" && known.body == "It can't use any of your items yet.")
        #expect(known.primary == "Done" && known.secondary == "Open its page")
        // Without the new agent's id there is no page to open: the list stays where the member left it.
        let unknown = step(.paired(name: "Claude on laptop", deviceID: nil))
        #expect(unknown.primary == "Done" && unknown.secondary == nil)
    }

    /// A desktop gets no rules or permissions: it asks for access sessions, which come to Approvals. Nothing to choose, and no page.
    @Test func pairedDesktopOffersNoChoiceOfWhatItMayUse() {
        for id in ["d1", nil] as [String?] {
            let s = step(.paired(name: "Work laptop", deviceID: id), desktop: true)
            #expect(s.title == "\u{2068}Work laptop\u{2069} is paired" && s.body == "When it asks for access, the request comes to Approvals.")
            #expect(s.primary == "Done" && s.secondary == nil)
        }
    }

    @Test func aPairedTitleWithNoNameStartsWithACapital() {
        #expect(step(.paired(name: "", deviceID: nil)).title == "\u{2068}An agent\u{2069} is paired")
        #expect(step(.paired(name: "", deviceID: nil), desktop: true).title == "\u{2068}A desktop\u{2069} is paired")
    }

    @Test func anEndedPairingSaysNothingWasPaired() {
        for desktop in [false, true] {
            let s = step(.ended, desktop: desktop) { $0.pairing.error = .vaultCode("x") }
            #expect(s.title == "Not paired" && s.body == "This pairing has ended. Start again from Devices & agents." && s.primary == "Done")
        }
    }

    /// No answer from the vault asserts nothing: not "Not paired", but that it was not confirmed, naming the device the way the pairing did.
    @Test func noAnswerFromTheVaultSaysItWasNotConfirmedAndNamesThatDevice() {
        let agent = step(.ended) { $0.pairing.unknownOutcome = true; $0.pairing.agentName = "Claude on laptop" }
        #expect(agent.title == "Pairing not confirmed")
        #expect(agent.body == "Your vault did not answer. If \u{2068}Claude on laptop\u{2069} is listed in Devices & agents, it was paired; if not, start again.")
        let desktop = step(.ended, desktop: true) { $0.pairing.unknownOutcome = true; $0.pairing.agentName = "Work laptop" }
        #expect(desktop.body == "Your vault did not answer. If \u{2068}Work laptop\u{2069} is listed in Devices & agents, it was paired; if not, start again.")
        // A device that gave no name: "an agent" / "a desktop", and never the other role's word.
        let none = step(.ended, desktop: true) { $0.pairing.unknownOutcome = true; $0.pairing.agentName = "" }
        #expect(none.body == "Your vault did not answer. If a desktop is listed in Devices & agents, it was paired; if not, start again.")
        let noName = step(.ended) { $0.pairing.unknownOutcome = true }
        #expect(noName.body?.contains("If an agent is listed") == true)
    }

    @Test func aPairingTheLockTookAwayIsInterruptedWithNewCodeAndCancel() {
        for desktop in [false, true] {
            let s = step(.idle, desktop: desktop) { $0.interrupted = true }
            #expect(s.title == "Not paired" && s.body == "This pairing has ended. Start again from Devices & agents.")
            #expect(s.primary == "New code" && s.secondary == "Cancel")
        }
    }

    /// A feed item with nothing held (the process ended since): it cannot be checked, and nothing is paired.
    @Test func aFeedItemWithNothingHeldSaysItCannotBeChecked() {
        let s = step(.idle) { $0.held = true }
        #expect(s.title == "A device asks to pair" && s.primary == "Done" && s.secondary == nil)
        #expect(s.body == "This pairing can't be checked on this phone any more. Let it expire: it ends by itself within 10 minutes and nothing is paired. If you want to pair, start again.")
    }

    /// An interruption outranks a failed code, and a failed code outranks "held".
    @Test func theOrderOfWhatAnEmptyStateMeans() {
        #expect(step(.idle) { $0.interrupted = true; $0.held = true }.title == "Not paired")
        #expect(step(.idle) { $0.pairing.error = .network; $0.held = true }.title == "Pair an agent")
        #expect(step(.idle) { $0.held = true }.title == "A device asks to pair")
    }

    /// The code screen announces the minutes left once a minute, singular and plural.
    @Test func theMinutesLeftHaveASingularAndAPlural() {
        #expect(DeviceStrings.pairMinutesLeft(1) == "1 minute left" && DeviceStrings.pairMinutesLeft(9) == "9 minutes left")
        #expect(DeviceStrings.pairExpiresIn("9:41") == "Expires in 9:41")
    }
}
// swiftlint:enable line_length
