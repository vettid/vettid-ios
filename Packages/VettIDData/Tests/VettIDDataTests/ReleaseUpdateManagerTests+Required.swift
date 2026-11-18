import Foundation
import Testing
@testable import VettIDData

/// When the update is required (owner decision 2026-11-17), over the same fake operations.
extension ReleaseUpdateManagerTests {
    /// Required (owner decision 2026-11-17): from the opening until the manifest is read (checking), then while an offer for
    /// the release the vault is on is listed (behind); a change of the features held is told once.
    @Test func requiredFromTheOpeningWhileAnOfferForTheVaultsReleaseIsListed() async {
        let ops = Ops()
        let m = manager(ops)
        var told: [Bool] = []
        m.onHoldsChange = { told.append($0) }
        #expect(!m.required)
        m.vaultOpened()
        #expect(m.required && m.checking && !m.behind)
        ops.offerValue = offer
        await m.refreshOffer()
        #expect(m.required && m.behind && !m.checking)
        ops.offerValue = nil
        await m.refreshOffer()
        #expect(!m.required && !m.behind)
        #expect(told == [true, false])
    }

    /// An offer read before the vault moved (its current release is not the vault's now) counts for nothing, also when a
    /// later read fails and leaves it.
    @Test func anOfferForAnEarlierReleaseIsNotRequired() async {
        let ops = Ops()
        let m = manager(ops)
        ops.offerValue = offer
        await m.refreshOffer()
        #expect(m.required)
        ops.release = 5
        // A read that fails outside a check keeps the old offer, which gates nothing.
        ops.offerFailures = 1
        await m.refreshOffer()
        #expect(m.offer == offer && !m.checking)
        #expect(!m.required && !m.behind)
        // Nor after an opening whose read answers with it.
        m.vaultOpened()
        await m.refreshOffer()
        #expect(!m.checking && !m.required && !m.behind)
    }

    /// Fail closed (owner decision 2026-11-17): a manifest that cannot be read after the opening keeps the check, and it is
    /// read again after 2, 5 and 15 seconds, until a read answers.
    @Test func aFailedCheckIsKeptAndReadAgainWithABackoff() async {
        let ops = Ops()
        let sleeps = Sleeps()
        let m = manager(ops, sleeps)
        m.vaultOpened()
        ops.offerFailures = 3
        await m.refreshOffer()
        #expect(m.checking && m.required, "kept after a failed read")
        #expect(await eventually { !m.checking })
        #expect(!m.required && sleeps.all == [2, 5, 15])
    }

    /// A clear (a wipe) ends the retries.
    @Test func aClearEndsTheRetries() async {
        let ops = Ops()
        let m = manager(ops)
        m.vaultOpened()
        ops.offerFailures = 1
        await m.refreshOffer()
        #expect(m.checking)
        m.clear()
        #expect(!m.checking && !m.required)
    }

    /// While a check whose read failed goes on, the features are held (told), and released once a read answers.
    @Test func aFailedCheckHoldsTheFeaturesUntilARead() async {
        let ops = Ops()
        let m = manager(ops)
        var told: [Bool] = []
        m.onHoldsChange = { told.append($0) }
        m.vaultOpened()
        #expect(!m.holdsFeatures, "a check that has not failed runs the opening's reads")
        ops.offerFailures = 1
        await m.refreshOffer()
        #expect(m.checkFailed && m.holdsFeatures)
        #expect(m.checkFailure == .network, "what failed, for the checking screen")
        #expect(await eventually { !m.checking })
        #expect(!m.holdsFeatures && !m.checkFailed)
        #expect(told == [true, false])
    }

    /// A lock (the vault no longer open) ends the check and its retries: nothing is read for a vault that is not open.
    @Test func aCloseEndsTheCheckAndItsRetries() async {
        let ops = Ops()
        let m = manager(ops)
        m.vaultOpened()
        ops.offerFailures = 100
        await m.refreshOffer()
        #expect(m.checking && m.checkFailed)
        m.vaultClosed()
        #expect(!m.checking && !m.required && !m.holdsFeatures)
        let reads = ops.reads
        await Task.yield()
        for _ in 0..<50 { await Task.yield() }
        #expect(ops.reads == reads, "no read after the close")
    }

    /// A read begun before an opening does not end that opening's check: its own read decides.
    @Test func aReadInFlightAcrossAnOpeningDoesNotEndItsCheck() async {
        let ops = Ops()
        let m = manager(ops)
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        ops.duringRead = { for await _ in gate { return } }
        let early = Task { await m.refreshOffer() }
        #expect(await eventually { ops.reads == 1 })
        m.vaultOpened()
        open.yield()
        await early.value
        #expect(m.checking, "the earlier read leaves the new check")
        ops.duringRead = nil
        await m.refreshOffer()
        #expect(!m.checking)
    }
}
