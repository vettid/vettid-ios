import Foundation
import Observation
import VettIDConnections
import VettIDData
import VettIDOnboarding

/// What the shell shows and where the member is: the destination, the screens pushed over it, the drawer, the avatar
/// sheet, and the owner check the member asked for. Owned above the owner check's gate (VAULT-MESSAGING §3.6.5), so that
/// a check past the deadline, which takes the place of the whole shell, leaves the member where they were. Mirrors the
/// state of vettid-android `AppShell` (its NavController, drawer state, `showAccount` and `asked`).
@MainActor
@Observable
public final class ShellModel {
    public private(set) var destination = TopLevelDestination.start
    public var path: [ShellRoute] = []
    public var drawerOpen = false
    public var showAccount = false
    /// The voluntary check or the hold-off check, shown over the shell; nil: none.
    public private(set) var asked: OwnerCheckMode?

    @ObservationIgnored private let account: any AccountRepository
    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let ownerChecks: any OwnerCheckRepository

    public init(account: any AccountRepository, vault: any VaultRepository, ownerChecks: any OwnerCheckRepository) {
        self.account = account
        self.vault = vault
        self.ownerChecks = ownerChecks
    }

    /// Drawer navigation: one copy of each top-level screen, its pushed screens dropped, the drawer closed.
    public func navigate(_ d: TopLevelDestination) {
        path = []
        destination = d
        drawerOpen = false
    }

    /// Settings' back arrow: the start destination, as vettid-android's back stack returns to it.
    public func back() { navigate(.start) }

    public func push(_ r: ShellRoute) { path.append(r) }

    /// "Change name" from the avatar sheet: the sheet closes and the name change opens over the current screen.
    public func changeName() {
        showAccount = false
        push(.changeName)
    }

    /// "Shared profile" from the avatar sheet: the sheet closes and the shared profile opens over the current screen.
    public func sharedProfile() {
        showAccount = false
        push(.sharedProfile)
    }

    public func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    /// Replaces the screen on top (the connect flow's scanner with the accept screen, and back), as vettid-android's
    /// `host.replace` does.
    public func replace(_ r: ShellRoute) {
        if !path.isEmpty { path.removeLast() }
        path.append(r)
    }

    /// A conversation over the current screen, unless it is the one on top already (vettid-android's `launchSingleTop`
    /// for `ConversationRoute`).
    public func openConversation(_ connectionID: String) {
        let route = ShellRoute.conversation(connectionID)
        if path.last != route { push(route) }
    }

    /// The bell: the Notifications screen (or its Archived view) over the current screen, once.
    public func openNotifications(archived: Bool = false) {
        let route = ShellRoute.notifications(archived: archived)
        if path.last != route { push(route) }
    }

    /// The screen a feed item opens (ANDROID-PLAN §4 Notifications, 4), as vettid-android's `openFeedTarget`: Connections,
    /// History and Settings (the daily check) as drawer destinations, the others over the current screen. A target whose
    /// screen the iPhone app does not have yet goes to the nearest one (chosen; not in the spec): Shared with you and a
    /// share rule to the connection's page (IOS-PLAN §8 I3.2). An item (Vault, I3.1) and ``FeedTarget/sheet`` stay with
    /// the Notifications screen's sheet.
    public func openFeedTarget(_ t: FeedTarget) {
        switch t {
        case .connections: navigate(.connections)
        case .history: navigate(.history)
        case .security: navigate(.settings)
        case .devices: pushOnce(.vaultStatus)
        case .approval(let key): pushOnce(.approval(key))
        case .connection(let id), .sharedWithYou(let id), .shareRule(let id, _): pushOnce(.connection(id))
        case .conversation(let id): openConversation(id)
        case .alarm: pushOnce(.alarm)
        case .credential: pushOnce(.credential)
        case .item, .sheet: break
        }
    }

    /// A History entry over History, once.
    public func openHistoryEntry(_ seq: Int64) { pushOnce(.historyEntry(seq)) }

    /// A connection's History over its page, once.
    public func openConnectionHistory(_ connectionID: String) { pushOnce(.connectionHistory(connectionID)) }

    private func pushOnce(_ r: ShellRoute) {
        if path.last != r { push(r) }
    }

    /// An invitation link the app was opened with (VAULT-MESSAGING §6.4, IOS-PLAN §6.8): the accept screen over the
    /// current one (also a VettID invitation confirmed in a message), where the member confirms before anything is sent.
    /// The drawer and the sheet close. Mirrors vettid-android `AppShell`'s `inviteLink`.
    public func openInvite(_ link: String) {
        showAccount = false
        drawerOpen = false
        let route = ShellRoute.connect(.accept(AcceptInput(link: link, opened: true)))
        if path.last == route { return }
        push(route)
    }

    /// "Check now" (the banner, Settings) or, with [holdOff], turning the hold off, which only a check may do
    /// (VAULT-MESSAGING §3.6.7). The sheet and the drawer close.
    public func ownerCheck(holdOff: Bool) {
        asked = holdOff ? .holdOff : .voluntary
        showAccount = false
        drawerOpen = false
    }

    /// The asked check passed or was cancelled.
    public func ownerCheckDone() { asked = nil }

    /// The check past the deadline took the shell's place: nothing the shell had open (the drawer, the sheet, an asked
    /// check) comes back with it.
    public func shown() {
        asked = nil
        showAccount = false
        drawerOpen = false
    }

    /// The vault was locked or left: the next open starts afresh, as vettid-android's new shell does.
    public func reset() {
        shown()
        path = []
        destination = .start
    }

    /// "Lock vault" from the avatar sheet: the sheet closes, the phone is locked at once (the root shows the unlock
    /// screen). A lock that fails reads the phase again, as vettid-android's `RootViewModel.lockVault` does.
    public func lockVault() async {
        showAccount = false
        do {
            try await vault.lock()
        } catch {
            try? await account.refresh()
        }
    }

    /// The hold-off indicator's "Turn on": a failure leaves the indicator; Settings shows it when the member tries there.
    public func turnHoldOn() async { try? await ownerChecks.turnHoldOn() }

    public func dismissNotices() async { try? await ownerChecks.dismissNotices() }
}
