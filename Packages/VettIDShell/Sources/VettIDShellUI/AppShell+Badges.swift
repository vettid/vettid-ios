#if os(iOS)
import SwiftUI
import VettIDData
import VettIDShell

extension AppShell {
    /// The drawer's counts (vettid-android `ShellBadges`): the approvals waiting for a decision, the conversations with
    /// unread messages, the open votes not yet voted on. Devices & agents has none: what a device asks for waits in Approvals.
    var badges: [TopLevelDestination: Int] {
        [
            .approvals: approvals?.approvals.count { $0.needsDecision } ?? 0,
            .messages: messages?.conversations.count { $0.unread > 0 } ?? 0,
            .votes: votes?.entry.badge ?? 0,
        ]
    }
}
#endif
