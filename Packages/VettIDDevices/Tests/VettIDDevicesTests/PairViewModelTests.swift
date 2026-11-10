import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDDevices

/// Pairing an agent (ANDROID-PLAN 0.1.53 AA2) and a desktop (vettid-android #291): what the screen adds to the pairing: the sheet that
/// belongs to its comparison, the first access, a new code for the role shown, and a pairing that leaves with the screen. Mirrors
/// vettid-android `PairViewModelTest`.
@MainActor
@Suite(.serialized) struct PairViewModelTests {
    let pairing = FakePairing()
    let exp = Samples.now.addingTimeInterval(600)
    var pending: PendingPairing { PendingPairing(pairingID: "p1", name: "Claude", sas: "123456", ends: exp) }

    func vm(held: Bool = false, desktop: Bool = false, owner: FakeVaultRepository? = nil) -> PairViewModel {
        PairViewModel(held: held, desktop: desktop, repo: pairing, ownerChecks: owner)
    }

    /// Lets the model work out what the repository said (it follows it on the main actor) and what it started.
    func sync(_ m: PairViewModel) async {
        for _ in 0..<30 { await Task.yield() }
        await m.settle()
        for _ in 0..<30 { await Task.yield() }
    }

    @Test func theButtonOpensANewCodeAndAFeedItemOpensWhatIsHeld() async {
        let m = vm()
        await sync(m)
        #expect(pairing.calls == ["acknowledge", "start"])
        pairing.calls = []
        let held = vm(held: true)
        await sync(held)
        // Never a new code from a feed item.
        #expect(pairing.calls.isEmpty)
        #expect(held.state.held)
    }

    @Test func theSheetOpensOnlyOverAComparisonAndPairsWithTheChosenAccess() async {
        let m = vm()
        await sync(m)
        m.codesMatch()
        #expect(!m.state.sheet)
        pairing.state = PairingState(stage: .compare(pending))
        await sync(m)
        m.codesMatch()
        await sync(m)
        #expect(m.state.sheet)
        // One hour is preselected (decision 5).
        #expect(m.state.session == .hour1)
        m.pair()
        await sync(m)
        #expect(pairing.calls.last == "approve:3600")
        m.choose(.none)
        m.pair()
        await sync(m)
        #expect(pairing.calls.last == "approve:nil")
    }

    @Test func everyChoiceIsAWholeNumberOfSecondsTheVaultTakes() {
        #expect(SessionChoice.allCases.map(\.seconds) == [nil, 900, 3_600, 14_400, 28_800, 86_400])
        #expect(SessionChoice.allCases.compactMap(\.seconds).allSatisfy { (60...86_400).contains($0) })
    }

    @Test func theSheetClosesWhenThePairingMovesOnButStaysForADailyCheck() async {
        let m = vm()
        pairing.state = PairingState(stage: .compare(pending))
        await sync(m)
        m.codesMatch()
        pairing.state = PairingState(stage: .compare(pending), error: .ownerCheckRequired)
        await sync(m)
        #expect(m.state.sheet)
        pairing.state = PairingState(stage: .paired(name: "Claude", deviceID: nil))
        await sync(m)
        #expect(!m.state.sheet)
    }

    @Test func theyDontMatchRejectsAndCancelAndLeavingLeaveTheVaultTold() async {
        let m = vm()
        pairing.state = PairingState(stage: .compare(pending))
        await sync(m)
        m.reject()
        await sync(m)
        #expect(pairing.calls.contains("reject"))
        pairing.calls = []
        m.cancel()
        #expect(pairing.calls == ["leave"])
    }

    @Test func aNewCodeAfterExpiryStartsAgain() async {
        let m = vm()
        pairing.state = PairingState(stage: .codeExpired(pairingID: "p1", exp: exp))
        await sync(m)
        pairing.calls = []
        m.copied()
        #expect(m.state.copied)
        m.newCode()
        await sync(m)
        #expect(pairing.calls == ["acknowledge", "start"])
        #expect(!m.state.copied)
    }

