import Foundation
import Testing
import VettIDConnections
import VettIDData
import VettIDDataTesting
import VettIDOnboarding
@testable import VettIDShell

/// Where the member is in the shell: the drawer's navigation, the asked owner check, the lock from the avatar sheet.
/// Mirrors vettid-android `AppShell`'s behaviour.
@MainActor
@Suite struct ShellNavigationTests {
    let repo = FakeVaultRepository(.unlocked)
    var model: ShellModel { ShellModel(account: repo, vault: repo, ownerChecks: repo) }

    /// One copy of each top-level screen: a drawer destination drops what was pushed and closes the drawer; Settings'
    /// back arrow returns to the start.
    @Test func theDrawerNavigates() {
        let m = model
        #expect(m.destination == .messages)
        m.navigate(.settings)
        m.push(.vaultStatus)
        m.push(.attestation)
        m.pop()
        #expect(m.path == [.vaultStatus])
        m.drawerOpen = true
        m.navigate(.history)
        #expect(m.destination == .history && m.path.isEmpty && !m.drawerOpen)
        m.navigate(.settings)
        m.back()
        #expect(m.destination == .messages)
        m.pop()
        #expect(m.path.isEmpty)
    }

    /// "Change name" and "Shared profile" from the avatar sheet close it and open over the current screen (VAULT-MESSAGING
    /// §10.8); the shared profile's "Change name" opens over it.
    @Test func theAvatarSheetOpensTheNamesAndTheSharedProfile() {
        let m = model
        m.navigate(.settings)
        m.showAccount = true
        m.sharedProfile()
        #expect(!m.showAccount && m.path == [.sharedProfile])
        m.push(.changeName)
        #expect(m.path == [.sharedProfile, .changeName])
        m.pop()
        m.pop()
        m.showAccount = true
        m.changeName()
        #expect(!m.showAccount && m.path == [.changeName])
    }

    /// "Check now" asks the voluntary check; the hold switch turned off asks the hold-off check (VAULT-MESSAGING §3.6.7);
    /// either closes the sheet and the drawer.
    @Test func theHoldSwitchAsksTheHoldOffCheck() {
        let m = model
        m.showAccount = true
        m.ownerCheck(holdOff: false)
        #expect(m.asked == .voluntary && !m.showAccount)
        m.ownerCheckDone()
        #expect(m.asked == nil)
        m.drawerOpen = true
        m.ownerCheck(holdOff: true)
        #expect(m.asked == .holdOff && !m.drawerOpen)
        m.shown()
        #expect(m.asked == nil)
    }

    /// A lock or a gated check keeps nothing open; a lock starts the next open afresh.
    @Test func aResetStartsAfresh() {
        let m = model
        m.navigate(.settings)
        m.push(.attestation)
        m.showAccount = true
        m.reset()
        #expect(m.destination == .messages && m.path.isEmpty && !m.showAccount && m.asked == nil)
    }

    /// The connect flow (VAULT-MESSAGING §6.4): the scanner is replaced by the accept screen; an opened invitation link
    /// opens the accept screen over the current one, once, the drawer and the sheet closed (vettid-android `AppShell`).
    @Test func theConnectFlowAndAnOpenedInvitation() {
        let m = model
        m.navigate(.connections)
        m.push(.connect(.scan))
        m.replace(.connect(.accept(AcceptInput(link: "scanned"))))
        #expect(m.path == [.connect(.accept(AcceptInput(link: "scanned")))])
        m.pop()
        m.drawerOpen = true
        m.showAccount = true
        m.openInvite("an-opened-link")
        m.openInvite("an-opened-link")
        #expect(m.path == [.connect(.accept(AcceptInput(link: "an-opened-link", opened: true)))] && !m.drawerOpen && !m.showAccount)
        // The path never prints the link.
        #expect(!"\(m.path)".contains("an-opened-link") && !String(reflecting: m.path).contains("an-opened-link"))
        m.replace(.connect(.scan))
        #expect(m.path == [.connect(.scan)])
    }

    /// A connection's detail (VAULT-MESSAGING §10.4): pushed from the list; the accept screen's "Open the connection"
    /// takes the accept screen's place (vettid-android `host.replace`); a drawer destination drops it.
    @Test func aConnectionsDetail() {
        let m = model
        m.navigate(.connections)
        m.push(.connection("c1"))
        #expect(m.path == [.connection("c1")])
        m.pop()
        m.push(.connect(.accept(AcceptInput())))
        m.replace(.connection("c2"))
        #expect(m.path == [.connection("c2")])
        m.navigate(.connections)
        #expect(m.path.isEmpty && m.destination == .connections)
    }

