import Foundation
import Testing
@testable import VettIDData

/// When the update is required (owner decision 2026-11-17), over the same fake operations.
extension ReleaseUpdateManagerTests {
    /// Required (owner decision 2026-11-17): from the opening until the manifest is read (checking), then while an offer for
    /// the release the vault is on is listed (behind); a change of behind is told once.
    @Test func requiredFromTheOpeningWhileAnOfferForTheVaultsReleaseIsListed() async {
        let ops = Ops()
        let m = manager(ops)
        var told: [Bool] = []
        m.onBehindChange = { told.append($0) }
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

    /// A new opening ends the retries of the one before: its own read decides.
    @Test func anOpeningEndsTheRetriesOfTheOneBefore() async {
        let ops = Ops()
        let m = manager(ops)
        m.vaultOpened()
        ops.offerFailures = 1
        await m.refreshOffer()
        #expect(m.checking)
        m.clear()
        #expect(!m.checking && !m.required)
    }
}