    @Test func theDailyCheckPassingClearsARefusedApproval() async {
        let owner = FakeVaultRepository()
        owner.ownerCheck = OwnerCheckView(state: .due, deadline: nil, hold: false)
        let m = vm(held: true, owner: owner)
        await sync(m)
        pairing.state = PairingState(stage: .compare(pending), error: .ownerCheckRequired)
        await sync(m)
        #expect(m.state.pairing.error == .ownerCheckRequired)
        #expect(!pairing.calls.contains("acknowledge"))
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: false)
        await sync(m)
        // The refused approval may be sent again: the repository is told the check passed.
        #expect(pairing.calls.contains("acknowledge"))
    }

    @Test func aPassedCheckClearsNothingWhenNoApprovalWasRefused() async {
        let owner = FakeVaultRepository()
        owner.ownerCheck = OwnerCheckView(state: .due, deadline: nil, hold: false)
        let m = vm(held: true, owner: owner)
        pairing.state = PairingState(stage: .compare(pending), error: .network)
        await sync(m)
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: false)
        await sync(m)
        #expect(!pairing.calls.contains("acknowledge"))
    }

    @Test func aPairingTheLockTookAwayIsInterruptedNotAnEndlessSpinner() async {
        let m = vm()
        await sync(m)
        // Before anything was shown, nothing to interrupt.
        #expect(!m.state.interrupted)
        pairing.state = PairingState(stage: .code(PairingCode(pairingID: "p1", link: "L", exp: exp)))
        await sync(m)
        #expect(!m.state.interrupted)
        // clear(): back to nothing, without an error and not busy.
        pairing.state = PairingState()
        await sync(m)
        #expect(m.state.interrupted)
        // Leaving by the member's own answer is not an interruption.
        m.done()
        await sync(m)
        #expect(!m.state.interrupted)
    }

    @Test func theSheetBelongsToTheComparisonItWasOpenedFor() async {
        let m = vm()
        pairing.state = PairingState(stage: .compare(pending))
        await sync(m)
        m.codesMatch()
        await sync(m)
        #expect(m.state.sheet)
        // Another pairing's comparison does not open with it.
        pairing.state = PairingState(stage: .compare(PendingPairing(pairingID: "p2", name: "Other", sas: "654321", ends: exp)))
        await sync(m)
        #expect(!m.state.sheet)
    }

    @Test func aCodeNeverReachesATextForm() async {
        let code = PairingCode(pairingID: "p", link: "SECRETLINKVALUE", exp: exp)
        #expect(!"\(code)".contains("SECRETLINKVALUE") && !String(reflecting: code).contains("SECRETLINKVALUE"))
        #expect(!"\(pending)".contains("123456"))
        // Nor does the screen's state, which holds the code, the digits and the name.
        let m = vm()
        pairing.state = PairingState(stage: .code(code))
        await sync(m)
        var dumped = ""
        dump(m.state, to: &dumped)
        for text in ["\(m.state)", dumped, String(reflecting: m.state)] { #expect(!text.contains("SECRETLINKVALUE")) }
    }

    // MARK: A desktop (vettid-android #291)

    @Test func thePairADesktopButtonStartsADesktopPairingAndNewCodeKeepsTheRole() async {
        let m = vm(desktop: true)
        await sync(m)
        #expect(pairing.calls == ["acknowledge", "start:desktop"])
        #expect(pairing.state.role == .desktop)
        pairing.calls = []
        pairing.state = PairingState(stage: .codeExpired(pairingID: "p1", exp: exp), role: .desktop)
        m.newCode()
        await sync(m)
        #expect(pairing.calls == ["acknowledge", "start:desktop"])
    }

    @Test func aPairingHeldForTheOtherRoleIsReplacedByTheRepositoryInOneCall() async {
        pairing.state = PairingState(stage: .code(PairingCode(pairingID: "p1", link: "x", exp: exp)), role: .agent)
        let m = vm(desktop: true)
        await sync(m)
        // No cancel then start from the screen: the repository switches in `start`.
        #expect(pairing.calls == ["acknowledge", "start:desktop"])
    }

    @Test func newCodeAfterALockKeepsTheDesktopRoleOfTheRoute() async {
        let m = vm(desktop: true)
        await sync(m)
        pairing.state = PairingState(stage: .code(PairingCode(pairingID: "p1", link: "x", exp: exp)), role: .desktop)
        await sync(m)
        // The lock clears the repository: nothing, and the role of nothing is the agent's.
        pairing.state = PairingState()
        await sync(m)
        // The screen still says what it showed.
        #expect(m.state.pairing.role == .desktop)
        #expect(m.state.interrupted)
        pairing.calls = []
        m.newCode()
        await sync(m)
        #expect(pairing.calls == ["acknowledge", "start:desktop"])
    }

    @Test func newCodeOnAHeldScreenKeepsTheRoleItLastShowed() async {
        let m = vm(held: true)
        pairing.state = PairingState(stage: .compare(pending), role: .desktop)
        await sync(m)
        pairing.state = PairingState()
        await sync(m)
        pairing.calls = []
        m.newCode()
        await sync(m)
        #expect(pairing.calls == ["acknowledge", "start:desktop"])
        // And an agent's held pairing starts an agent's.
        let agent = vm(held: true)
        pairing.state = PairingState(stage: .compare(pending), role: .agent)
        await sync(agent)
        pairing.state = PairingState()
        await sync(agent)
        pairing.calls = []
        agent.newCode()
        await sync(agent)
        #expect(pairing.calls == ["acknowledge", "start"])
    }

    @Test func aDesktopApprovalSendsTheChosenSessionOnlyAndTheMismatchRejects() async {
        let m = vm(desktop: true)
        pairing.state = PairingState(stage: .compare(pending), role: .desktop)
        await sync(m)
        m.codesMatch()
        await sync(m)
        #expect(m.state.sheet)
        m.pair()
        await sync(m)
        // The repository's approve takes the session and nothing else: no grants exist to send.
        #expect(pairing.calls.last == "approve:3600")
        m.reject()
        await sync(m)
        #expect(pairing.calls.last == "reject")
    }

    // MARK: Leaving (iOS)

    /// Leaving an expired code by Back tells the vault (the code may still be answered for a minute): it is rejected first, never
    /// acknowledged away before that.
    @Test func leavingAnExpiredCodeRejectsItBeforeAnythingIsAcknowledged() async {
        let m = vm()
        pairing.state = PairingState(stage: .codeExpired(pairingID: "p1", exp: exp))
        await sync(m)
        pairing.calls = []
        m.done()
        #expect(pairing.calls == ["leave"])
        var other: PairViewModel? = vm(held: true)
        await sync(other!)
        pairing.calls = []
        other = nil
        #expect(await eventually { pairing.calls == ["leave"] })
    }

    /// A pairing that succeeded, or was rejected or ended, is only read: nothing is rejected.
    @Test func readingAFinalStageRejectsNothing() async {
        for stage in [
            PairingStage.paired(name: "Claude", deviceID: "a1"), .rejected(told: true), .ended,
        ] {
            let m = vm()
            pairing.state = PairingState(stage: stage)
            await sync(m)
            pairing.calls = []
            m.done()
            #expect(pairing.calls == ["acknowledge"], "\(stage)")
        }
    }

    /// The screen going, however it goes, rejects a pairing not approved: an abandoned pairing grants nothing (vettid-android's
    /// `onCleared`).
    @Test func theScreenGoingLeavesAndAcknowledgesTheRepository() async {
        var m: PairViewModel? = vm()
        await sync(m!)
        pairing.calls = []
        m = nil
        #expect(await eventually { pairing.calls == ["leave", "acknowledge"] })
    }
}
