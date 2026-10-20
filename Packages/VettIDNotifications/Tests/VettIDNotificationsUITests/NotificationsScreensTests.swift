#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
import VettIDNotifications
@testable import VettIDNotificationsUI
import VettIDUI
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Notifications screens: their texts (vettid-android's, word for word), every state rendered, the headers, the rows'
/// state for VoiceOver, the icons, the detail sheet's lines and notes, the delete question and the bell. Mirrors
/// vettid-android `NotificationsScreenTest`.
@MainActor
@Suite struct NotificationsScreensTests {
    static func item(_ id: String, _ kind: String = "message.received", status: String = "active", priority: String = "normal", connection: String? = nil, ref: String? = nil) -> FeedItem {
        FeedItem(itemID: id, seq: 1, kind: kind, at: "2026-10-19T12:00:00.000Z", status: status, priority: priority, connectionID: connection, ref: ref)
    }

    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDNotificationsUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 38)
        let missing = "\u{0}missing"
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            #expect(key.hasPrefix("notifications_"), "\(key)")
        }
    }

    @Test func theTextsAreAndroids() {
        #expect(NotificationsStrings.title == "Notifications" && NotificationsStrings.archivedTitle == "Archived")
        #expect(NotificationsStrings.markAllRead == "Mark all as read" && NotificationsStrings.needsAttention == "Needs attention")
        #expect(NotificationsStrings.deleteBody == "Delete this notification on all your devices?")
        #expect(NotificationsStrings.deleteBatch("Sam") == "Later requests from Sam will start a new notification.")
        #expect(NotificationsStrings.sheetUnknown == "A newer kind of notification. Update VettID to see more.")
        #expect(NotificationsStrings.emptyBody == "What happens in your vault appears here")
    }

    @Test func theHeadersSayTheDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        let today = cal.startOfDay(for: now)
        #expect(FeedTimes.header(nil, now: now, calendar: cal) == "Needs attention")
        #expect(FeedTimes.header(today, now: now, calendar: cal) == "Today")
        #expect(FeedTimes.header(cal.date(byAdding: .day, value: -1, to: today), now: now, calendar: cal) == "Yesterday")
        #expect(FeedTimes.header(FeedSections.undated, now: now, calendar: cal) == "Earlier")
    }

    @Test func aRowSaysItsStateAndIcon() {
        #expect(FeedRow.stateText(Self.item("a", priority: "urgent"), unread: true) == "Unread, Urgent")
        #expect(FeedRow.stateText(Self.item("a", priority: "high"), unread: false) == "Important")
        #expect(FeedRow.stateText(Self.item("a"), unread: false).isEmpty)
        #expect(FeedIcons.hue(Self.item("a", "credential.alarm", priority: "urgent")) == .red)
        #expect(FeedIcons.hue(Self.item("a", "message.received", priority: "high")) == .amber)
        #expect(FeedIcons.hue(Self.item("a", "device.paired")) == .purple && FeedIcons.icon("device.paired") == .devices)
        #expect(FeedIcons.icon("guide") == .eventNote && FeedIcons.icon("drop.rate_limited") == .block)
    }

    @Test func theSheetSaysWhatIsLeft() {
        let names = FeedNames()
        let revealed = FeedDetailSheet.lines(Self.item("r", "item.revealed", ref: "01GONE"), names)
        #expect(revealed.contains(.init(label: "Item", value: "Deleted item")))
        let future = FeedDetailSheet.lines(Self.item("f", "future.kind"), names)
        #expect(future.contains(.init(label: "Kind", value: "future.kind")))
        #expect(FeedDetailSheet.lines(Self.item("m", connection: "gone"), names).contains(.init(label: "Connection", value: "Removed connection")))
        #expect(FeedDetailSheet.note(Self.item("l", "leash.item.run"), gone: false) == "Not available in this version of the app.")
        #expect(FeedDetailSheet.note(Self.item("g", "grant.request", ref: "g1"), gone: true) == "This is no longer waiting.")
        #expect(FeedDetailSheet.note(Self.item("m", connection: "gone"), gone: true) == "What this was about is no longer there.")
        #expect(FeedDetailSheet.note(Self.item("f", "future.kind"), gone: false) == "A newer kind of notification. Update VettID to see more.")
        #expect(FeedDetailSheet.note(Self.item("m"), gone: false) == nil)
    }

    @Test func deletingABatchSaysLaterRequestsStartANewOne() {
        var sam = ConnectionInfo(id: "c1", name: "", state: .active)
        sam.firstName = "Sam"
        let names = FeedNames(connections: ["c1": sam])
        #expect(NotificationsScreen.deleteMessage(Self.item("m"), names: names) == "Delete this notification on all your devices?")
        #expect(NotificationsScreen.deleteMessage(Self.item("g", "grant.request", connection: "c1"), names: names)
            == "Delete this notification on all your devices?\n\nLater requests from Sam will start a new notification.")
    }

    /// No bell while held or due; the feed's count otherwise.
    @Test func theBellFollowsTheFeedAndTheHold() {
        let feed = FakeFeed()
        feed.items = [Self.item("a", priority: "urgent"), Self.item("b"), Self.item("c", status: "read")]
        #expect(NotificationsBell.of(feed, held: true) {} == nil && NotificationsBell.of(nil, held: false) {} == nil)
        let bell = NotificationsBell.of(feed, held: false) {}
        #expect(bell?.unread == 2 && bell?.urgent == true)
    }

    @Test func everyStateRenders() {
        var sam = ConnectionInfo(id: "c1", name: "", state: .active)
        sam.firstName = "Sam"
        sam.lastName = "Lee"
        let items = [Self.item("u", "credential.alarm", priority: "urgent"), Self.item("m", connection: "c1"), Self.item("r", "device.paired", status: "read"), Self.item("z", status: "archived")]
        var loaded = NotificationsState()
        loaded.load = .loaded
        var full = loaded
        full.items = items
        full.names = FeedNames(connections: ["c1": sam])
        var failed = NotificationsState()
        failed.load = .failed
        var unread = loaded
        unread.unreadOnly = true
        var archived = full
        archived.archived = true
        var emptyArchived = loaded
        emptyArchived.archived = true
        var sheet = full
        sheet.sheet = items[1]
        sheet.sheetGone = true
        var deleting = archived
        deleting.confirmDelete = items[3]
        for s in [NotificationsState(), loaded, full, failed, unread, archived, emptyArchived, sheet, deleting] {
            _ = host(NotificationsScreen(state: s, actions: NotificationsActions()))
        }
        _ = host(FeedDetailSheet(item: items[0], names: FeedNames(), gone: false))
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }
}

// swiftlint:enable line_length
#endif
