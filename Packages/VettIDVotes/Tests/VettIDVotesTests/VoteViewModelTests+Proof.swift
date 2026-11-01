import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVotes

/// The proof, Release and the unlock window of one vote's screen (owner behaviours 1 and 3), of ``VoteViewModelTests``.
extension VoteViewModelTests {
    // MARK: The proof (owner behaviour 3)

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

    /// A second Save always opens the exporter again, even when the first one's evidence was never written.
    @Test func aSecondSaveOpensTheExporterAgain() async {
        let m = await screen(verified())
        m.askProof()
        m.fetchProof()
        await m.settle()
        #expect(m.state.proofReady && m.proofFile != nil)
        m.askProof()
        #expect(!m.state.proofReady && m.proofFile == nil, "reset first, so that the next fetch is a change")
        m.fetchProof()
        await m.settle()
        #expect(m.state.proofReady && m.proofFile != nil)
        #expect(fake.calls.filter { $0 == "evidence:c1/p1" }.count == 2)
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
}
