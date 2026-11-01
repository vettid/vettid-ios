import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVotes

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// One vote's screen (ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes", screens 2 to 7; IOS-PLAN §4.16): the reads, the cast and
/// its prompts, the cast that is never retried and never made while a restore waits, cancellation that stays silent, the
/// proof written only where the member chooses and Release after it, the unlock window notice. Mirrors vettid-android
/// `VoteViewModelTest`.
@MainActor
@Suite struct VoteViewModelTests {
    let fake = FakeVotes()
    let connections = FakeConnections()
    var cast: String { "cast:c1/p1:yes" }

    init() { connections.connections = [Samples.service()] }

    /// The vote [s] listed with its detail, and the screen opened on it.
    func screen(_ s: VoteSummary = Samples.open(), choiceID: String? = nil, serviceBallot: String? = nil) async -> VoteViewModel {
        fake.votes = [s]
        fake.details[s.key] = Samples.detail(s, choiceID: choiceID, serviceBallot: serviceBallot)
        let m = VoteViewModel(key: s.key, repo: fake, connections: connections, now: { Samples.t0 })
        await m.settle()
        return m
    }

    var casts: [String] { fake.calls.filter { $0.hasPrefix("cast:") } }

    // MARK: Reads

    @Test func theVoteIsReadWhenItOpensWithItsPublicSiteCopy() async {
        let m = await screen()
        #expect(fake.calls == ["refresh", "get:c1/p1", "siteCheck:c1/p1"])
        #expect(m.state.loaded && m.state.loadError == nil && m.state.detail?.choices.count == 3)
        #expect(m.state.serviceName == "Example Org" && m.state.summary?.title == "Budget 2027")
    }

    @Test func aVoteTheVaultDoesNotHoldIsGoneAfterTheListWasRead() async {
        fake.votes = []
        let m = VoteViewModel(key: Samples.key, repo: fake, connections: connections)
        await m.settle()
        #expect(m.state.summary == nil && m.state.loaded)
    }

    @Test func aFailedReadIsToldWithItsKindAndReadsAgainOnRetry() async {
        fake.fail["refresh"] = VaultFailure(.network)
        let m = await screen()
        #expect(m.state.loadError?.kind == .network && m.state.loaded)
        m.refresh()
        await m.settle()
        #expect(m.state.loadError == nil && m.state.detail != nil)
    }

