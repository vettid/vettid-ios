import Foundation
import Testing
import VettIDData
import VettIDVault
@testable import VettIDNotify

/// Feed items as notifications (ANDROID-PLAN §4 Notification modes 7 and 8). Mirrors the feed part of vettid-android
/// `FeedNotifierTest`.
@MainActor
@Suite struct FeedNotifierTests {
    @MainActor
    final class Posted: NotificationPoster {
        var shown: [String: LocalNotification] = [:]
        var log: [String] = []
        var leftoverSweeps = 0

        func post(_ n: LocalNotification) {
            shown[n.id] = n
            log.append("post:\(n.id)")
        }

        func remove(_ ids: [String]) {
            for id in ids where shown.removeValue(forKey: id) != nil { log.append("remove:\(id)") }
        }

        func removeLeftovers() { leftoverSweeps += 1 }
    }

    @MainActor
    final class World {
        let poster = Posted()
        var previews = NotificationPreviews.names
        var open = true
        var allowed = true
        var active = true
        var namesRead = 0
        var visible: NotifyVisible?
        var names: FeedNames = {
            var sam = ConnectionInfo(id: "c1", name: "", state: .active)
            sam.firstName = "Sam"
            sam.lastName = "Lee"
            return FeedNames(connections: ["c1": sam], items: ["i1": "Passport"])
        }()
        var text: String? = "See you at 6"
        /// The votes list read before a `vote.result` is titled: how often, whether it went through, and how long it takes.
        var votesRead = 0
        var votesFresh = true
        var votesSlow: Duration?
        lazy var notifier = FeedNotifier(
            poster: poster, previews: { [unowned self] in previews }, open: { [unowned self] in open },
            active: { [unowned self] in active }, visible: { [unowned self] in visible }, allowed: { [unowned self] in allowed },
            names: { [unowned self] in
                namesRead += 1
                return names
            },
            messageText: { [unowned self] _, _ in text },
            refreshVotes: { [unowned self] in await refreshVotes() },
            voteListWait: .milliseconds(150)
        )

        func refreshVotes() async -> Bool {
            votesRead += 1
            // A read that ignores cancellation (queued behind earlier reads): only the race can hold the cap.
            if let slow = votesSlow {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    Task {
                        try? await Task.sleep(for: slow)
                        c.resume()
                    }
                }
            }
            return votesFresh
        }
        var items: [FeedItem] = []

