import Foundation
import Testing
@testable import VettIDData

/// A countdown shows what is left of the wait, not the ticks counted (a suspended app returns to the real remainder).
@Suite struct WaitDeadlineTests {
    @Test func aTickTakesOffOneSecondAtLeast() {
        let now = ContinuousClock.now
        let d = WaitDeadline(seconds: 30, now: now)
        // A clock that has not moved (virtual ticks) still counts down.
        #expect(d.left(after: 30, now: now) == 29)
        #expect(d.left(after: 1, now: now) == 0)
        #expect(d.left(after: 0, now: now) == 0)
    }

    @Test func aLongSuspensionShowsTheRealRemainder() {
        let start = ContinuousClock.now
        let d = WaitDeadline(seconds: 300, now: start)
        #expect(d.left(after: 299, now: start.advanced(by: .seconds(250))) == 50)
        #expect(d.left(after: 299, now: start.advanced(by: .seconds(400))) == 0)
        // Part of a second left counts as a second.
        #expect(d.left(after: 299, now: start.advanced(by: .milliseconds(299_500))) == 1)
    }
}