    @Test func theAppsHintsAndTheWindowNoticeAreTheRepositorys() async {
        let m = await screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending, reason: "input")))
        fake.hints[Samples.key] = VoteHint(gaveUp: .site, resultsProblem: true)
        fake.windowNotClosed = WindowNotClosed(ttlSeconds: 90)
        #expect(m.state.hint.gaveUp == .site && m.state.hint.resultsProblem)
        #expect(m.state.windowNotClosed == WindowNotClosed(ttlSeconds: 90))
    }

    @Test func aGaveUpCheckLooksAtTheSiteOnce() async {
        _ = await screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .gaveUp)))
        #expect(fake.calls.filter { $0 == "diagnoseGaveUp:c1/p1" }.count == 1)
    }

    // MARK: Cast

    @Test func castNeedsAChoiceAndTheVaultsYes() async {
        let m = await screen()
        m.askCast()
        #expect(m.state.cast == .none && !m.state.canCast)
        m.select("yes")
        #expect(m.state.canCast)
        m.askCast()
        #expect(m.state.cast == .confirm)
        m.dismissCast()
        #expect(m.state.cast == .none && casts.isEmpty)
        // The vault says no: nothing is offered.
        let refused = await screen(Samples.open(canCast: false, cannotCast: "closing"))
        refused.select("yes")
        refused.askCast()
        #expect(refused.state.cast == .none && !refused.state.canCast)
    }

    @Test func aChoiceNotInTheListIsNeverCast() async {
        let m = await screen()
        m.select("maybe")
        #expect(!m.state.canCast)
        m.askCast()
        #expect(m.state.cast == .none && casts.isEmpty)
    }

    /// Owner behaviour 2: nothing is cast while "Is this your vote?" waits, whatever the screen drew.
    @Test func noCastWhileARestoreWaitsForTheMembersAnswer() async {
        let m = await screen(Samples.open(confirmPending: true), serviceBallot: "no")
        m.select("yes")
        #expect(!m.state.canCast && m.state.restoreAsked)
        m.askCast()
        m.confirmCast()
        m.submitPassword()
        #expect(m.state.cast == .none && casts.isEmpty && fake.castPasswords.isEmpty)
        // The vault's list changes under a confirm sheet that was already open: the cast is refused before anything is sent.
        let open = await screen()
        open.select("yes")
        open.askCast()
        fake.votes = [Samples.open(confirmPending: true)]
        open.confirmCast()
        #expect(casts.isEmpty && open.state.cast == .confirm)
    }

    @Test func anOpenWindowCastsAtOnceWithoutAPasswordPrompt() async {
        fake.windowIsOpen = true
        let m = await screen()
        m.select("yes")
        m.askCast()
        m.confirmCast()
        #expect(m.state.cast == .sending)
        await m.settle()
        #expect(casts == [cast] && fake.castPasswords == [nil] && m.state.cast == .none && m.state.selected == nil)
    }

    @Test func aClosedWindowAsksForThePasswordAndSendsTheRequestOnce() async {
        let m = await screen()
        m.select("yes")
        m.askCast()
        m.confirmCast()
        #expect(m.state.cast == .password && casts.isEmpty)
        m.submitPassword()
        #expect(casts.isEmpty, "an empty password sends nothing")
        m.setPassword("correct horse")
        m.submitPassword()
        await m.settle()
        #expect(casts == [cast] && fake.castPasswords == ["correct horse"])
        #expect(m.state.cast == .none && m.state.password.isEmpty, "the password is held only while the request runs")
    }

    @Test func aWrongPasswordStaysInThePromptAndTheAppDoesNotRetry() async {
        let m = await screen()
        m.select("yes")
        m.askCast()
        m.confirmCast()
        fake.fail[cast] = VaultFailure(.badPassword, code: "bad_password")
        m.setPassword("wrong")
        m.submitPassword()
        await m.settle()
        #expect(m.state.cast == .password && m.state.passwordError?.kind == .badPassword && m.state.password.isEmpty)
        #expect(casts.count == 1 && m.state.castProblem == nil)
    }

    @Test func aBackoffHoldsTheConfirmUntilItsEnd() async {
        let m = await screen()
        m.select("yes")
        m.askCast()
        m.confirmCast()
        fake.fail[cast] = VaultFailure(.backoff, code: "backoff", retryAfterSeconds: 30)
        m.setPassword("wrong")
        m.submitPassword()
        await m.settle()
        #expect(m.state.retryUntil == Samples.t0.addingTimeInterval(30))
        m.setPassword("again")
        m.submitPassword()
        await m.settle()
        #expect(casts.count == 1, "no request during the wait")
    }

    @Test func aClosedWindowAfterAllAsksForThePasswordAndNothingIsRetriedByTheApp() async {
        fake.windowIsOpen = true
        let m = await screen()
        m.select("yes")
        m.askCast()
        fake.fail[cast] = VaultFailure(.credentialLocked, code: "credential_locked")
        m.confirmCast()
        await m.settle()
        #expect(m.state.cast == .password && casts.count == 1 && m.state.castProblem == nil)
    }

    /// Owner behaviour 2: no answer is said plainly (the vote may have been sent), offers no retry, and is not retried.
    @Test func noAnswerIsToldAndTheCastIsNeverRetriedByTheApp() async {
        fake.windowIsOpen = true
        let m = await screen()
        m.select("yes")
        m.askCast()
        fake.fail[cast] = VaultFailure(.noResponse)
        m.confirmCast()
        await m.settle()
        #expect(m.state.castProblem?.kind == .noResponse && m.state.cast == .none)
        #expect(casts.count == 1)
        // The vote is read again whatever failed.
        #expect(fake.calls.filter { $0 == "refresh" }.count == 2)
        // Only the member casts again.
        m.dismissCastProblem()
        #expect(m.state.castProblem == nil && casts.count == 1)
    }

    @Test func aRefusalOfTheVaultIsShownWithItsCodeAndTheVoteIsReadAgain() async {
        fake.windowIsOpen = true
        let m = await screen()
        m.select("yes")
        m.askCast()
        fake.fail[cast] = VaultFailure(.other, code: "closing")
        m.confirmCast()
        await m.settle()
        #expect(m.state.castProblem?.code == "closing" && !m.state.alreadyVoted)
        #expect(fake.calls.last == "siteCheck:c1/p1" && fake.calls.filter { $0 == "get:c1/p1" }.count == 2)
    }

    @Test func alreadyVotedIsAnoticeNotAFailureWithTheRecordedChoice() async {
        fake.windowIsOpen = true
        let m = await screen()
        m.select("yes")
        m.askCast()
        fake.fail[cast] = VaultFailure(.other, code: "already_voted")
        // The re-read finds the recorded ballot and its choice.
        fake.onRefresh = { [fake] in
            let s = Samples.open(ballot: VoteBallot(state: .recorded), canCast: false)
            fake.votes = [s]
            fake.details[s.key] = Samples.detail(s, choiceID: "no")
        }
        m.confirmCast()
        await m.settle()
        #expect(m.state.alreadyVoted && m.state.castProblem == nil && m.state.choiceLabel == "No")
        m.dismissAlreadyVoted()
        #expect(!m.state.alreadyVoted)
    }

    @Test func aVoteThatHoldsABallotIsNeverNotSent() async {
        fake.windowIsOpen = true
        let m = await screen()
        m.select("yes")
        m.askCast()
        fake.fail[cast] = VaultFailure(.other, code: "closing")
        fake.onRefresh = { [fake] in fake.votes = [Samples.open(ballot: VoteBallot(state: .waiting), canCast: false)] }
        m.confirmCast()
        await m.settle()
        #expect(m.state.castProblem == nil)
    }

    @Test func aCastGoesToTheConnectionOfThisVoteWhenTwoServicesShareAProposalId() async {
        fake.windowIsOpen = true
        let a = Samples.open("cA", "same")
        let b = Samples.open("cB", "same")
        fake.votes = [a, b]
        fake.details[a.key] = Samples.detail(a)
        fake.details[b.key] = Samples.detail(b)
        let m = VoteViewModel(key: b.key, repo: fake, connections: connections)
        await m.settle()
        m.select("yes")
        m.askCast()
        m.confirmCast()
        await m.settle()
        #expect(casts == ["cast:cB/same:yes"])
    }

    @Test func theAppLeavingDropsThePasswordOnly() async {
        let m = await screen()
        m.select("yes")
        m.askCast()
        m.confirmCast()
        m.setPassword("secret")
        m.forgetSecrets()
        #expect(m.state.password.isEmpty && m.state.cast == .password && m.state.selected == "yes")
    }

    // MARK: Cancellation (owner behaviour 4)

    @Test func aCastCutOffByALockIsSilentAndTheVoteIsReadAgain() async {
        fake.windowIsOpen = true
        let m = await screen()
        m.select("yes")
        m.askCast()
        fake.failError[cast] = CancellationError()
        m.confirmCast()
        await m.settle()
        #expect(m.state.cast == .none && m.state.castProblem == nil && m.state.passwordError == nil && !m.state.alreadyVoted)
        #expect(casts.count == 1, "not sent again")
        #expect(fake.calls.filter { $0 == "refresh" }.count == 2)
    }

    @Test func aReadCutOffIsSilent() async {
        fake.failError["refresh"] = CancellationError()
        let m = await screen()
        #expect(m.state.loadError == nil && m.state.detail == nil)
        fake.failError["get:c1/p1"] = CancellationError()
        m.refresh()
        await m.settle()
        #expect(m.state.loadError == nil)
    }

    @Test func theSiteCheckCutOffIsSilent() async {
        fake.failError["siteCheck:c1/p1"] = CancellationError()
        let m = await screen()
        #expect(m.state.loadError == nil && m.state.castProblem == nil && m.state.checkProblem == nil && m.state.detail != nil)
    }

    @Test func aMembersCheckAgainCutOffIsSilent() async {
        let m = await screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending)))
        fake.failError["checkResults:c1/p1"] = CancellationError()
        m.checkWithService()
        await m.settle()
        #expect(!m.state.checking && m.state.checkProblem == nil && m.state.checkOutcome == nil)
        // The next press works.
        fake.resultsOutcome = .siteUnreachable
        m.checkWithService()
        await m.settle()
        #expect(m.state.checkOutcome == .siteUnreachable)
    }

    @Test func everyOtherRequestCutOffIsSilent() async {
        let m = await screen(Samples.open(ballot: VoteBallot(state: .waiting), canCast: false, confirmPending: true), serviceBallot: "yes")
        fake.failError["check:c1/p1"] = CancellationError()
        m.checkWithService()
        await m.settle()
        fake.failError["confirm:c1/p1:true"] = CancellationError()
        m.answerRestore(mine: true)
        await m.settle()
        fake.failError["evidence:c1/p1"] = CancellationError()
        m.askProof()
        m.fetchProof()
        await m.settle()
        fake.failError["closeWindowNow"] = CancellationError()
        m.closeWindowNow()
        await m.settle()
        let s = m.state
        #expect(s.checkProblem == nil && s.restoreProblem == nil && s.proofProblem == nil && s.windowCloseProblem == nil)
        #expect(!s.checking && !s.restoreBusy && !s.proofBusy && !s.windowClosing && !s.proofReady)
    }

    // MARK: Check, restore

    @Test func checkWithTheServiceAsksTheServiceAndCheckAgainTakesTheResultsForAClosedVote() async {
        let waiting = await screen(Samples.open(ballot: VoteBallot(state: .waiting), canCast: false))
        waiting.checkWithService()
        await waiting.settle()
        #expect(fake.calls.contains("check:c1/p1") && !fake.calls.contains("checkResults:c1/p1"))
        let closed = await screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending)))
        fake.resultsOutcome = .notPublished
        closed.checkWithService()
        await closed.settle()
        #expect(fake.calls.contains("checkResults:c1/p1") && closed.state.checkOutcome == .notPublished)
    }

    @Test func aFailedCheckIsToldWithItsKind() async {
        let m = await screen(Samples.open(ballot: VoteBallot(state: .waiting), canCast: false))
        fake.fail["check:c1/p1"] = VaultFailure(.network)
        m.checkWithService()
        await m.settle()
        #expect(m.state.checkProblem?.kind == .network && !m.state.checking)
    }

    @Test func theRestoreDialogAsksOnlyWhenTheVaultNamedABallot() async {
        let named = await screen(Samples.open(confirmPending: true), serviceBallot: "no")
        #expect(named.state.restoreAsked && named.state.restoreLabel == "No")
        let unnamed = await screen(Samples.open(confirmPending: true))
        #expect(!unnamed.state.restoreAsked)
        named.answerRestore(mine: true)
        await named.settle()
        #expect(fake.calls.contains("confirm:c1/p1:true") && !named.state.restoreBusy)
    }

    // MARK: The proof (owner behaviour 3)

    private func verified() -> VoteSummary { Samples.closed(VoteBallot(state: .conflict)) }

    @Test func theProofIsWrittenUnchangedOnlyWhereTheMemberChooses() async {
        fake.evidenceText = #"{"evidence":{"choice_id":"yes","sig":"abc"}}"#
        let m = await screen(verified())
        m.askProof()
        #expect(m.state.proofWarning && !fake.calls.contains("evidence:c1/p1") && m.proofFile == nil)
        m.fetchProof()
        await m.settle()
        let file = m.proofFile
        #expect(file?.bytes == Data(fake.evidenceText.utf8) && file?.name == "vettid-vote-p1.json")
        #expect(m.state.proofReady && !m.state.proofExported)
        m.proofExporterAnswered(saved: true)
        #expect(m.state.proofSaved && m.state.proofExported && m.proofFile == nil && !m.state.proofReady)
        m.proofShown()
        #expect(!m.state.proofSaved)
    }

    @Test func cancellingTheExporterWritesNothingAndForgetsTheProof() async {
        let m = await screen(verified())
        m.askProof()
        m.fetchProof()
        await m.settle()
        m.proofExporterAnswered(saved: false)
        #expect(m.proofFile == nil && !m.state.proofSaved && !m.state.proofExported && !m.state.proofReady)
        // Release stays out of reach.
        m.askRelease()
        #expect(!m.state.releaseDialog)
        m.release(pin: "123456")
        await m.settle()
        #expect(fake.releasePins.isEmpty)
    }

    @Test func aFailedWriteIsToldAndLeavesNothingBehind() async {
        let m = await screen(verified())
        m.askProof()
        m.fetchProof()
        await m.settle()
        m.proofExporterFailed()
        #expect(m.state.proofSaveFailed && !m.state.proofExported && m.proofFile == nil)
    }

    @Test func aFailedEvidenceRequestIsToldAndNothingIsOffered() async {
        let m = await screen(verified())
        fake.fail["evidence:c1/p1"] = VaultFailure(.network)
        m.askProof()
        m.fetchProof()
        await m.settle()
        #expect(m.state.proofProblem?.kind == .network && !m.state.proofReady && m.proofFile == nil && !m.state.proofBusy)
    }

    @Test func theFileNameIsTheProposalsIdAndNothingElse() async {
        fake.votes = [Samples.open("c1", "p/../1 x")]
        let m = VoteViewModel(key: VoteKey(connectionID: "c1", proposalID: "p/../1 x"), repo: fake, connections: connections)
        #expect(m.proofFileName == "vettid-vote-p1x.json")
        let empty = VoteViewModel(key: VoteKey(connectionID: "c1", proposalID: "//"), repo: fake, connections: connections)
        #expect(empty.proofFileName == "vettid-vote-proof.json")
    }

    // MARK: Release (owner behaviour 3)

    @Test func releaseIsOfferedOnlyAfterTheProofWasSavedAndAsksForThePin() async {
        let m = await screen(verified())
        m.askRelease()
        #expect(!m.state.releaseDialog)
        m.askProof()
        m.fetchProof()
        await m.settle()
        m.askRelease()
        #expect(!m.state.releaseDialog, "not while the exporter is open")
        m.proofExporterAnswered(saved: true)
        m.askRelease()
        #expect(m.state.releaseDialog)
        m.release(pin: "")
        #expect(fake.releasePins.isEmpty)
        m.release(pin: "123456")
        await m.settle()
        #expect(fake.releasePins == ["123456"] && m.state.released && !m.state.releaseDialog)
        m.askRelease()
        #expect(!m.state.releaseDialog)
    }

    @Test func aReleaseTheVaultRefusesIsShown() async {
        let m = await screen(verified())
        m.askProof()
        m.fetchProof()
        await m.settle()
        m.proofExporterAnswered(saved: true)
        m.askRelease()
        fake.fail["release:c1/p1"] = VaultFailure(.badPin, code: "bad_pin")
        m.release(pin: "000000")
        await m.settle()
        #expect(m.state.releaseProblem?.kind == .badPin && m.state.releaseDialog && !m.state.released && !m.state.releaseBusy)
    }

    // MARK: The unlock window (owner behaviour 1)

    @Test func theWindowNoticeIsHeldByTheRepositoryNotTheScreen() async {
        fake.windowNotClosed = WindowNotClosed(ttlSeconds: 600)
        let first = await screen()
        #expect(first.state.windowNotClosed?.ttlSeconds == 600)
        // The screen moved on; another opens on the same vote: the notice is still there.
        let again = VoteViewModel(key: Samples.key, repo: fake, connections: connections)
        await again.settle()
        #expect(again.state.windowNotClosed?.ttlSeconds == 600)
    }

    @Test func closeItNowLocksTheWindowAndClearsTheNoticeOnlyOnSuccess() async {
        fake.windowNotClosed = WindowNotClosed(ttlSeconds: 600)
        let m = await screen()
        fake.fail["closeWindowNow"] = VaultFailure(.network)
        m.closeWindowNow()
        await m.settle()
        #expect(m.state.windowNotClosed != nil && m.state.windowCloseProblem?.kind == .network && !m.state.windowClosing)
        m.closeWindowNow()
        await m.settle()
        #expect(m.state.windowNotClosed == nil && m.state.windowCloseProblem == nil)
    }

    // MARK: Nothing secret in a description

    @Test func theStateShowsNoChoiceNoPasswordAndNoEvidenceWhenPrinted() async {
        fake.evidenceText = #"{"evidence":{"choice_id":"EVIDENCE-MARK"}}"#
        let m = await screen(verified(), choiceID: "CHOICE-MARK")
        m.setPassword("PASSWORD-MARK")
        m.askProof()
        m.fetchProof()
        await m.settle()
        var out = ""
        dump(m.state, to: &out)
        let all = [String(describing: m.state), String(reflecting: m.state), out, String(describing: m.proofFile as Any)].joined()
        for mark in ["CHOICE-MARK", "PASSWORD-MARK", "EVIDENCE-MARK"] { #expect(!all.contains(mark), "\(mark)") }
    }
}