        func arrive(_ i: FeedItem) {
            items = items.filter { $0.itemID != i.itemID } + [i]
            notifier.arrived(i)
        }
    }

    private func item(_ id: String, kind: String = "message.received", status: String = "active", count: Int? = nil, ref: String? = "m1")
        -> FeedItem {
        var i = FeedItem(itemID: id, seq: 1, kind: kind, at: "2026-10-09T12:00:00Z", status: status, connectionID: "c1", ref: ref)
        i.count = count
        return i
    }

    @Test func anItemNotifiesInItsCategoryAndGoesWhenReadAnywhere() {
        let w = World()
        w.arrive(item("f1"))
        let n = try? #require(w.poster.shown["f1"])
        #expect(n?.category == .messages)
        #expect(n?.title == "New message from \u{2068}Sam Lee\u{2069}")
        #expect(n?.body == nil, "Names: never the message text")
        #expect(n?.publicTitle == "New activity in VettID")
        #expect(n?.itemID == "f1" && n?.names == true && n?.update == false)
        // Read on another device (a catch-up changed its status).
        w.notifier.itemsChanged([item("f1", status: "read")])
        #expect(w.poster.shown.isEmpty)
        // Archived or deleted: gone from the list.
        w.arrive(item("f2"))
        w.notifier.itemsChanged([])
        #expect(w.poster.shown.isEmpty)
    }

    /// The give-up item (VAULT-MESSAGING 0.83.6 §10.19.6 step 4, owner decision a): a `vote.result` is it only by its vote's
    /// state in the list, read again first (at most 3 s; 150 ms here); a list that cannot be read in time, or under "Nothing",
    /// reads as the generic "Vote results are out" (the review's M3).
    @Test func aVoteResultIsTheGiveUpItemOnlyWhenTheListWasReadAgain() async {
        func settled(_ w: World, _ id: String) async -> LocalNotification? {
            for _ in 0..<100 where w.poster.shown[id] == nil { try? await Task.sleep(for: .milliseconds(10)) }
            return w.poster.shown[id]
        }
        let result = item("v1", kind: "vote.result", ref: "p1")
        // Fresh: the give-up title, the list read once.
        let w = World()
        w.names.votesGaveUp = ["c1/p1"]
        w.arrive(result)
        #expect(await settled(w, "v1")?.title == "Vote results not checked yet" && w.votesRead == 1)
        // The read did not go through: the list may be older than the item, so the generic title.
        let failed = World()
        failed.names.votesGaveUp = ["c1/p1"]
        failed.votesFresh = false
        failed.arrive(result)
        #expect(await settled(failed, "v1")?.title == "Vote results are out")
        // Too slow: the same, within the wait.
        let slow = World()
        slow.names.votesGaveUp = ["c1/p1"]
        slow.votesSlow = .seconds(5)
        slow.arrive(result)
        #expect(await settled(slow, "v1")?.title == "Vote results are out")
        // A vote that is not `gave_up`, and "Nothing" (no names read, no list read).
        let plain = World()
        plain.arrive(result)
        #expect(await settled(plain, "v1")?.title == "Vote results are out")
        let hidden = World()
        hidden.previews = .nothing
        hidden.names.votesGaveUp = ["c1/p1"]
        hidden.arrive(result)
        #expect(hidden.poster.shown["v1"]?.title == "New activity in VettID" && hidden.votesRead == 0)
        // Other kinds are posted at once and read nothing.
        let other = World()
        other.arrive(item("v2", kind: "vote.open", ref: "p1"))
        #expect(other.poster.shown["v2"] != nil && other.votesRead == 0)
        // Read meanwhile: not posted.
        let read = World()
        read.votesSlow = .milliseconds(50)
        read.arrive(result)
        read.notifier.cleared()
        read.active = false
        #expect(await settled(read, "v1") == nil)
    }

    @Test func aBatchIsOneNotificationUpdatedInPlaceWithoutAlertingAgain() {
        let w = World()
        w.arrive(item("b", kind: "grant.request", count: 2, ref: "g1"))
        w.arrive(item("b", kind: "grant.request", count: 3, ref: "g1"))
        #expect(w.poster.log == ["post:b", "post:b"])
        #expect(w.poster.shown["b"]?.title == "\u{2068}Sam\u{2069} asks for 3 things")
        #expect(w.poster.shown["b"]?.update == true)
        #expect(w.poster.shown["b"]?.category == .requests)
    }

    @Test func whatNotificationsShow() {
        let w = World()
        w.previews = .namesAndText
        w.arrive(item("f1"))
        #expect(w.poster.shown["f1"]?.body == "See you at 6")
        w.arrive(item("f2", kind: "item.revealed", ref: "i1"))
        #expect(w.poster.shown["f2"]?.title == "\u{2068}Passport\u{2069} was revealed")
        w.previews = .names
        w.arrive(item("f3", kind: "item.revealed", ref: "i1"))
        #expect(w.poster.shown["f3"]?.title.contains("Passport") == false, "Names: no item names")
        w.previews = .nothing
        w.arrive(item("f4"))
        #expect(w.poster.shown["f4"]?.title == "New activity in VettID" && w.poster.shown["f4"]?.body == nil)
        #expect(w.poster.shown["f4"]?.names == false)
        // The security category's lock-screen text.
        var alarm = item("f5", kind: "credential.alarm", ref: "a1")
        alarm.priority = "urgent"
        w.arrive(alarm)
        #expect(w.poster.shown["f5"]?.publicTitle == "VettID needs your attention")
        #expect(w.poster.shown["f5"]?.category == .security)
    }

    @Test func aRequestWhoseScreenComesLaterSaysToOpenANewerVettID() {
        let w = World()
        w.arrive(item("r1", kind: "intro.request", ref: "x"))
        #expect(w.poster.shown["r1"]?.body == "Open VettID on a newer version")
        w.previews = .namesAndText
        w.arrive(item("r2", kind: "intro.request", ref: "x"))
        #expect(w.poster.shown["r2"]?.body == "Open VettID on a newer version")
    }

    @Test func aLockHoldOrWipeRemovesEveryItemNotification() {
        let w = World()
        w.arrive(item("f1"))
        w.arrive(item("f2", kind: "connection.added"))
        w.open = false
        w.notifier.cleared()
        #expect(w.poster.shown.isEmpty && w.poster.leftoverSweeps == 1)
        w.arrive(item("f3"))
        #expect(w.poster.shown.isEmpty, "nothing while the vault is not open")
        w.open = true
        w.arrive(item("f4"))
        #expect(Set(w.poster.shown.keys) == ["f4"])
        #expect(w.notifier.posted == ["f4"])
    }

    /// "Nothing" chosen: the item notifications already showing, which name people, go; another choice keeps them.
    @Test func choosingNothingRemovesWhatIsShowing() {
        let w = World()
        w.arrive(item("f1"))
        w.notifier.previewsChanged(.namesAndText)
        #expect(Set(w.poster.shown.keys) == ["f1"])
        w.notifier.previewsChanged(.nothing)
        #expect(w.poster.shown.isEmpty && w.poster.leftoverSweeps == 1 && w.notifier.posted.isEmpty)
    }

    /// A narrower choice removes what is showing (it shows more than the choice allows); a wider one keeps it.
    @Test func narrowingWhatNotificationsShowRemovesWhatIsShowing() {
        let w = World()
        w.previews = .namesAndText
        w.arrive(item("f1"))
        w.notifier.previewsChanged(.namesAndText)
        #expect(Set(w.poster.shown.keys) == ["f1"])
        w.notifier.previewsChanged(.names)
        #expect(w.poster.shown.isEmpty && w.poster.leftoverSweeps == 1)
        w.arrive(item("f2"))
        w.notifier.previewsChanged(.namesAndText)
        #expect(Set(w.poster.shown.keys) == ["f2"], "wider: kept")
    }

    /// With "Nothing" no name is read.
    @Test func nothingReadsNoNames() {
        let w = World()
        w.previews = .nothing
        w.arrive(item("f1"))
        #expect(w.poster.shown["f1"] != nil && w.namesRead == 0)
        w.previews = .names
        w.arrive(item("f2"))
        #expect(w.namesRead == 1)
    }

    /// Owner decision of 2026-11-02: leaving the foreground removes every item notification, and nothing is posted while
    /// the app is not active (an arrival in the background's grace period).
    @Test func leavingTheForegroundRemovesEverythingAndNothingPostsMeanwhile() {
        let w = World()
        w.arrive(item("f1"))
        w.active = false
        w.notifier.backgrounded()
        #expect(w.poster.shown.isEmpty && w.poster.leftoverSweeps == 1 && w.notifier.posted.isEmpty)
        w.arrive(item("f2"))
        #expect(w.poster.shown.isEmpty, "nothing posts while not active")
        w.active = true
        w.arrive(item("f3"))
        #expect(Set(w.poster.shown.keys) == ["f3"])
    }

    @Test func nothingWithoutTheMembersPermission() {
        let w = World()
        w.allowed = false
        w.arrive(item("f1"))
        #expect(w.poster.log.isEmpty)
    }

    @Test func onlyActiveItemsNotify() {
        let w = World()
        w.arrive(item("f1", status: "read"))
        w.arrive(item("f2", status: "archived"))
        #expect(w.poster.log.isEmpty)
    }

    @Test func nothingWhileItsScreenIsInFront() {
        let w = World()
        w.visible = .notifications
        w.arrive(item("f1"))
        w.visible = .target(.conversation("c1"))
        w.arrive(item("f2"))
        w.arrive(item("f3", kind: "connection.added"))
        w.visible = .target(.vote(connectionID: "c1", proposalID: "p1"))
        w.arrive(item("v1", kind: "vote.open", ref: "p1"))
        w.arrive(item("v2", kind: "vote.open", ref: "p2"))
        #expect(Set(w.poster.shown.keys) == ["f3", "v2"])
    }

    /// ANDROID-PLAN §4 Notification modes 8: a notification posted before the process ended does not outlive the open vault.
    @Test func atStartWithTheVaultNotOpenWhatAnEarlierProcessPostedGoes() {
        let w = World()
        w.open = false
        w.notifier.start()
        #expect(w.poster.leftoverSweeps == 1)
        let v = World()
        v.notifier.start()
        #expect(v.poster.leftoverSweeps == 0)
    }

    @Test func receivedMessageTextIsCleanedIsolatedAndFirstLineOnly() {
        let fsi = "\u{2068}", pdi = "\u{2069}"
        #expect(NotificationContent.messageText("\u{202E}\n hi \nsecond", photo: false) == "\(fsi)hi\(pdi)")
        #expect(NotificationContent.messageText("\u{200B}\u{3164}\n\u{200D}", photo: false) == nil)
        #expect(NotificationContent.messageText("\u{3164}", photo: true) == "Photo")
        #expect(NotificationContent.messageText("\u{202E}beach\nmore", photo: true) == "Photo: \(fsi)beach\(pdi)")
    }

    @Test func theNotificationNeverCarriesAMatchCode() {
        let w = World()
        var signin = item("s1", kind: "connection.authenticate.requested", ref: "a1")
        signin.title = "Match code 4271"
        signin.body = "match code 4271"
        for p in [NotificationPreviews.names, .namesAndText] {
            w.previews = p
            w.arrive(signin)
            let n = w.poster.shown["s1"]
            #expect(n?.title.contains("4271") == false)
            #expect((n?.body ?? "").contains("4271") == false)
        }
    }

    @Test func aNotificationDescribesNoText() {
        let n = LocalNotification(id: "x", category: .messages, title: "New message from Sam", body: "secret", publicTitle: "p")
        #expect(!String(describing: n).contains("Sam") && !String(reflecting: n).contains("secret"))
    }
}

