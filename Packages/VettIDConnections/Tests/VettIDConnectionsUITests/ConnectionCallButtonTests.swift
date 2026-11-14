#if os(iOS)
import Foundation
import Testing
import VettIDConnections
@testable import VettIDConnectionsUI
import VettIDData

/// The Call button of a connection's page (vettid-android `ConnectionDetailScreen`): shown only when the vault's probe has said it
/// has calls (owner decision), never for a service or a connection that is not active, hidden otherwise.
@MainActor
@Suite struct ConnectionCallButtonTests {
    static func host(canCall: Bool, onCall: (@MainActor (String) -> Void)?) -> ConnectHost {
        var h = ConnectHost()
        h.canCall = { canCall }
        h.onCall = onCall
        return h
    }

    static func actions(_ host: ConnectHost) -> DetailActions {
        ConnectionDetailRoute.actions(nil, connectionID: "c1", hasSharing: false, host: host)
    }

    @Test func theButtonIsHiddenUnlessTheVaultHasCalls() {
        #expect(Self.actions(ConnectHost()).onCall == nil)
        #expect(Self.actions(Self.host(canCall: false, onCall: { _ in })).onCall == nil)
        #expect(Self.actions(Self.host(canCall: true, onCall: nil)).onCall == nil)
        #expect(Self.actions(Self.host(canCall: true, onCall: { _ in })).onCall != nil)
    }

    @Test func aTapCallsThisConnection() {
        var called: [String] = []
        Self.actions(Self.host(canCall: true, onCall: { called.append($0) })).onCall?()
        #expect(called == ["c1"])
    }

    @Test func thePillHasTheCallButtonAfterMessageOnlyForAnActivePerson() {
        func labels(_ c: ConnectionInfo, call: Bool, messages: Bool = true) -> [String] {
            var a = DetailActions()
            if call { a.onCall = {} }
            if messages { a.onMessage = {} }
            return ConnectionDetailScreen(state: ConnectionDetailState(connectionID: c.id), actions: a).pill(c).map(\.label)
        }
        var c = ConnectionInfo(id: "c1", name: "", state: .active)
        c.firstName = "Ada"
        c.lastName = "Lovelace"
        let with = labels(c, call: true)
        #expect(with.firstIndex(of: "Call") == 1 && with[0].hasPrefix("Message"))
        #expect(!labels(c, call: false).contains("Call"))
        c.isService = true
        #expect(!labels(c, call: true).contains("Call"))
        c.isService = false
        c.state = .stale
        #expect(!labels(c, call: true).contains("Call"))
    }
}
#endif
