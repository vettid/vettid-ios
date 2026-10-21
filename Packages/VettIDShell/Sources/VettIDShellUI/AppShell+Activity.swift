#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDApprovalsUI
import VettIDData
import VettIDHistory
import VettIDHistoryUI
import VettIDItems
import VettIDNotifications
import VettIDNotificationsUI
import VettIDShell

/// The Notifications screens (from the bell), one approval's decision (from Approvals or a feed item), a History entry and
/// a connection's History: vettid-android's `notificationsDestination`, `approvalsDestination` and `historyDestination`.
extension AppShell {
    @ViewBuilder func activityDetail(_ route: ShellRoute) -> some View {
        switch route {
        case .notifications(let archived):
            if let feed {
                NotificationsRoute(
                    feed: feed, connections: connections, approvals: approvals, items: items, archived: archived, host: notificationsHost
                )
            }
        case .approval(let key):
            if let approvals { ApprovalDetailRoute(key, approvals: approvals, connections: connections, items: items, host: approvalsHost) }
        case .historyEntry(let seq):
            if let history { HistoryEntryRoute(seq, history: history, connections: connections, items: items, host: historyHost) }
        case .connectionHistory(let id):
            if let history, let historyExport {
                HistoryRoute(
                    history: history, export: historyExport, connections: connections, ownerChecks: ownerChecks, items: items,
                    connectionID: id, chrome: nil, host: historyHost
                )
            }
        default:
            EmptyView()
        }
    }

    /// Where the Notifications screens go (vettid-android `NotificationsHost`): back, the Archived view, an item's target.
    var notificationsHost: NotificationsHost {
        let model = model
        var h = NotificationsHost()
        h.onBack = { model.pop() }
        h.onOpenArchived = { model.openNotifications(archived: true) }
        h.onOpen = { model.openFeedTarget($0) }
        return h
    }

    /// Where the History screens go (vettid-android `HistoryHost`): an entry over the list, back, the entry's connection,
    /// the credential alarm and the daily check (the export's refusals), and an item entry's item.
    var historyHost: HistoryHost {
        let model = model
        var h = HistoryHost()
        h.onOpenEntry = { model.openHistoryEntry($0) }
        h.onBack = { model.pop() }
        h.onOpenConnection = { model.push(.connection($0)) }
        h.onOpenAlarm = { model.push(.alarm) }
        h.onOwnerCheck = { model.ownerCheck(holdOff: false) }
        if items != nil { h.onOpenItem = { model.openItem($0) } }
        return h
    }

    /// Where the Approvals screens go: a decision over the current screen, and back.
    var approvalsHost: ApprovalsHost {
        let model = model
        var h = ApprovalsHost()
        h.onOpen = { model.push(.approval($0)) }
        h.onBack = { model.pop() }
        return h
    }
}
#endif
