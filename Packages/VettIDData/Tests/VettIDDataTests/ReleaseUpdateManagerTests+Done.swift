import Foundation
import Testing
@testable import VettIDData

/// The offer when the update is done: only an offer the update reached goes. Mirrors vettid-android "the update done drops
/// only an offer it reached" (`offerGone`).
extension ReleaseUpdateManagerTests {
    /// The update to 5 is done: its own offer goes. A newer offer read by the opening on the new release (5 → 6) stays
    /// through "Continue", so the gate still holds the vault that is behind again.
    @Test func doneDropsOnlyAnOfferTheUpdateReached() async {
        let ops = Ops()
        ops.results = [.moved, .opened]
        ops.offerValue = offer
        let m = manager(ops)
        await m.refreshOffer()
        #expect(m.start(pin: "246802", offer: offer))
        await m.settle()
        #expect(m.progress?.step == .done && m.offer == nil, "the update's own offer goes")

        // The opening on release 5 reads the manifest: 6 is offered now.
        ops.release = 5
        let newer = ReleaseUpdateOffer(current: Self.rel(5, "deprecated"), target: Self.rel(6))
        ops.offerValue = newer
        await m.refreshOffer()
        #expect(m.offer == newer)
        m.finish()
        #expect(m.progress == nil)
        #expect(m.offer == newer, "a newer offer is kept at Continue")
        #expect(m.required, "the vault is behind again")
    }

    /// An offer for a release past the update's target, already known when the update ends, is kept at done too.
    @Test func aNewerOfferKnownBeforeTheEndIsKept() async {
        let ops = Ops()
        ops.results = [.moved, .opened]
        let newer = ReleaseUpdateOffer(current: Self.rel(4, "deprecated"), target: Self.rel(6))
        ops.offerValue = newer
        let m = manager(ops)
        await m.refreshOffer()
        #expect(m.start(pin: "246802", offer: offer))
        await m.settle()
        #expect(m.progress?.step == .done)
        #expect(m.offer == newer, "6 is past the update's 5")
        ops.release = 5
        m.finish()
        #expect(m.offer == newer)
        // Read while the vault was on 4, it gates nothing on 5 until a read for 5 (``ReleaseUpdateManager/behind``), as the
        // opening's own read on the new release does in the test above.
        #expect(!m.behind && !m.required)
    }

    /// An offer for a release below the update's target is stale: it goes at Done.
    @Test func anOlderOfferGoesAtDone() async {
        let ops = Ops()
        ops.results = [.moved, .opened]
        let older = ReleaseUpdateOffer(current: Self.rel(3, "deprecated"), target: Self.rel(4))
        ops.offerValue = older
        let m = manager(ops)
        await m.refreshOffer()
        #expect(m.offer == older)
        #expect(m.start(pin: "246802", offer: offer))
        await m.settle()
        #expect(m.progress?.step == .done && m.offer == nil, "4 is below the update's 5")
        ops.release = 5
        m.finish()
        #expect(m.offer == nil && !m.behind)
    }
}