    /// The messages (VAULT-MESSAGING §10.5): a conversation opens from Messages or the picker over the current screen,
    /// once if it is on top already (vettid-android's `launchSingleTop`); the connection's page from the conversation,
    /// and the conversation again from there; "Send a message" after connecting opens it over the accept screen.
    @Test func theMessagesFlow() {
        let m = model
        #expect(m.destination == .messages)
        m.push(.newMessage)
        m.openConversation("c1")
        m.openConversation("c1")
        #expect(m.path == [.newMessage, .conversation("c1")])
        m.push(.connection("c1"))
        m.openConversation("c1")
        #expect(m.path == [.newMessage, .conversation("c1"), .connection("c1"), .conversation("c1")])
        m.pop()
        m.pop()
        #expect(m.path == [.newMessage, .conversation("c1")])
        m.navigate(.connections)
        m.push(.connect(.accept(AcceptInput())))
        m.openConversation("c2")
        #expect(m.path == [.connect(.accept(AcceptInput())), .conversation("c2")])
        m.navigate(.messages)
        #expect(m.path.isEmpty && m.destination == .messages)
    }

    /// vettid-android `RootViewModel.lockVault`: the sheet closes and the vault locks; a lock that fails reads the phase
    /// again.
    @Test func lockVaultFromTheSheet() async {
        let m = model
        m.showAccount = true
        await m.lockVault()
        #expect(!m.showAccount && repo.calls.contains("lock") && repo.phase == .locked)
        repo.fail["lock"] = VaultFailure(.network)
        await m.lockVault()
        #expect(repo.calls.last == "refresh")
    }

    @Test func theBannersActions() async {
        repo.ownerCheck = OwnerCheckView(state: .ok, deadline: nil, hold: false)
        let m = model
        await m.turnHoldOn()
        #expect(repo.ownerCheck?.hold == true)
        await m.dismissNotices()
        #expect(repo.calls.contains("turnHoldOn"))
    }

    /// The bell opens Notifications once; a feed item's target opens its screen as vettid-android's `openFeedTarget`.
    @Test func theBellAndAFeedItemOpenTheirScreens() {
        let m = model
        m.openNotifications()
        m.openNotifications()
        #expect(m.path == [.notifications(archived: false)])
        m.openNotifications(archived: true)
        m.openFeedTarget(.approval(key: "grant:g1"))
        m.openFeedTarget(.approval(key: "grant:g1"))
        #expect(m.path == [.notifications(archived: false), .notifications(archived: true), .approval("grant:g1")])
        m.path = [.notifications(archived: false)]
        m.openFeedTarget(.conversation("c1"))
        m.openFeedTarget(.connection("c2"))
        m.openFeedTarget(.sharedWithYou("c3"))
        m.openFeedTarget(.shareRule(connectionID: "c4", ruleID: "r"))
        m.openFeedTarget(.alarm)
        m.openFeedTarget(.credential)
        m.openFeedTarget(.devices)
        m.openFeedTarget(.item("i"))
        m.openFeedTarget(.sheet)
        #expect(m.path == [
            .notifications(archived: false), .conversation("c1"), .connection("c2"), .sharedWithYou(connectionID: "c3", ask: false),
            .ruleEdit(connectionID: "c4", ruleID: "r"), .alarm, .credential, .vaultStatus, .item("i"),
        ])
        // An item once (a History entry's "Open the item" over the item it opened).
        m.openItem("i")
        #expect(m.path.last == .item("i") && m.path.count { $0 == .item("i") } == 1)
        m.openFeedTarget(.connections)
        #expect(m.destination == .connections && m.path.isEmpty)
        m.openFeedTarget(.history)
        #expect(m.destination == .history)
        m.push(.notifications(archived: false))
        m.openFeedTarget(.security)
        #expect(m.destination == .settings && m.path.isEmpty)
    }

    /// History's entry over the list, and a connection's History over its page, each once.
    @Test func historyEntriesAndAConnectionsHistoryOpenOnce() {
        let m = model
        m.navigate(.history)
        m.openHistoryEntry(12)
        m.openHistoryEntry(12)
        #expect(m.destination == .history && m.path == [.historyEntry(12)])
        m.navigate(.connections)
        m.push(.connection("c1"))
        m.openConnectionHistory("c1")
        m.openConnectionHistory("c1")
        m.openHistoryEntry(3)
        #expect(m.path == [.connection("c1"), .connectionHistory("c1"), .historyEntry(3)])
    }

    /// What a connection can see, a share rule of it and what it shares open over its page, each once (IOS-PLAN §8 I3.2); a
    /// new rule has no rule id, and a tag another rule shares opens that rule over the editor.
    @Test func theSharingScreensOpenOnce() {
        let m = model
        m.navigate(.connections)
        m.push(.connection("c1"))
        m.openSharing("c1")
        m.openSharing("c1")
        m.openRule("c1", nil)
        m.openRule("c1", nil)
        m.openRule("c1", "r1")
        let rules: [ShellRoute] = [.ruleEdit(connectionID: "c1", ruleID: nil), .ruleEdit(connectionID: "c1", ruleID: "r1")]
        #expect(m.path == [.connection("c1"), .connectionSharing("c1")] + rules)
        m.navigate(.connections)
        m.push(.connection("c2"))
        m.openShared("c2")
        m.openShared("c2")
        m.openShared("c2", ask: true)
        let shared: [ShellRoute] = [.sharedWithYou(connectionID: "c2", ask: false), .sharedWithYou(connectionID: "c2", ask: true)]
        #expect(m.path == [.connection("c2")] + shared)
    }
}