#if os(iOS)
import UserNotifications

/// The system poster's pure parts: the foreground presentation by level, and which delivered notifications are the feed's.
@Suite struct SystemNotificationPosterTests {
    @Test func passiveNotificationsGoToTheListOnly() {
        #expect(SystemNotificationPoster.presentation(.passive) == [.list])
        for level in [UNNotificationInterruptionLevel.active, .timeSensitive] {
            #expect(SystemNotificationPoster.presentation(level) == [.banner, .list, .sound])
        }
    }

    @Test func onlyFeedItemNotificationsAreLeftovers() {
        let delivered: [(String, [AnyHashable: Any])] = [
            ("f1", [SystemNotificationPoster.itemKey: "f1"]), ("other", [:]), ("x", ["something": "else"]),
        ]
        #expect(SystemNotificationPoster.itemIDs(delivered) == ["f1"])
        #expect(SystemNotificationPoster.itemID([SystemNotificationPoster.itemKey: "f2"]) == "f2")
    }
}

/// The poster's bookkeeping over a fake center whose adds land when the test says.
@MainActor
@Suite struct SystemNotificationPosterOrderTests {
    @MainActor
    final class FakeCenter: NotificationCenterOps {
        var landings: [(String, @Sendable () -> Void)] = []
        var removedPending: [String] = []
        var removedDelivered: [String] = []
        var shown: [String] = []

