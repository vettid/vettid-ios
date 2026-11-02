import Foundation
import SwiftUI
import UIKit
import UserNotifications
import VettIDData
import VettIDNotify
import VettIDShell
import VettIDUI

/// The feed's notifications on this iPhone (IOS-PLAN §6.7; ANDROID-PLAN §4 Notification modes 7 and 8): the notifier over
/// the vault manager's feed, the notification center's delegate, and whether the member allowed notifications. Before
/// Apple push (IOS-PLAN ID12) the feed is collected only while the app is in the foreground, so these show as banners
/// while the app is open on another screen. The permission is asked once, when the open app is first shown (never on
/// the onboarding screens); the iPhone's Settings keep the answer, and turn notifications off. Nothing here is stored.
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    let previews = NotificationPreviewsSetting()
    let visibility = NotifyVisibility()
    /// A tap waiting for the open app's shell.
    let taps = NotificationOpenInbox()
    private(set) var notifier: FeedNotifier?
    /// The member allowed notifications for VettID (read at launch, on each return to the foreground and after the ask).
    private var allowed = false

    /// Hooks the notifier to [vault]'s feed and sets this as the notification center's delegate.
    func start(vault: VaultManager) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(SystemNotificationPoster.categories)
        let previews = previews
        let visibility = visibility
        let notifier = FeedNotifier(
            poster: SystemNotificationPoster(center: center),
            previews: { previews.previews },
            open: { [weak vault] in
                guard let vault, vault.phase == .unlocked else { return false }
                return vault.ownerChecks.ownerCheck?.gated(Date()) != true
            },
            visible: { UIApplication.shared.applicationState == .active ? visibility.visible : nil },
            allowed: { [weak self] in self?.allowed ?? false },
            names: { [weak vault] in
                guard let vault else { return FeedNames() }
                return FeedNames(
                    connections: vault.connections.connections, items: vault.items.names ?? [:],
                    approvals: vault.approvals.approvals, votes: vault.votes.votes
                )
            },
            messageText: { [weak vault] connectionID, messageID in
                guard let m = vault?.messages.messages(connectionID).first(where: { $0.messageID == messageID && !$0.outgoing }) else {
                    return nil
                }
                return NotificationContent.messageText(m.text, photo: m.attachment != nil)
            }
        )
        self.notifier = notifier
        previews.onSet = { [weak notifier] in notifier?.previewsChanged($0) }
        vault.feed.onArrival = { [weak notifier] in notifier?.arrived($0) }
        vault.feed.onItems = { [weak notifier] in notifier?.itemsChanged($0) }
        vault.feed.onCleared = { [weak notifier] in notifier?.cleared() }
        notifier.start()
        refreshAllowed()
    }

    /// Reads whether the member allows notifications (they may have changed it in the iPhone's Settings).
    func refreshAllowed() {
        Task { @MainActor [weak self] in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            self?.allowed = Self.allows(status)
        }
    }

    nonisolated static func allows(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// The permission, asked once: the iPhone asks only while the member has not answered.
    func askOnce() {
        Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            self?.refreshAllowed()
        }
    }

    /// A wipe: "Show in notifications" back to its default, and no tap waiting.
    func reset() {
        previews.reset()
        taps.consume()
    }

    /// In the foreground: a banner (the notifier posts nothing about the screen in front); Vault activity and an update in
    /// place go to the list only.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        SystemNotificationPoster.presentation(notification.request.content.interruptionLevel)
    }

    /// A tap: the item, for the open app's shell (after the app lock, the unlock and the daily check).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = SystemNotificationPoster.itemID(response.notification.request.content.userInfo) else { return }
        await MainActor.run { taps.offer(id) }
    }
}

/// The open app's part (IOS-PLAN §4.12, the tap rule): the screen in front for the notifier, the tap's item opened once the
/// shell is really in front, and the permission asked the first time. The shell exists only while the vault is open and
/// no check past the deadline takes its place; it stays mounted under the app lock's cover and under an asked daily
/// check, so nothing here acts then (``ShellModel/inFront(appLocked:)``): a tap waits for the unlock or the check. Waits up
/// to 10 seconds for the tapped item after a start, as vettid-android does; the item is marked read.
struct ShellNotificationsHook: ViewModifier {
    let notifications: AppNotifications
    let model: ShellModel
    let feed: FeedManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.vettIDLocked) private var appLocked

    static let itemWait: Duration = .seconds(10)

    private var inFront: Bool { model.inFront(appLocked: appLocked) }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: update)
            .onDisappear {
                notifications.visibility.set(nil)
                // The vault locked or a check took the shell's place: the tap's item is waited for again after it.
                notifications.taps.rearm()
            }
            .onChange(of: model.notifyVisible) { _, _ in show() }
            .onChange(of: appLocked) { _, _ in update() }
            .onChange(of: model.asked) { _, _ in update() }
            .onChange(of: scenePhase) { _, now in
                show()
                guard now == .active else { return }
                notifications.refreshAllowed()
                openTapped()
            }
            .onChange(of: notifications.taps.itemID) { _, _ in openTapped() }
            .onChange(of: notifications.taps.waitOver) { _, _ in openTapped() }
    }

    private func update() {
        show()
        guard inFront else { return }
        notifications.askOnce()
        openTapped()
    }

    private func show() {
        notifications.visibility.set(scenePhase == .active && inFront ? model.notifyVisible : nil)
    }

    /// The tapped item opens only while the shell is in front, decided again after any wait: a wait for the item never
    /// acts by itself, it only asks the shell to decide again (``NotificationOpenInbox/waitOver``).
    private func openTapped() {
        let taps = notifications.taps
        // Only in the foreground: a wait that ends in the background leaves the tap for the return.
        guard inFront, scenePhase == .active, let id = taps.itemID else { return }
        let item = feed.items.first { $0.itemID == id }
        guard item != nil || taps.waitOver else {
            if taps.startWaiting() { wait(for: id) }
            return
        }
        taps.consume()
        if item != nil { feed.markReadQuietly(id) }
        model.openNotified(item)
    }

    /// Waits up to ``itemWait`` for [id] to reach the feed (after a start, as vettid-android does), then ends the wait.
    private func wait(for id: String) {
        let feed = feed
        let taps = notifications.taps
        Task { @MainActor in
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: Self.itemWait)
            while !feed.items.contains(where: { $0.itemID == id }), clock.now < end, taps.itemID == id {
                try? await Task.sleep(for: .milliseconds(250))
            }
            taps.waitEnded(for: id)
        }
    }
}
