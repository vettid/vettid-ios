import Foundation
import Testing
@testable import VettIDData

/// The check after an opening as it ends, and a foreground read after it passed, over the same fake operations.
extension ReleaseUpdateManagerTests {
    /// An opening tells nothing (it reads its lists itself): a vault that moved since the last offer is recorded as no longer
    /// held, and no lift is told for it afterwards either.
    @Test func anOpeningTellsNothing() async {
        let ops = Ops()
        let m = manager(ops)
        var told: [Bool] = []
        m.onHoldsChange = { told.append($0) }
        ops.offerValue = offer
        await m.refreshOffer()
        #expect(m.behind && told == [true])
        // The update's own unlock: the vault on another release now.
        ops.release = 5
        m.vaultOpened()
        #expect(!m.holdsFeatures && told == [true], "not told by the opening")
        ops.offerValue = nil
        await m.refreshOffer()
        #expect(!m.checking && told == [true], "nor afterwards: nothing was held since the opening")
    }

    /// A check that passes at once tells its end (the site's work starts then); one that failed first tells the lift only.
    @Test func aCheckThatNeverFailedTellsItsEnd() async {
        let ops = Ops()
        let m = manager(ops)
        var ended = 0
        var told: [Bool] = []
        m.onCheckEnded = { ended += 1 }
        m.onHoldsChange = { told.append($0) }
        m.vaultOpened()
        await m.refreshOffer()
        #expect(!m.checking && ended == 1 && told.isEmpty)
        m.vaultOpened()
        ops.offerFailures = 1
        await m.refreshOffer()
        #expect(await eventually { !m.checking })
        #expect(ended == 1 && told == [true, false])
    }

    /// A manifest that no longer verifies after this opening's check passed (its signature, an older serial), or that no
    /// longer checks the vault's release: held as the first check is (the checking screen with what failed), and read again
    /// until it answers.
    @Test(arguments: [
        VaultFailure(.manifest), VaultFailure(.other, code: ReleaseUpdateManager.codeReleaseUnchecked), VaultFailure(.other),
    ])
    func aManifestThatNoLongerVerifiesHoldsAgain(_ failure: VaultFailure) async {
        let ops = Ops()
        let m = manager(ops)
        var told: [Bool] = []
        m.onHoldsChange = { told.append($0) }
        m.vaultOpened()
        await m.refreshOffer()
        #expect(!m.required)
        ops.offerFailure = failure
        ops.offerFailures = 2
        await m.refreshOffer()
        #expect(m.checking && m.required && m.holdsFeatures)
        #expect(m.checkFailure == failure.kind)
        #expect(await eventually { !m.checking })
        #expect(!m.required && told == [true, false])
    }

    /// A foreground read that cannot reach the manifest after the check passed keeps the last verified answer.
    @Test func aReadThatCannotReachTheManifestKeepsTheLastAnswer() async {
        let ops = Ops()
        let m = manager(ops)
        m.vaultOpened()
        await m.refreshOffer()
        for failure in ReleaseUpdateManager.unreachable.map({ VaultFailure($0) }) {
            ops.offerFailure = failure
            ops.offerFailures = 1
            await m.refreshOffer()
            #expect(!m.checking && !m.required && m.checkFailure == nil)
        }
    }

    /// Try again that answers while a retry waits for its next read ends the check and its retry: a later failure that holds
    /// again is read again by a retry of its own.
    @Test func aTryAgainDuringARetrysWaitLeavesLaterRetriesTheirOwn() async {
        let ops = Ops()
        let m = ReleaseUpdateManager(ops: ops) { _ in try await Task.sleep(for: .milliseconds(200)) }
        m.vaultOpened()
        ops.offerFailures = 1
        await m.refreshOffer()
        #expect(m.checking && m.checkFailed)
        // Try again, during the retry's wait (once it has begun).
        try? await Task.sleep(for: .milliseconds(50))
        await m.refreshOffer()
        #expect(!m.checking)
        try? await Task.sleep(for: .milliseconds(400))
        // A foreground read that no longer verifies: held again, and read again until it does.
        ops.offerFailure = VaultFailure(.manifest)
        ops.offerFailures = 1
        await m.refreshOffer()
        #expect(m.checking)
        #expect(await eventually { !m.checking }, "its own retry reads again")
    }

    /// Try again that answers while a retry's read is still in flight: the check ends, and the retry's failure, answering
    /// after it, sets nothing.
    @Test func aTryAgainThatAnswersDuringARetryEndsTheCheck() async {
        let ops = Ops()
        let m = manager(ops)
        m.vaultOpened()
        ops.failingReads = [1, 2]
        ops.duringRead = { [m, ops] in
            guard ops.reads == 2 else { return }
            // The member's Try again, answering before the retry's read does.
            await m.refreshOffer()
        }
        await m.refreshOffer()
        #expect(await eventually { ops.reads >= 3 && !m.checking })
        ops.duringRead = nil
        #expect(m.checkFailure == nil && !m.required && !m.holdsFeatures)
    }
}