        func add(_ request: UNNotificationRequest, landed: @escaping @Sendable () -> Void) {
            landings.append((request.identifier, landed))
        }

        func removePending(_ ids: [String]) { removedPending += ids }

        func removeDelivered(_ ids: [String]) { removedDelivered += ids }

        func delivered() async -> [(String, [AnyHashable: Any])] {
            shown.map { ($0, [SystemNotificationPoster.itemKey: $0]) }
        }

        /// The first add still under way lands.
        func land() async {
            let (id, landed) = landings.removeFirst()
            shown.append(id)
            landed()
            for _ in 0..<5 { await Task.yield() }
        }
    }

    private func note(_ id: String) -> LocalNotification {
        LocalNotification(id: id, category: .messages, title: "t", publicTitle: "p", itemID: id)
    }

    @Test func postRemoveLandRemovesItOnceItLands() async {
        let c = FakeCenter()
        let p = SystemNotificationPoster(center: c)
        p.post(note("f1"))
        p.remove(["f1"])
        c.removedDelivered = []
        c.removedPending = []
        await c.land()
        #expect(c.removedDelivered == ["f1"] && c.removedPending == ["f1"])
    }

    @Test func postSweepLandRemovesItOnceItLands() async {
        let c = FakeCenter()
        let p = SystemNotificationPoster(center: c)
        p.post(note("f1"))
        p.removeLeftovers()
        for _ in 0..<5 { await Task.yield() }
        #expect(c.removedDelivered.isEmpty, "the sweep leaves an add under way to the add")
        await c.land()
        #expect(c.removedDelivered == ["f1"] && c.removedPending == ["f1"])
    }

    @Test func postRemovePostAgainThenTheFirstLandsKeepsTheSecond() async {
        let c = FakeCenter()
        let p = SystemNotificationPoster(center: c)
        p.post(note("f1"))
        p.remove(["f1"])
        p.post(note("f1"))
        c.removedDelivered = []
        c.removedPending = []
        await c.land()
        #expect(c.removedDelivered.isEmpty && c.removedPending.isEmpty, "the first add's landing leaves the second")
        await c.land()
        #expect(c.removedDelivered.isEmpty)
    }

    @Test func aSweepKeepsWhatWasPostedAfterItBegan() async {
        let c = FakeCenter()
        let p = SystemNotificationPoster(center: c)
        c.shown = ["old"]
        p.removeLeftovers()
        p.post(note("new"))
        await c.land()
        for _ in 0..<5 { await Task.yield() }
        #expect(c.removedDelivered.contains("old") && !c.removedDelivered.contains("new"))
    }
}
#endif
