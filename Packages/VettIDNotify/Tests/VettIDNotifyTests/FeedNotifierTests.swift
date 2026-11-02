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
        var visible: NotifyVisible?
        var names: FeedNames = {
            var sam = ConnectionInfo(id: "c1", name: "", state: .active)
            sam.firstName = "Sam"
            sam.lastName = "Lee"
            return FeedNames(connections: ["c1": sam], items: ["i1": "Passport"])
        }()
        var text: String? = "See you at 6"
        lazy var notifier = FeedNotifier(
            poster: poster, previews: { [unowned self] in previews }, open: { [unowned self] in open },
            visible: { [unowned self] in visible }, allowed: { [unowned self] in allowed }, names: { [unowned self] in names },
            messageText: { [unowned self] _, _ in text }
        )
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
