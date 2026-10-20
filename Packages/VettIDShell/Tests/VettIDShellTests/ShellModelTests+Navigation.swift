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
}
