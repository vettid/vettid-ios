import Foundation
import Testing
@testable import VettIDData

/// The locks heard of during a read (``LocksHeard/since(_:after:)``): counted by event as well as by time.
struct LocksHeardTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func heard(_ times: Date...) -> LocksHeard {
        var h = LocksHeard()
        for at in times { h.note(at) }
        return h
    }

    /// A lock heard after the vault's clock stepped back is not the newest by time, and still counts when it is after the
    /// read's start.
    @Test func aLockAfterAStepBackOfTheVaultsClockCounts() {
        let before = heard(t)
        let after = heard(t, t.addingTimeInterval(-10))
        #expect(after.latest == before.latest)
        #expect(after.since(before, after: t.addingTimeInterval(-20)))
    }

    /// An old lock heard during the read (a mailbox's) does not make a lock heard before it count.
    @Test func anOldLockDoesNotMakeAnEarlierOneCount() {
        let start = t
        let before = heard(start.addingTimeInterval(-600))
        let after = heard(start.addingTimeInterval(-600), start.addingTimeInterval(-2 * 86_400))
        #expect(!after.since(before, after: start.addingTimeInterval(-3_600)))
    }

    /// The newest by time counts even when an older one was heard after it.
    @Test func theNewestCountsWhateverCameAfter() {
        let before = heard()
        let after = heard(t, t.addingTimeInterval(-86_400))
        #expect(after.since(before, after: t.addingTimeInterval(-60)))
        #expect(!after.since(after, after: t.addingTimeInterval(-60)), "nothing heard since")
    }
}
