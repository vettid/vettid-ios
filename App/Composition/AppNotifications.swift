import Foundation
import SwiftUI
import UIKit
import UserNotifications
import VettIDData
import VettIDNotify
import VettIDShell

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

    /// In the foreground: a banner (the notifier posts nothing about the screen in front).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap: the item, for the open app's shell (after the app lock, the unlock and the daily check).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = SystemNotificationPoster.itemID(response.notification.request.content.userInfo) else { return }
        await MainActor.run { taps.offer(id) }
    }
}

/// The open app's part (IOS-PLAN §4.12, the tap rule): the screen in front for the notifier, the tap's item opened once the
/// shell is shown (it is only after the app lock, the unlock and the daily check), and the permission asked the first
/// time. Waits up to 10 seconds for the tapped item after a start, as vettid-android does; the item is marked read.
struct ShellNotificationsHook: ViewModifier {
    let notifications: AppNotifications
    let model: ShellModel
    let feed: FeedManager
    @Environment(\.scenePhase) private var scenePhase

    static let itemWait: Duration = .seconds(10)

    func body(content: Content) -> some View {
        content
            .onAppear {
                notifications.askOnce()
                show()
                openTapped()
            }
            .onDisappear { notifications.visibility.set(nil) }
            .onChange(of: model.notifyVisible) { _, _ in show() }
            .onChange(of: scenePhase) { _, now in
                show()
                if now == .active { notifications.refreshAllowed() }
            }
            .onChange(of: notifications.taps.itemID) { _, _ in openTapped() }
    }

    private func show() {
        notifications.visibility.set(scenePhase == .active ? model.notifyVisible : nil)
    }

    private func openTapped() {
        guard let id = notifications.taps.itemID else { return }
        notifications.taps.consume()
        let feed = feed
        let model = model
        Task { @MainActor in
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: Self.itemWait)
            var item = feed.items.first { $0.itemID == id }
            while item == nil, clock.now < end, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                item = feed.items.first { $0.itemID == id }
            }
            if item != nil { feed.markReadQuietly(id) }
            model.openNotified(item)
        }
    }
}
