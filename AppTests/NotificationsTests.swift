import Foundation
import Testing
import UserNotifications
@testable import VettID
import VettIDData
import VettIDNotify

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
