import Foundation
import Testing
import VettIDData
@testable import VettIDNotify

@Test func packageBuilds() {
    #expect(VettIDNotify.name == "VettIDNotify")
}

/// Release L (VAULT-MESSAGING §3.6.8): the idle lock's notification, with the time computed. Mirrors vettid-android
/// `FeedNotifierTest` `anIdleLockSaysTheVaultLockedItself` and `durationsAreSaidAsOnTheScreens`.
@Suite struct LockedNotificationTests {
    @Test func anIdleLockSaysTheVaultLockedItself() {
        let plain = LockedNotification.of(idle: nil)
        #expect(plain.title == "Your vault is locked" && plain.body == "You won’t be notified until you unlock it")
        let n = LockedNotification.of(idle: IdleLocked(afterSeconds: 604_800))
        #expect(n.title == "Your vault locked itself")
        #expect(n.body == "You hadn’t checked in for 7 days, so your vault locked. Unlock it with your PIN and your credential "
            + "password to carry on. New messages wait for up to 14 days.")
        #expect(n.publicTitle == "VettID needs your attention")
        // Staging (24): 7 days run as 7 hours; and a time not known.
        #expect(LockedNotification.of(idle: IdleLocked(afterSeconds: 25_200)).body.hasPrefix("You hadn’t checked in for 7 hours,"))
        #expect(LockedNotification.of(idle: IdleLocked(afterSeconds: nil)).body
            == "You hadn’t checked in, so your vault locked. Unlock it with your PIN and your credential password to carry on. "
            + "New messages wait for up to 14 days.")
        #expect(LockedNotification.of(idle: IdleLocked(afterSeconds: 86_400)).body.hasPrefix("You hadn’t checked in for 1 day,"))
    }
}
