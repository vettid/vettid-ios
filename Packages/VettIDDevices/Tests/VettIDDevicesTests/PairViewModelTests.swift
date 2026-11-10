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
        m.codesMatch(pairingID: "p1")
        #expect(!m.state.sheet)
        pairing.state = PairingState(stage: .compare(pending))
        await sync(m)
        m.codesMatch(pairingID: "p1")
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
        m.codesMatch(pairingID: "p1")
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
        m.reject(pairingID: "p1")
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
        // An expired code is not acknowledged away first: the repository's start rejects it.
        #expect(pairing.calls == ["start"])
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
        m.codesMatch(pairingID: "p1")
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
        await sync(m)
        m.newCode()
        await sync(m)
        #expect(pairing.calls == ["start:desktop"])
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
        m.codesMatch(pairingID: "p1")
        await sync(m)
        #expect(m.state.sheet)
        m.pair()
        await sync(m)
        // The repository's approve takes the session and nothing else: no grants exist to send.
        #expect(pairing.calls.last == "approve:3600")
        m.reject(pairingID: "p1")
        await sync(m)
        #expect(pairing.calls.last == "reject")
    }

    // MARK: Review fixes

    /// Done on a code being made, a live code or a comparison asks the repository to leave, not left to the model going.
    @Test func doneOnACodeOrAComparisonLeavesTheRepository() async {
        for stage in [PairingStage.code(PairingCode(pairingID: "p1", link: "L", exp: exp)), .compare(pending), .creating] {
            let m = vm()
            pairing.state = PairingState(stage: stage)
            await sync(m)
            pairing.calls = []
            m.done()
            #expect(pairing.calls == ["leave"], "\(stage)")
        }
    }

    /// A sheet opened for an older comparison never approves the new one: Pair is ignored unless it is the comparison now held.
    @Test func aSheetOfAnOlderComparisonCannotApproveTheNewOne() async {
        let m = vm()
        pairing.state = PairingState(stage: .compare(pending))
        await sync(m)
        m.codesMatch(pairingID: "p1")
        await sync(m)
        pairing.state = PairingState(stage: .compare(PendingPairing(pairingID: "p2", name: "Other", sas: "654321", ends: exp)))
        await sync(m)
        pairing.calls = []
        m.pair()
        await sync(m)
        #expect(!pairing.calls.contains { $0.hasPrefix("approve") })
        // Nothing held at all: nothing is approved either.
        pairing.state = PairingState()
        await sync(m)
        m.pair()
        await sync(m)
        #expect(!pairing.calls.contains { $0.hasPrefix("approve") })
    }

    /// A screen released before it saw any state leaves by its owner alone; one that did always leaves its own pairing, whatever
    /// done() or cancel() did (some stages are not ended by them: a code still being made, a comparison with an approval in flight);
    /// it is idempotent for the repository.
    @Test func aScreenReleasedBeforeItsFirstStateStillEndsWhatItStarted() async {
        // Released before its first state, it still ends what it started: by its owner alone.
        var none: PairViewModel? = vm()
        none = nil
        #expect(await eventually { pairing.leftOwners.count == 1 })
        #expect(pairing.leftTokens == [nil])
        pairing.leftOwners = []
        pairing.leftTokens = []

        for stage in [
            PairingStage.creating, .code(PairingCode(pairingID: "p1", link: "L", exp: exp)), .compare(pending),
        ] {
            var m: PairViewModel? = vm()
            var s = PairingState(stage: stage)
            s.token = 5
            pairing.state = s
            await sync(m!)
            m!.done()
            pairing.calls = []
            pairing.leftTokens = []
            m = nil
            #expect(await eventually { pairing.leftTokens == [5] }, "\(stage)")
        }
    }

    /// The token of what the screen saw is what it leaves and acknowledges with, and the approval names the comparison.
    @Test func theScreenLeavesAcknowledgesAndApprovesOnlyWhatItSaw() async {
        let m = vm()
        var s = PairingState(stage: .compare(pending))
        s.token = 9
        pairing.state = s
        await sync(m)
        m.codesMatch(pairingID: "p1")
        await sync(m)
        m.pair()
        await sync(m)
        #expect(pairing.approvedIDs == ["p1"])
        m.cancel()
        #expect(pairing.leftTokens == [9])
        let n = vm()
        s = PairingState(stage: .ended)
        s.token = 11
        pairing.state = s
        await sync(n)
        pairing.calls = []
        n.done()
        #expect(pairing.acknowledgedTokens == [11])
    }

    /// Every screen owns what it shows: its own owner starts a pairing or, from a feed item, takes over the one held, and it leaves and
    /// reads with that owner; the screens' owners differ. The comparison to match or reject is the one shown.
    @Test func everyScreenIsItsOwnOwnerAndNamesWhatItShows() async {
        let a = vm()
        await sync(a)
        let b = vm(held: true)
        await sync(b)
        guard let starter = pairing.owners.first, let claimer = pairing.claimedOwners.first else {
            Issue.record("a screen that starts, and one that takes over, each name their owner")
            return
        }
        #expect(starter != claimer, "each screen has its own owner")
        var s = PairingState(stage: .compare(pending))
        s.token = 3
        pairing.state = s
        await sync(a)
        await sync(b)
        a.cancel()
        b.cancel()
        #expect(pairing.leftOwners == [starter, claimer])
        // The sheet and the rejection are for the comparison shown, never another.
        b.codesMatch(pairingID: "other")
        await sync(b)
        #expect(!b.state.sheet)
        b.reject(pairingID: "p1")
        await sync(b)
        #expect(pairing.rejectedIDs == ["p1"])
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
        pairing.state = PairingState(stage: .code(PairingCode(pairingID: "p1", link: "L", exp: exp)))
        pairing.state.token = 4
        await sync(m!)
        pairing.calls = []
        m = nil
        #expect(await eventually { pairing.calls.contains("leave") })
        // Only the pairing this screen saw.
        #expect(pairing.leftTokens == [4])
    }
}
