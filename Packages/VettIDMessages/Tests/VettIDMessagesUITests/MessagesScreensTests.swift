#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDMessages
@testable import VettIDMessagesUI
import VettIDUI

/// The Messages screens: their texts (vettid-android's, word for word), every state rendered, the rows' lines, the bubbles'
/// states and links, the days, and when the top loads older messages. Mirrors vettid-android's `feature/messages` screen
/// tests (the photos in ``PhotoScreensTests``).
@MainActor
@Suite struct MessagesScreensTests {
    static func connection(_ id: String, first: String? = "Ada", state: ConnectionState = .active) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: state)
        c.firstName = first
        c.lastName = first == nil ? nil : "Lovelace"
        return c
    }

    static func message(_ id: String, outgoing: Bool = false, text: String = "Hello", at: Date = Date(), read: Bool = false,
                        delivered: Bool = false) -> MessageInfo {
        MessageInfo(connectionID: "c1", messageID: id, outgoing: outgoing, text: text, sentAt: at, delivered: delivered, read: read)
    }

    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDMessagesUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 95)
        let missing = "\u{0}missing"
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            #expect(key.hasPrefix("messages_"), "\(key)")
        }
    }

    @Test func theTextsAreAndroids() {
        #expect(MessagesStrings.title == "Messages" && MessagesStrings.filter == "Unread" && MessagesStrings.add == "New message")
        #expect(MessagesStrings.emptyNoConnections == "Invite someone to connect, then write to them here")
        #expect(MessagesStrings.previewYou("Hi") == "You: Hi")
        #expect(MessagesStrings.rowUnread(1, "Hi") == "1 unread · Hi" && MessagesStrings.rowUnread(3, "Hi") == "3 unread · Hi")
        #expect(MessagesStrings.conversationEmptyBody("Ada") == "Messages with Ada go through your vaults, end to end encrypted")
        #expect(MessagesStrings.outgoingLabel("Hi", "3:00 PM", "Read") == "You: Hi. 3:00 PM, Read")
        #expect(MessagesStrings.incomingLabel("Ada", "Hi", "3:00 PM") == "Ada: Hi. 3:00 PM")
        #expect(MessagesStrings.replyHint("Ada") == "Message Ada")
        #expect(MessagesStrings.tooLong == "This message is too long (16 KB at most)")
        #expect(MessagesStrings.inactive("Ada") == "Ada cannot receive messages right now: the connection is not active.")
        #expect(MessagesStrings.deleteBody("Ada") == "It is removed from your vault only; Ada keeps their copy.")
        #expect(MessagesStrings.details("Ada") == "About Ada" && MessagesStrings.loadOlder == "Show older messages")
        #expect(MessagesStrings.openLink("example.org") == "Open link to example.org?" && MessagesStrings.openLinkConfirm == "Open")
    }

    /// A row's line: the latest message's first line ("You: " for the member's own), after the unread count.
    @Test func aRowSaysTheLatestMessage() {
        let c = Self.connection("c1")
        #expect(ConversationItem.supporting(ConversationSummary(connection: c, last: nil, unread: 0)) == "No messages yet")
        let own = Self.message("m1", outgoing: true, text: "See you\nat noon")
        #expect(ConversationItem.supporting(ConversationSummary(connection: c, last: own, unread: 0)) == "You: \u{2068}See you\u{2069}")
        let theirs = Self.message("m2", text: "Hi")
        #expect(ConversationItem.supporting(ConversationSummary(connection: c, last: theirs, unread: 2)) == "2 unread · \u{2068}Hi\u{2069}")
        #expect(ConversationItem.name(Self.connection("c2", first: nil)) == "Name not shared yet")
    }

    @Test func theEmptyStatesSayWhy() {
        var s = MessagesState()
        s.loading = false
        #expect(MessagesScreen.emptyTitle(s) == "No messages" && MessagesScreen.emptyBody(s) == MessagesStrings.emptyNoConnections)
        s.noConnections = false
        #expect(MessagesScreen.emptyBody(s) == "Conversations with your connections appear here")
        s.unreadOnly = true
        #expect(MessagesScreen.emptyTitle(s) == "No unread messages" && MessagesScreen.emptyBody(s) == "You are all caught up")
    }

    @Test func everyListStateRenders() {
        for s in listStates() {
            #expect(height(MessagesScreen(state: s, chrome: chrome, actions: MessagesActions())) > 0, "\(s)")
        }
    }

    @Test func everyConversationStateRenders() {
        for s in conversationStates() {
            #expect(height(ConversationScreen(state: s, actions: ConversationActions())) > 0, "\(s)")
            _ = host(ConversationScreen(state: s, actions: ConversationActions()))
        }
    }

    @Test func everyPickerStateRenders() {
        var full = NewMessageState()
        full.loading = false
        full.connections = [Self.connection("c1"), Self.connection("c2", first: nil)]
        var empty = NewMessageState()
        empty.loading = false
        for s in [NewMessageState(), empty, full] {
            #expect(height(NewMessageScreen(state: s, onBack: {}, onPick: { _ in }, onInvite: {})) > 0, "\(s)")
        }
    }

    /// VAULT-MESSAGING 0.76.0 §10.8 steps 4 and 6: the preview is the first line that shows something, isolated; a photo with
    /// nothing to show says "Photo"; any other text with nothing to show leaves out the line and its "You: " label.
    @Test func aPreviewTakesTheFirstLineThatShowsSomething() {
        let c = Self.connection("c1")
        func row(_ text: String, outgoing: Bool = false, unread: Int = 0, photo: Bool = false) -> String {
            var m = Self.message("m", outgoing: outgoing, text: text)
            if photo {
                m.attachment = AttachmentInfo(attID: "a", state: .stored, reason: nil, mime: nil, size: 1, width: 1, height: 1, name: nil)
            }
            return ConversationItem.supporting(ConversationSummary(connection: c, last: m, unread: unread))
        }
        #expect(row("\u{3164}\n\u{202E} hi \nmore") == "\u{2068}hi\u{2069}")
        #expect(row("hi", outgoing: true) == "You: \u{2068}hi\u{2069}")
        #expect(row("\u{200D}\u{000B}\u{000C}  x") == "\u{2068}x\u{2069}")
        for empty in ["\u{200B}\u{3164}", "\u{200D}", "\u{00A0}", "\r\u{200B}\n", "\u{000B}\u{000C}"] {
            #expect(row(empty) == "" && row(empty, outgoing: true) == "")
            #expect(row(empty, unread: 3) == "3 unread")
            #expect(row(empty, photo: true) == "Photo" && row(empty, outgoing: true, photo: true) == "You: Photo")
        }
    }

    /// §10.8 step 7: a search matches the cleaned text without the isolates, across a name and the words around it.
    @Test func aSearchMatchesTheCleanedText() {
        let c = Self.connection("c1", first: "Ada\u{202E}")
        let s = ConversationSummary(connection: c, last: Self.message("m", text: "pay\u{2029}\u{200B}now \u{2068}x\u{2069}"), unread: 0)
        #expect(s.matches("ada lovelace") && s.matches("pay now x") && !s.matches("\u{2068}"))
    }

    /// §10.8 "more lightly": a bubble keeps LRM, RLM and ALM, drops the rest, isolates each line, and links are found in what
    /// it shows.
    @Test func aBubbleIsCleanedLightlyAndIsolatedPerLine() {
        let a = BubbleText.message("\n a\u{200F}\u{202E}b https://example.org/x\r\u{200B}\n\u{3000}c \u{2028}")
        #expect(String(a.characters) == "\u{2068}a\u{200F}b https://example.org/x\u{2069}\n\u{2068}\u{2069}\n\u{2068}\u{3000}c\u{2069}")
        #expect(a.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.org/x"])
        #expect(String(BubbleText.message("\u{3164}\u{200B}").characters).isEmpty)
    }

    /// An outgoing message says read, delivered or sent; an incoming one nothing.
    @Test func aBubbleSaysItsState() {
        #expect(MessageList.status(Self.message("m", outgoing: true)) == "Sent")
        #expect(MessageList.status(Self.message("m", outgoing: true, delivered: true)) == "Delivered")
        #expect(MessageList.status(Self.message("m", outgoing: true, read: true, delivered: true)) == "Read")
        #expect(MessageList.status(Self.message("m", read: true)) == nil)
    }

    /// Only the link rule's ranges are tappable (VAULT-MESSAGING §10.5 "Links"): other schemes stay text, and the text
    /// reads the same.
    @Test func onlyHttpsLinksAreTappable() throws {
        let text = "Go to https://example.org/a. Not http://plain.example, vettid://connect or someapp://x (https://b.example)"
        let a = BubbleText.attributed(text)
        #expect(String(a.characters) == text)
        let links = a.runs.compactMap { run in run.link.map { ($0, String(a[run.range].characters)) } }
        #expect(links.map(\.1) == ["https://example.org/a", "https://b.example"])
        #expect(links.map(\.0.absoluteString) == ["https://example.org/a", "https://b.example"])
        #expect(BubbleText.attributed("no links here").runs.allSatisfy { $0.link == nil })
        #expect(String(BubbleText.attributed("").characters).isEmpty)
    }

    /// The messages by day, each day once, in the order it first appears.
    @Test func theMessagesGoByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let day1 = Date(timeIntervalSince1970: 1_791_115_200)
        let day2 = day1.addingTimeInterval(86_400)
        let ms = [Self.message("a", at: day1), Self.message("b", at: day1.addingTimeInterval(60)), Self.message("c", at: day2),
                  Self.message("d", at: day1.addingTimeInterval(120))]
        let days = MessageList.days(ms, calendar: calendar)
        #expect(days.map { $0.messages.map(\.messageID) } == [["a", "b", "d"], ["c"]])
    }

    /// Reaching the top loads older messages only once the opening settled, and not for a top in view from the start until
    /// it has left the view.
    @Test func theTopLoadsOnlyWhenReached() {
        var t = OlderTrigger()
        let early = t.appeared()
        t.settle()
        let afterSettle = t.armed
        t.disappeared()
        let back = t.appeared()
        #expect(!early && !afterSettle && back)
        var long = OlderTrigger()
        long.settle()
        let first = long.appeared()
        long.disappeared()
        let again = long.appeared()
        #expect(first && again)
    }

    /// The confirmed link's last step: an invitation to the accept screen, another link to the system, nothing otherwise.
    @Test func aConfirmedLinkGoesWhereItBelongs() throws {
        var opened: [URL] = []
        var invited: [String] = []
        let url = try #require(URL(string: "https://example.org/a"))
        LinkOpening.perform(.open(url), open: { opened.append($0) }, invite: { invited.append($0) })
        LinkOpening.perform(.invite("https://relay.vettid.org/connect#x"), open: { opened.append($0) }, invite: { invited.append($0) })
        LinkOpening.perform(nil, open: { opened.append($0) }, invite: { invited.append($0) })
        #expect(opened == [url] && invited == ["https://relay.vettid.org/connect#x"])
    }

    /// VoiceOver names a link by the host the question shows: lower case, ASCII.
    @Test func aLinkIsNamedByItsASCIIHost() throws {
        let link = try #require(MessageLinks.links(in: "https://Bücher.Example/x").first)
        #expect(BubbleText.linkName(link.url) == "xn--bcher-kva.example")
        #expect(BubbleText.linkName(try #require(URL(string: "https://EXAMPLE.org"))) == "example.org")
    }

    /// The conversation's link question names the host and, once answered, the route opens nothing by itself.
    @Test func theLinkQuestionNamesTheHost() throws {
        var s = ConversationState(connectionID: "c1")
        s.loading = false
        s.connection = Self.connection("c1")
        s.link = LinkPrompt(url: try #require(URL(string: "https://xn--bcher-kva.example/x")), host: "xn--bcher-kva.example")
        #expect(MessagesStrings.openLink(try #require(s.link).host) == "Open link to xn--bcher-kva.example?")
        _ = host(ConversationScreen(state: s, actions: ConversationActions()))
    }

    private var chrome: ShellChrome { ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {}) }

    private func listStates() -> [MessagesState] {
        var loaded = MessagesState()
        loaded.loading = false
        var full = loaded
        full.noConnections = false
        full.searchable = true
        full.conversations = [
            ConversationSummary(connection: Self.connection("c1"), last: Self.message("m1"), unread: 1),
            ConversationSummary(connection: Self.connection("c2", first: nil), last: nil, unread: 0),
        ]
        var failed = loaded
        failed.error = .network
        var noMatch = full
        noMatch.conversations = []
        noMatch.query = "zz"
        var unread = loaded
        unread.unreadOnly = true
        unread.noConnections = false
        return [MessagesState(), loaded, full, failed, noMatch, unread]
    }

    private func conversationStates() -> [ConversationState] {
        let base = ConversationState(connectionID: "c1")
        var empty = base
        empty.loading = false
        empty.connection = Self.connection("c1")
        var full = empty
        full.messages = [
            Self.message("m1", text: "See https://example.org"), Self.message("m2", outgoing: true, delivered: true),
            Self.message("m3", outgoing: true, read: true),
        ]
        full.olderAvailable = true
        full.draft = "Hi"
        var busy = full
        busy.loadingOlder = true
        busy.sending = true
        busy.error = .network
        var tooLong = full
        tooLong.tooLong = true
        var inactive = full
        inactive.connection?.state = .blocked
        var deleting = full
        deleting.deleting = full.messages.first
        return [base, empty, full, busy, tooLong, inactive, deleting]
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }
}
#endif
