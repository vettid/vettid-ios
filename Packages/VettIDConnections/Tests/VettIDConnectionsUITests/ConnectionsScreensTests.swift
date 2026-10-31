#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDConnections
@testable import VettIDConnectionsUI
import VettIDData
import VettIDUI

/// The Connections list and a connection's detail: their texts (vettid-android's, word for word), every state rendered,
/// the detail's pill and its closing once the connection is gone.
/// Mirrors vettid-android `ConnectionNamesScreenTest` and `ConnectionsSearchTest`.
@MainActor
@Suite struct ConnectionsScreensTests {
    static func connection(_ id: String, first: String? = "Ada", favorite: Bool = false) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: .active)
        c.firstName = first
        c.lastName = first == nil ? nil : "Lovelace"
        c.favorite = favorite
        return c
    }

    @Test func theTextsAreAndroids() {
        #expect(ConnectStrings.title == "Connections" && ConnectStrings.emptyTitle == "No connections yet")
        #expect(ConnectStrings.inviteExpires("Oct 20, 2026 at 3:00 PM") == "Expires Oct 20, 2026 at 3:00 PM")
        #expect(ConnectStrings.removeTitle("Ada") == "Remove Ada?")
        #expect(ConnectStrings.asksCooldowns(1) == "1 request you declined is refused for 7 days.")
        #expect(ConnectStrings.asksCooldowns(3) == "3 requests you declined are refused for 7 days.")
        #expect(ConnectStrings.asksPaused("Ada")
            == "Ada’s requests are paused after you declined several. They are refused without asking you until you resume them.")
        #expect(ConnectStrings.stateLabel(.active) == nil && ConnectStrings.stateLabel(.stale) == "Out of reach: needs a new invitation")
        #expect(AsksCard.label(.allowAgain) == "Allow declined requests again")
    }

    /// "Connected" alone for an active connection without a display name; otherwise the state and the display name.
    @Test func aRowSaysTheStateAndTheDisplayName() {
        var c = Self.connection("c1")
        #expect(ConnectionItem.supporting(c) == "Connected")
        c.name = "Countess"
        #expect(ConnectionItem.supporting(c) == "\u{2068}Countess\u{2069}")
        c.state = .pending
        #expect(ConnectionItem.supporting(c) == "Waiting for approval · \u{2068}Countess\u{2069}")
    }

    @Test func everyListStateRenders() {
        for s in listStates() {
            #expect(height(ConnectionsScreen(state: s, chrome: chrome, actions: ConnectionsActions())) > 0, "\(s)")
        }
    }

    @Test func everyDetailStateRenders() {
        for s in detailStates() {
            var actions = DetailActions()
            if s.busy { actions.onMessage = {} }
            #expect(height(ConnectionDetailScreen(state: s, actions: actions)) > 0, "\(s)")
        }
    }

    /// The message action only once the messages are there (IOS-PLAN §8 I2.2), and only for an active connection;
    /// favourite and remove always.
    @Test func thePillOffersWhatTheAppHas() {
        let c = Self.connection("c1", favorite: true)
        let screen = ConnectionDetailScreen(state: ConnectionDetailState(connectionID: "c1"), actions: DetailActions())
        #expect(screen.pill(c).map(\.label) == ["Remove \u{2068}Ada Lovelace\u{2069} from favourites", "Remove"])
        var actions = DetailActions()
        actions.onMessage = {}
        var state = ConnectionDetailState(connectionID: "c1")
        state.connection = c
        let withMessages = ConnectionDetailScreen(state: state, actions: actions)
        #expect(withMessages.pill(c).first?.label == "Message \u{2068}Ada Lovelace\u{2069}")
        var stale = c
        stale.state = .stale
        #expect(withMessages.pill(stale).count == 2)
    }

    /// The connection is gone (removed here, or unknown to the vault): the screen closes.
    @Test func aGoneConnectionCloses() {
        var closed = 0
        var actions = DetailActions()
        actions.onBack = { closed += 1 }
        var state = ConnectionDetailState(connectionID: "c1")
        state.gone = true
        _ = host(ConnectionDetailScreen(state: state, actions: actions))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(closed == 1)
    }

    private var chrome: ShellChrome { ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {}) }

    private func listStates() -> [ConnectionsState] {
        let full: ConnectionsState = {
            var s = ConnectionsState()
            s.loading = false
            s.connections = [Self.connection("c1", favorite: true), Self.connection("c2", first: nil)]
            s.connections[1].state = .blocked
            s.connections[0].lastActiveAt = Date()
            s.invites = [
                OutstandingInvite(inviteID: "i1", exp: Date().addingTimeInterval(600), remote: false),
                OutstandingInvite(inviteID: "i2", exp: nil, remote: true),
            ]
            s.peerDeclines = [PeerDecline(requestID: "r", name: nil, outgoing: false, at: Date())]
            s.error = .network
            s.cancelling = s.invites.first
            s.searchable = true
            return s
        }()
        var loading = ConnectionsState()
        loading.loading = true
        var failed = ConnectionsState()
        failed.loading = false
        failed.error = .network
        var empty = ConnectionsState()
        empty.loading = false
        var noMatch = empty
        noMatch.query = "zz"
        noMatch.searchable = true
        var searching = full
        searching.query = "Ada"
        return [loading, failed, empty, noMatch, full, searching]
    }

    private func detailStates() -> [ConnectionDetailState] {
        var loading = ConnectionDetailState(connectionID: "c1")
        loading.loading = true
        var bare = ConnectionDetailState(connectionID: "c1")
        bare.loading = false
        bare.connection = Self.connection("c1", first: nil)
        bare.connection?.asks = AskState()
        var full = ConnectionDetailState(connectionID: "c1")
        full.loading = false
        full.busy = true
        full.error = .network
        full.confirm = .remove
        var c = Self.connection("c1", favorite: true)
        c.name = "Countess"
        c.sharedItems = [SharedProfileItem(itemID: "i", name: "Phone", fields: [.init("Mobile", "+1 555 0100")])]
        c.keyFingerprint = "0123 4567 89ab cdef 0123 4567 89ab cdef"
        c.createdAt = Date()
        c.lastActiveAt = Date()
        c.asks = AskState(muted: true, paused: true, pausedAt: Date(), cooldowns: 2)
        full.connection = c
        var cooled = full
        cooled.connection?.asks = AskState(cooldowns: 1)
        // The first read failed: the error card with "Try again", not a blank page.
        var failed = ConnectionDetailState(connectionID: "c1")
        failed.loading = false
        failed.error = .network
        return [loading, bare, full, cooled, failed]
    }

    /// The add sheet opens at half height and can be pulled to full height; at the largest text size its options scroll, so
    /// the last one ("Paste a link") can be reached.
    @Test func theAddSheetGrowsAndScrollsAtLargeSizes() {
        #expect(VettIDSheet.detents == [.medium, .large])
        let sheet = AddConnectionSheet(onInvite: {}, onScan: {}, onPaste: {})
            .vettIDGrowingSheet()
            .environment(\.dynamicTypeSize, .accessibility5)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 420))
        window.rootViewController = UIHostingController(rootView: sheet.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        let scroll = views(in: window).compactMap { $0 as? UIScrollView }.first
        #expect(scroll != nil)
        if let scroll { #expect(scroll.contentSize.height > scroll.bounds.height) }
        window.isHidden = true
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

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }
}
#endif
