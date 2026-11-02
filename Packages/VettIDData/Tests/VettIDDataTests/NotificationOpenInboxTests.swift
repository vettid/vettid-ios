import Testing
@testable import VettIDData

/// A tapped notification's item waits in the inbox until the shell takes it; a wait for the item only ends, it never
/// takes the tap (the shell decides again, with what is in front then).
@MainActor
struct NotificationOpenInboxTests {
    @Test func oneWaitPerTapAndItsEndAsksForANewDecision() throws {
        let taps = NotificationOpenInbox()
        #expect(taps.startWaiting() == nil, "nothing tapped")
        taps.offer("f1")
        let token = try #require(taps.startWaiting())
        #expect(taps.startWaiting() == nil && taps.isWaiting(token), "one wait")
        taps.waitEnded(token)
        #expect(taps.itemID == "f1" && taps.waitOver && !taps.isWaiting(token), "the tap stays until the shell takes it")
        #expect(taps.startWaiting() == nil, "no second wait once it is over")
        taps.consume()
        #expect(taps.itemID == nil && !taps.waitOver)
    }

    @Test func anotherTapReplacesTheWaitAndTheOldWaitsEndIsIgnored() throws {
        let taps = NotificationOpenInbox()
        taps.offer("f1")
        let old = try #require(taps.startWaiting())
        taps.offer("f2")
        #expect(!taps.isWaiting(old))
        taps.waitEnded(old)
        #expect(taps.itemID == "f2" && !taps.waitOver)
        let new = try #require(taps.startWaiting())
        taps.waitEnded(new)
        #expect(taps.waitOver)
    }

    @Test func theSameItemTappedAgainKeepsItsWait() throws {
        let taps = NotificationOpenInbox()
        taps.offer("f1")
        let token = try #require(taps.startWaiting())
        taps.offer("f1")
        taps.waitEnded(token)
        #expect(taps.waitOver)
    }

    @Test func aWaitEndedAfterTheTapWasTakenChangesNothing() throws {
        let taps = NotificationOpenInbox()
        taps.offer("f1")
        let token = try #require(taps.startWaiting())
        taps.consume()
        taps.waitEnded(token)
        #expect(taps.itemID == nil && !taps.waitOver)
    }

    /// The shell left and came back while the first wait still runs: only the new wait's end counts.
    @Test func aShellThatLeftWaitsAgainAndTheEarlierWaitCannotEndIt() throws {
        let taps = NotificationOpenInbox()
        taps.offer("f1")
        let first = try #require(taps.startWaiting())
        taps.rearm()
        let second = try #require(taps.startWaiting())
        #expect(!taps.isWaiting(first) && taps.isWaiting(second))
        taps.waitEnded(first)
        #expect(taps.itemID == "f1" && !taps.waitOver, "the earlier wait's end is ignored")
        taps.waitEnded(second)
        #expect(taps.waitOver)
    }
}
