import Testing
@testable import VettIDData

/// A tapped notification's item waits in the inbox until the shell takes it; a wait for the item only ends, it never
/// takes the tap (the shell decides again, with what is in front then).
@MainActor
struct NotificationOpenInboxTests {
    @Test func oneWaitPerTapAndItsEndAsksForANewDecision() {
        let taps = NotificationOpenInbox()
        #expect(!taps.startWaiting(), "nothing tapped")
        taps.offer("f1")
        #expect(taps.startWaiting() && !taps.startWaiting(), "one wait")
        taps.waitEnded(for: "f1")
        #expect(taps.itemID == "f1" && taps.waitOver, "the tap stays until the shell takes it")
        #expect(!taps.startWaiting(), "no second wait once it is over")
        taps.consume()
        #expect(taps.itemID == nil && !taps.waitOver)
    }

    @Test func anotherTapReplacesTheWaitAndTheOldWaitsEndIsIgnored() {
        let taps = NotificationOpenInbox()
        taps.offer("f1")
        _ = taps.startWaiting()
        taps.offer("f2")
        taps.waitEnded(for: "f1")
        #expect(taps.itemID == "f2" && !taps.waitOver)
        #expect(taps.startWaiting())
        taps.waitEnded(for: "f2")
        #expect(taps.waitOver)
    }

    @Test func theSameItemTappedAgainKeepsItsWait() {
        let taps = NotificationOpenInbox()
        taps.offer("f1")
        _ = taps.startWaiting()
        taps.offer("f1")
        taps.waitEnded(for: "f1")
        #expect(taps.waitOver)
    }

    @Test func aWaitEndedAfterTheTapWasTakenChangesNothing() {
        let taps = NotificationOpenInbox()
        taps.offer("f1")
        _ = taps.startWaiting()
        taps.consume()
        taps.waitEnded(for: "f1")
        #expect(taps.itemID == nil && !taps.waitOver)
    }

    @Test func aShellThatLeftWaitsAgainForTheItem() {
        let taps = NotificationOpenInbox()
        taps.offer("f1")
        _ = taps.startWaiting()
        taps.rearm()
        taps.waitEnded(for: "f1")
        #expect(taps.itemID == "f1" && !taps.waitOver, "the old wait's end is ignored")
        #expect(taps.startWaiting())
        taps.waitEnded(for: "f1")
        #expect(taps.waitOver)
    }
}
