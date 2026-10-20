import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDNotifications
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Notifications screen's model: the grouping, viewing marks read, the tap and its target or sheet, archive and
/// Undo, read and unread, the Archived view's move back and delete, Mark all as read, and every failure. Mirrors
/// vettid-android `NotificationsTest`.
@MainActor
@Suite struct NotificationsViewModelTests {
    let feed = FakeFeed()
    let connections = FakeConnections()
    let approvals: FakeApprovals
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    init() { approvals = FakeApprovals(connections: connections) }

    static func item(_ id: String, _ kind: String = "message.received", at: String = "2026-10-19T12:00:00.000Z", status: String = "active", priority: String = "normal", connection: String? = nil, ref: String? = nil) -> FeedItem {
        FeedItem(itemID: id, seq: 1, kind: kind, at: at, status: status, priority: priority, connectionID: connection, ref: ref)
    }

    func model(archived: Bool = false) async -> NotificationsViewModel {
        let m = NotificationsViewModel(feed: feed, connections: connections, approvals: approvals, archived: archived)
        await m.settle()
        return m
    }

    @Test func sectionsPutUrgentUnreadFirstThenDays() {
        let items = [
            Self.item("a", at: "2026-10-19T09:00:00.000Z"), Self.item("b", "credential.alarm", at: "2026-10-18T09:00:00.000Z", priority: "urgent"),
            Self.item("c", at: "2026-10-18T10:00:00.000Z", status: "read"), Self.item("d", at: "2026-10-19T11:00:00.000Z", status: "archived"),
            Self.item("e", "credential.alarm", at: "2026-10-17T09:00:00.000Z", status: "read", priority: "urgent"), Self.item("f", at: "nonsense"),
        ]
        let s = FeedSections.of(items, archived: false, unreadOnly: false, calendar: Self.utc)
        #expect(s.map { $0.items.map(\.itemID) } == [["b"], ["a"], ["c"], ["e"], ["f"]])
        #expect(s[0].day == nil && s[4].day == FeedSections.undated)
        #expect(FeedSections.of(items, archived: true, unreadOnly: false, calendar: Self.utc).map { $0.items.map(\.itemID) } == [["d"]])
        let unread = FeedSections.of(items, archived: false, unreadOnly: true, calendar: Self.utc, fresh: ["c"])
        #expect(unread.flatMap { $0.items.map(\.itemID) } == ["b", "a", "c", "f"])
    }

    @Test func aDayTitleHasTheYearOnlyWhenNotThisYears() {
        let en = Locale(identifier: "en_GB")
        let day = Self.utc.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let today = Self.utc.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        #expect(FeedSections.dayTitle(day, today: today, calendar: Self.utc, locale: en) == "Mon 5 Oct")
        let old = Self.utc.date(from: DateComponents(year: 2025, month: 10, day: 6))!
        #expect(FeedSections.dayTitle(old, today: today, calendar: Self.utc, locale: en) == "Mon 6 Oct 2025")
    }

    @Test func aFeedNotReadIsReadOnceAndAFailureShows() async {
        feed.load = .notLoaded
        feed.fail["refresh"] = VaultFailure(.network)
        let m = await model()
        #expect(feed.calls == ["refresh"] && m.state.load == .failed && m.state.error == .network)
        m.errorShown()
        m.refresh()
        await m.settle()
        #expect(m.state.load == .loaded && m.state.error == nil)
        // Already read: not read again.
        let other = NotificationsViewModel(feed: feed)
        await other.settle()
        #expect(feed.calls == ["refresh", "refresh"])
    }

