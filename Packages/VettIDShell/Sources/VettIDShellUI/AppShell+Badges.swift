#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDData
import VettIDShell
import VettIDUI

extension AppShell {
    /// The drawer's counts (vettid-android `ShellBadges`): the open approvals, the same count as the approvals indicator's
    /// (ANDROID-PLAN §4 "The approvals indicator" 8), the conversations with unread messages, the open votes not yet voted on.
    /// Devices & agents has none: what a device asks for waits in Approvals.
    var badges: [TopLevelDestination: Int] {
        [
            .approvals: openApprovals.count,
            .messages: messages?.conversations.count { $0.unread > 0 } ?? 0,
            .votes: votes?.entry.badge ?? 0,
        ]
    }

    /// The open approvals at [approvalsNow] (ANDROID-PLAN §4 "The approvals indicator" 1, 3, 5): one source for the indicator
    /// and the drawer badge. A connection is named by its title, cleaned.
    var openApprovals: OpenApprovals {
        let names = Dictionary((connections?.connections ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        return OpenApprovalRules.of(approvals?.approvals ?? [], now: approvalsNow) { AccountNames.cleaned(names[$0]) }
    }

    /// The indicator the shell provides (2, 8): none while the vault is held or the check due, at the app lock, or at 0; a
    /// tap always opens the Approvals list, never a single request (6). The screens it is hidden on opt out themselves
    /// (``ShellIndicator``). vettid-android `approvalsIndicator`.
    func approvalsIndicator(locked: Bool) -> ApprovalsIndicator? {
        let open = openApprovals
        guard approvals != nil, !gate.gated, !locked, open.count > 0 else { return nil }
        return ApprovalsIndicator(
            count: open.count,
            critical: open.critical != nil,
            urgent: open.critical?.urgent == true,
            deadline: open.critical?.deadline,
            // A name the connection or device chose: isolated, as everywhere it is spoken (11).
            label: open.critical?.label.flatMap(AccountNames.isolateOrNull),
            onTap: { [model] in model.navigate(.approvals) }
        )
    }

    /// The instants at which the open approvals change by time alone (each deadline and the start of its last 2 minutes).
    var approvalsChangeAt: [Date] { OpenApprovalRules.changesAt(approvals?.approvals ?? []) }

    /// The approvals indicator for the screens of the stack, each of which may opt out.
    var indicator: ApprovalsIndicator? { approvalsIndicator(locked: appLocked) }
}

/// Moves [now] on at each of [points] without a new read (ANDROID-PLAN §4 "The approvals indicator" 3), and reads the time
/// again whenever the app comes back to the front (a sleep does not run while the phone sleeps). vettid-android
/// `deadlineClock` with its `resumed`.
struct ApprovalsClock: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let points: [Date]
    @Binding var now: Date

    func body(content: Content) -> some View {
        content.task(id: Key(points: points, phase: scenePhase)) {
            guard scenePhase == .active else { return }
            await DeadlineClock().run(points) { now = $0 }
        }
    }

    /// What restarts the clock: a change of the points, or of the scene phase (a return to the front).
    private struct Key: Equatable {
        let points: [Date]
        let phase: ScenePhase
    }
}
#endif
