#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDApprovalsUI
import VettIDNotifications
import VettIDNotificationsUI
import VettIDShell

/// The Notifications screens (from the bell) and one approval's decision (from Approvals or a feed item): vettid-android's
/// `notificationsDestination` and `approvalsDestination`.
extension AppShell {
    @ViewBuilder func activityDetail(_ route: ShellRoute) -> some View {
        switch route {
        case .notifications(let archived):
            if let feed {
                NotificationsRoute(feed: feed, connections: connections, approvals: approvals, archived: archived, host: notificationsHost)
            }
        case .approval(let key):
            if let approvals { ApprovalDetailRoute(key, approvals: approvals, connections: connections, host: approvalsHost) }
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
