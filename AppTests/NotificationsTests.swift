import Foundation
import Testing
import UserNotifications
@testable import VettID
import VettIDData
import VettIDNotify
import VettIDOnboarding

/// The feed's notifications in the app (IOS-PLAN §6.7): the system poster's sweep runs against the real notification
/// center without leaving the main actor's rules (its answer comes on the center's own queue), and a wipe resets what
/// the notifications keep in memory.
@MainActor
struct NotificationsTests {
    @Test func theLeftoverSweepRunsAgainstTheRealCenter() async throws {
        let poster = SystemNotificationPoster()
        poster.removeLeftovers()
        poster.remove(["none"])
        try await Task.sleep(for: .milliseconds(500))
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        #expect(delivered.allSatisfy { SystemNotificationPoster.itemID($0.request.content.userInfo) == nil })
    }

    @Test func aWipeResetsWhatNotificationsShowAndATapWaiting() throws {
        let n = AppNotifications()
        n.taps.offer("f1")
        n.reset()
        #expect(n.taps.itemID == nil && n.previews.previews == .names)
    }

    @Test func passiveNotificationsDoNotBannerInTheForeground() {
        #expect(SystemNotificationPoster.presentation(.passive) == [.list])
        #expect(SystemNotificationPoster.presentation(.active) == [.banner, .list, .sound])
    }
}

/// A notification's tap, decided from what holds now (``ShellNotificationsHook/decision(stale:active:inFront:found:waitOver:)``).
@MainActor
struct NotificationTapDecisionTests {
    typealias Decision = ShellNotificationsHook.TapDecision

    @Test func aTapWaitsForTheAppAndTheShellThenForItsItem() {
        let d = ShellNotificationsHook.decision
        #expect(d(true, true, true, true, false) == Decision.drop, "stale: dropped whatever holds")
        #expect(d(false, false, true, true, false) == Decision.later, "the app not active")
        #expect(d(false, true, false, true, false) == Decision.later, "under the app lock or an asked check")
        #expect(d(false, true, true, false, false) == Decision.wait, "the item not in the feed yet")
        #expect(d(false, true, true, true, false) == Decision.open)
        #expect(d(false, true, true, false, true) == Decision.open, "the wait is over: the Notifications screen")
    }
}

/// The shell's live state for a tap: the daily check's gate read with the clock, not on the gate view's tick.
@MainActor
struct NotificationShellOpenTests {
    @Test func aDeadlinePastByTheClockClosesTheShellForATap() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let past = OwnerCheckView(state: .ok, deadline: now.addingTimeInterval(-1))
        let ahead = OwnerCheckView(state: .ok, deadline: now.addingTimeInterval(3_600))
        #expect(AppNotifications.shellOpen(unlocked: true, checkAfterCancel: false, check: ahead, now: now))
        #expect(!AppNotifications.shellOpen(unlocked: true, checkAfterCancel: false, check: past, now: now))
        #expect(!AppNotifications.shellOpen(unlocked: true, checkAfterCancel: true, check: ahead, now: now))
        #expect(!AppNotifications.shellOpen(unlocked: false, checkAfterCancel: false, check: ahead, now: now))
        // With the shell still mounted, a tap then waits: nothing is opened or marked read.
        let inFront = AppNotifications.shellOpen(unlocked: true, checkAfterCancel: false, check: past, now: now)
        #expect(ShellNotificationsHook.decision(stale: false, active: true, inFront: inFront, found: true, waitOver: false) == .later)
    }

    @Test func withoutTheVaultTheShellIsNotOpen() {
        #expect(!AppNotifications().shellOpen())
    }
}
