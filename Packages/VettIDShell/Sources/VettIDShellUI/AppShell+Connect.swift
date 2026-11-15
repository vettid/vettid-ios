#if os(iOS)
import SwiftUI
import VettIDConnectionsUI
import VettIDData

extension AppShell {
    /// Where the connect flow's screens go (vettid-android `connectionsDestination`'s host).
    var connectHost: ConnectHost {
        let model = model
        var h = ConnectHost()
        h.onBack = { model.pop() }
        h.replace = { model.replace(.connect($0)) }
        h.push = { model.push(.connect($0)) }
        h.onOpenConnection = { model.push(.connection($0)) }
        h.replaceWithConnection = { model.replace(.connection($0)) }
        // A connection's History, once History is there (IOS-PLAN §8 I2.3).
        if history != nil, historyExport != nil { h.onOpenHistory = { model.openConnectionHistory($0) } }
        // "Send a message" on a connection's page and after connecting, once the messages are there (IOS-PLAN §8 I2.2).
        if messages != nil { h.onOpenConversation = { model.openConversation($0) } }
        // "Votes from <name>" on a service connection's page, once the Votes are there.
        if votes != nil { h.onOpenVotes = { model.openConnectionVotes($0) } }
        // The Call button of a connection's page: only while the vault's probe says it has calls (owner decision).
        if let calls {
            h.canCall = calls.canCall
            h.onCall = calls.call
        }
        // The sharing cards of a connection's page, once the Vault's sharing screens are there (IOS-PLAN §8 I3.2).
        if items != nil, sharing != nil {
            h.onOpenSharing = { model.openSharing($0) }
            h.onOpenShared = { model.openShared($0) }
            h.onOpenShareRule = { model.openRule($0, $1) }
            h.onAskFor = { model.openShared($0, ask: true) }
        }
        return h
    }
}
#endif