    /// Viewing marks read the unread items that are not urgent, once each; they keep their dot until the member leaves.
    @Test func viewingMarksReadButNotUrgentAndKeepsTheDot() async {
        feed.items = [Self.item("a"), Self.item("u", "credential.alarm", priority: "urgent"), Self.item("r", status: "read")]
        let m = await model()
        #expect(feed.calls.isEmpty)
        m.shown()
        #expect(feed.calls == ["markViewed:a"] && m.state.fresh == ["a"])
        #expect(m.state.showsUnread(feed.items[0]) && m.state.showsUnread(feed.items[1]) && !m.state.showsUnread(feed.items[2]))
        // An arrival while in view is marked too; while paused it is not.
        feed.items.append(Self.item("b"))
        #expect(await eventually { feed.calls.last == "markViewed:b" })
        m.paused()
        feed.items.append(Self.item("c"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(feed.calls.last == "markViewed:b")
        m.left()
        #expect(m.state.fresh.isEmpty && !m.state.showsUnread(feed.items[0]))
        // Coming back marks what is still unread (c), never twice what was handled.
        m.shown()
        #expect(feed.calls.last == "markViewed:c")
        // The Archived view never marks.
        let archived = await model(archived: true)
        archived.shown()
        #expect(feed.calls.last == "markViewed:c")
    }

    @Test func aTapMarksReadAndOpensItsTargetOrTheSheet() async {
        var sam = ConnectionInfo(id: "c1", name: "", state: .active)
        sam.firstName = "Sam"
        connections.connections = [sam]
        let m = await model()
        m.open(Self.item("m", connection: "c1"))
        #expect(feed.calls == ["markReadQuietly:m"] && m.state.open == .conversation("c1"))
        m.targetTaken()
        #expect(m.state.open == nil)
        // The connection is gone: the sheet, "no longer there".
        m.open(Self.item("x", connection: "gone"))
        #expect(m.state.open == nil && m.state.sheet?.itemID == "x" && m.state.sheetGone)
        m.closeSheet()
        #expect(m.state.sheet == nil && !m.state.sheetGone)
        // A kind with no screen: the sheet, not gone.
        m.open(Self.item("g", "guide"))
        #expect(m.state.sheet?.itemID == "g" && !m.state.sheetGone)
        // An ask decided or expired: the sheet, gone; one still waiting: Approvals.
        m.open(Self.item("q", "grant.request", connection: "c1", ref: "g1"))
        #expect(m.state.sheet?.itemID == "q" && m.state.sheetGone)
        approvals.listed = [.grant(GrantRequest(requestID: "g1", connectionID: "c1", entries: [], receivedAt: Date(), exp: nil))]
        m.closeSheet()
        m.open(Self.item("q", "grant.request", connection: "c1", ref: "g1"))
        #expect(m.state.open == .approval(key: "grant:g1"))
        // An item not in the cache (no items list yet): the sheet. A device kind: its screen.
        m.open(Self.item("i", "item.revealed", ref: "01ITEM"))
        #expect(m.state.sheet?.itemID == "i" && m.state.sheetGone)
        m.open(Self.item("d", "device.paired"))
        #expect(m.state.open == .devices)
    }

    @Test func archiveAndUndoRestoreThePreviousStatus() async {
        feed.items = [Self.item("a"), Self.item("r", status: "read")]
        let m = await model()
        m.archive(feed.items[0])
        await m.settle()
        #expect(m.state.undo == ArchiveUndo(itemID: "a", previous: "active") && feed.items[0].status == "archived")
        m.undoArchive()
        await m.settle()
        #expect(m.state.undo == nil && feed.calls.last == "setStatus:a:active" && feed.items[0].status == "active")
        // An undone item is not marked read by viewing.
        m.shown()
        #expect(!feed.calls.contains("markViewed:a"))
        m.archive(feed.items[1])
        m.undoShown()
        #expect(m.state.undo == nil)
        // A refused archive shows the failure.
        feed.fail["setStatus"] = VaultFailure(.network)
        m.archive(feed.items[0])
        await m.settle()
        #expect(m.state.error == .network)
    }

    @Test func toggleReadFollowsWhatTheRowShows() async {
        feed.items = [Self.item("a"), Self.item("r", status: "read")]
        let m = await model()
        m.toggleRead(feed.items[0])
        await m.settle()
        #expect(feed.calls.last == "setStatus:a:read")
        m.toggleRead(feed.items[1])
        await m.settle()
        #expect(feed.calls.last == "setStatus:r:active")
        // Read by viewing (still dotted): only the dot goes.
        feed.items = [Self.item("v")]
        m.shown()
        let before = feed.calls.count
        m.toggleRead(feed.items[0])
        await m.settle()
        #expect(feed.calls.count == before && !m.state.fresh.contains("v"))
    }

    @Test func theArchivedViewMovesBackAndDeletesAfterConfirming() async {
        feed.items = [Self.item("z", status: "archived")]
        let m = await model(archived: true)
        #expect(m.state.archived && m.state.sections().count == 1)
        m.moveToNotifications(feed.items[0])
        await m.settle()
        #expect(feed.calls.last == "setStatus:z:read")
        m.askDelete(feed.items[0])
        #expect(m.state.confirmDelete?.itemID == "z")
        m.askDelete(nil)
        m.delete()
        #expect(!feed.calls.contains("delete:z"))
        m.askDelete(feed.items[0])
        m.delete()
        await m.settle()
        #expect(feed.calls.last == "delete:z" && feed.items.isEmpty && m.state.confirmDelete == nil)
        feed.items = [Self.item("y", status: "archived")]
        feed.fail["delete"] = VaultFailure(.notFound)
        m.askDelete(feed.items[0])
        m.delete()
        await m.settle()
        #expect(m.state.error == .notFound)
    }

    @Test func markAllReadOnceAtATimeAndItsFailure() async {
        feed.items = [Self.item("a"), Self.item("b")]
        let m = await model()
        m.shown()
        #expect(m.state.unread == 0 && m.state.fresh == ["a", "b"])
        feed.items.append(Self.item("c"))
        m.paused()
        m.markAllRead()
        #expect(m.state.markingAll && m.state.fresh.isEmpty)
        m.markAllRead()
        await m.settle()
        #expect(feed.calls.filter { $0 == "markAllRead" }.count == 1 && !m.state.markingAll && m.state.unread == 0)
        feed.items.append(Self.item("d"))
        feed.fail["markAllRead"] = VaultFailure(.network)
        m.markAllRead()
        await m.settle()
        #expect(m.state.error == .network && !m.state.markingAll)
    }

    @Test func theUnreadChipAndTheNames() async {
        var sam = ConnectionInfo(id: "c1", name: "", state: .active)
        sam.firstName = "Sam"
        sam.lastName = "Lee"
        connections.connections = [sam]
        feed.items = [Self.item("a", status: "read", connection: "c1"), Self.item("b")]
        let m = await model()
        m.setUnreadOnly(true)
        #expect(m.state.sections().flatMap { $0.items.map(\.itemID) } == ["b"])
        #expect(m.state.names.connections["c1"] != nil)
        #expect(FeedKinds.title(feed.items[0], m.state.names) == "New message from Sam Lee")
    }

    /// The state never shows the feed's content in a log or a dump.
    @Test func theStateRevealsNoContent() async {
        feed.items = [Self.item("secret-id", "guide")]
        let m = await model()
        m.open(feed.items[0])
        for text in [String(describing: m.state), String(reflecting: m.state)] {
            #expect(!text.contains("secret-id") && !text.contains("guide"))
        }
        #expect(Mirror(reflecting: m.state).children.isEmpty)
    }

    @Test func iconsComeFromHistorysCategories() {
        #expect(FeedCategories.of("guide") == .other && FeedCategories.of("credential.alarm") == .security)
        #expect(FeedCategories.of("message.received") == .messages && FeedCategories.of("recovery.attempt") == .security)
        #expect(FeedCategories.of("owner_check.failed") == .vaultAccess && FeedCategories.of("grant.request") == .items)
    }
}

func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// swiftlint:enable line_length
