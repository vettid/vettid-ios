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
/// the requests' safety codes kept out of captures, the detail's pill and its closing once the connection is gone.
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
        #expect(EndedRequestNotice.title(.gone) == "Already decided")
        #expect(EndedRequestNotice.body(.gone) == "This request was decided on another device, or it expired.")
        #expect(EndedRequestNotice.title(.expired) == "No connection was made")
        #expect(EndedRequestNotice.body(.expired) == "The request expired before both of you approved.")
        #expect(EndedRequestNotice.body(.declined) == "You declined the request.")
        #expect(AsksCard.label(.allowAgain) == "Allow declined requests again")
    }

    /// "Connected" alone for an active connection without a display name; otherwise the state and the display name.
    @Test func aRowSaysTheStateAndTheDisplayName() {
        var c = Self.connection("c1")
        #expect(ConnectionItem.supporting(c) == "Connected")
        c.name = "Countess"
        #expect(ConnectionItem.supporting(c) == "Countess")
        c.state = .pending
        #expect(ConnectionItem.supporting(c) == "Waiting for approval · Countess")
    }

    /// The requests as vettid-android's request screens word them, on either side.
    @Test func aRequestSaysWhatToCompare() {
        let incoming = PendingConnection.incoming(
            ConnectionRequest(pendingID: "p", sas: "042817", remote: true, name: "Ada", receivedAt: Date(), exp: nil)
        )
        let outgoing = PendingConnection.outgoing(
            OutgoingRequest(connectionID: "o", sas: "042817", remote: false, name: nil, state: .pending, receivedAt: Date(), exp: nil)
        )
        #expect(RequestCard.type(incoming) == "Connection request (link)" && RequestCard.type(outgoing) == "Your connection request")
        #expect(RequestCard.body(incoming).hasPrefix("\u{2068}Ada\u{2069} used your invitation link."))
        #expect(RequestCard.body(outgoing).hasPrefix("Compare it with Someone: it must match the code on their phone."))
        #expect(RequestCard.approveLabel(incoming) == "The codes match: connect")
        #expect(RequestCard.approveLabel(outgoing) == "The codes match: approve")
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

    /// IOS-PLAN §6.4: a request's safety code on the secure layer, unless screenshots are allowed.
    @Test func aRequestsCodeIsKeptOutOfCaptures() {
        guard SecureLayer.isAvailable else { return }
        var s = ConnectionsState()
        s.loading = false
        s.requests = [.incoming(ConnectionRequest(pendingID: "p", sas: "042817", remote: false, name: "Ada", receivedAt: Date(), exp: nil))]
        let screen = ConnectionsScreen(state: s, chrome: chrome, actions: ConnectionsActions())
        let protected = host(screen.environment(ScreenshotAllowance(onByDefault: false)))
        #expect(views(in: protected).contains { String(describing: type(of: $0)).contains("Canvas") })
        let allowed = host(screen.environment(ScreenshotAllowance(onByDefault: true)))
        #expect(!views(in: allowed).contains { String(describing: type(of: $0)).contains("Canvas") })
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
            s.requests = [
                .incoming(ConnectionRequest(pendingID: "p", sas: "042817", remote: true, name: nil, receivedAt: Date(), exp: nil)),
                .outgoing(OutgoingRequest(
                    connectionID: "o1", sas: nil, remote: false, name: "Ada", state: .waiting, receivedAt: Date(), exp: nil
                )),
                .outgoing(OutgoingRequest(
                    connectionID: "o2", sas: "042817", remote: true, name: "Ada", state: .approved, receivedAt: Date(), exp: nil
                )),
            ]
            s.deciding = ["p"]
            s.ended = EndedRequest(requestID: "x", end: .gone)
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
        return [loading, bare, full, cooled]
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
