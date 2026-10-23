#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
import VettIDHistory
import VettIDKeys
import VettIDOnboarding
import VettIDSettings
import VettIDShell
@testable import VettIDShellUI
import VettIDUI
import VettIDVault

/// The shell: its texts (vettid-android's, word for word), the owner check's banners and the avatar sheet's lines, and
/// every view rendered.
@MainActor
@Suite struct ShellScreensTests {
    let now = Date(timeIntervalSince1970: 1_791_384_000)

    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDShellUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 78)
        let missing = "\u{0}missing"
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            let prefixes = [
                "nav_", "drawer_", "account_", "owner_check_", "ownercheck_", "settings_", "ios_", "release_banner_", "credential_alarm_",
                "rotate_offer",
            ]
            #expect(prefixes.contains { key.hasPrefix($0) }, "\(key)")
        }
    }

    @Test func theTextsAreAndroids() {
        let labels = ["Messages", "Connections", "Approvals", "Vault", "History", "Settings", "Help"]
        #expect(TopLevelDestination.allCases.map(\.label) == labels)
        #expect(ShellStrings.drawerVersion("2.0.0", 1) == "VettID 2.0.0 (1)")
        #expect(ShellStrings.ownerCheckWarning("3:00 PM") == "Your daily check is due at 3:00 PM.")
        #expect(ShellStrings.ownerCheckNoticeMore("A daily check failed: wrong PIN.", 2) == "A daily check failed: wrong PIN. And 2 more.")
        #expect(ShellStrings.accountSubscriptionTrialUntil("Annual", "Dec 1") == "Annual: trial until Dec 1")
        #expect(ShellStrings.accountEmailNote == "Only you see this address.")
        #expect(ShellStrings.renewPromptAction == "New phone secret")
        #expect(ShellStrings.accountChangeNameBody == "Only here, in the app, with your PIN and password")
        #expect(ShellStrings.accountSharedProfile == "Shared profile")
        #expect(ShellStrings.accountSharedProfileBody == "Display name and what your connections see")
        #expect(ShellStrings.alarmBanner == "Your credential was presented by another device")
        #expect(ShellStrings.rotateOffer == "You can now rotate your vault's keys: every older copy of your credential stops working.")
        #expect(ShellStrings.rotateOfferAction == "Rotate now")
    }

    /// The texts that name a scaled wait: in real time the approved words verbatim (ANDROID-PLAN §4 "Recovery and unlock
    /// from release R"; VAULT-MESSAGING §3.6.5), on a scaled vault the computed duration (the owner's decision of
    /// 2026-10-19).
    @Test func theScaledWaitsSayTheApprovedWordsInRealTime() {
        let view = OwnerCheckView(state: .ok, deadline: now.addingTimeInterval(1_800))
        let real = OwnerCheckGate.of(view, now: now)
        #expect(OwnerCheckBanners.warningText(nil, scaledAhead: real.scaledWarningText) == "Your daily check is due within the hour.")
        #expect(OwnerCheckBanners.presenceBody(real.scaledQuietText) == """
            If this stays for three days, your vault is no longer protected against a recovery started by someone else. \
            Try again later. If it does not go away, contact VettID.
            """)
        let staging = OwnerCheckGate.of(view, now: now, timeScale: 24)
        #expect(OwnerCheckBanners.warningText(nil, scaledAhead: staging.scaledWarningText)
            == "Your daily check is due within 150 seconds.")
        #expect(OwnerCheckBanners.presenceBody(staging.scaledQuietText) == """
            If this stays for 3 hours, your vault is no longer protected against a recovery started by someone else. \
            Try again later. If it does not go away, contact VettID.
            """)
    }

    /// vettid-android `OwnerCheckBanners`: the warning names the deadline's time, the hold-off its end; a notice says when
    /// and how many more.
    @Test func theBannersSayWhatIsDue() {
        let deadline = now.addingTimeInterval(1_800)
        #expect(OwnerCheckBanners.warningText(deadline) == "Your daily check is due at \(ShellTimes.time(deadline)).")
        #expect(OwnerCheckBanners.warningText(nil) == "Your daily check is due within the hour.")
        #expect(OwnerCheckBanners.warningText(deadline, scaledAhead: "150 seconds")
            == "Your daily check is due at \(ShellTimes.time(deadline)).")
        #expect(OwnerCheckBanners.holdOffText(nil) == "The hold is off.")
        let failed = OwnerCheckNotice(itemID: "1", kind: "owner_check.failed", ref: "password", at: nil, urgent: true)
        #expect(OwnerCheckBanners.noticeText(failed, count: 1, now: now) == "A daily check failed: wrong credential password.")
        let at = OwnerCheckNotice(itemID: "2", kind: "owner_check.locked", ref: nil, at: now, urgent: true)
        #expect(OwnerCheckBanners.noticeText(at, count: 3, now: now)
            == "Your vault locked after ten wrong daily checks. (\(ShellTimes.time(now))) And 2 more.")
    }

    /// The release banner (RELEASE-UPDATES §2): vettid-android's texts, "available" or the end-date warning.
    @Test func theReleaseBanner() {
        func rel(_ n: UInt64, _ status: String = "active", _ endsAt: Date? = nil) -> ReleaseView {
            ReleaseView(number: n, pcr0: String(repeating: "ab", count: 48), status: status, endsAt: endsAt, notes: "")
        }
        #expect(ShellStrings.releaseBannerAvailable(18) == "A new vault release is available (release 18).")
        #expect(ShellStrings.releaseBannerUpdate == "Update now")
        let ending = ReleaseUpdateOffer(current: rel(17, "retired"), target: rel(18))
        #expect(ReleaseUpdateBanner.text(ending) == "Your vault's release is ending. Update now to keep your vault.")
        let ended = ReleaseUpdateOffer(current: rel(17, "removed"), target: rel(18))
        #expect(ReleaseUpdateBanner.text(ended) == "Your vault's release has ended. Update now to keep your vault.")
        let dated = ReleaseUpdateOffer(current: rel(17, "deprecated", now), target: rel(18))
        #expect(ReleaseUpdateBanner.text(dated).hasPrefix("Your vault's release ends on "))
        for o in [ReleaseUpdateOffer(current: rel(17, "active"), target: rel(18)), ending, ended, dated] {
            #expect(height(ReleaseUpdateBanner.banner(o, onUpdate: {}, onDismiss: {})) > 0)
        }
        let updates = FakeReleaseUpdates(offer: ending)
        #expect(height(ReleaseUpdateBanner(updates: updates) {}) > 0)
    }

    @Test func theAccountDetails() {
        let until = now.addingTimeInterval(86_400)
        #expect(AccountDetails.membership(.canceled(deletesAt: until))
            == "Account cancelled: your vault is deleted on \(ShellTimes.full(until))")
        #expect(AccountDetails.membership(.registered) == "Registered, not yet a member")
        #expect(AccountDetails.subscription(.none) == "No subscription")
        #expect(AccountDetails.subscription(.active(name: nil, until: nil)) == "Subscription: active")
        #expect(AccountDetails.subscription(.expired(name: "Annual")) == "Annual: expired")
        #expect(AccountDetails.subscription(.other(name: nil)) == "Subscription")
        #expect(AccountSheet.membershipLine(.unknown) == "VettID account")
    }

    /// While the vault is not open (IOS-PLAN §4.7) the sheet shows no name and no address, not even the masked hint the
    /// account record keeps for the unlock screen; the open vault's address is shown. Mirrors vettid-android
    /// `AccountSheetTest.whileTheVaultIsNotOpenTheSheetShowsNoAddressAndNoName` and `theOpenVaultsAddressIsShown`.
    @Test func whileTheVaultIsNotOpenTheSheetShowsNoAddressAndNoName() {
        let locked = AccountInfo(emailHint: "s***@example.org")
        #expect(AccountSheet(account: locked, now: now, onLockVault: {}, onOpenPortal: {}).account == nil)
        #expect(height(AccountSheet(account: locked, now: now, onLockVault: {}, onOpenPortal: {})) > 0)
        let open = AccountInfo(
            emailHint: "s***@example.org", state: "member", firstName: "Sam", lastName: "Rivera", email: "sam@example.org"
        )
        #expect(AccountSheet(account: open, now: now, onLockVault: {}, onOpenPortal: {}).account == open)
    }

    @Test func everyViewRenders() {
        let member = AccountInfo(
            emailHint: "a***@example.com", state: "member", termsNeedAcceptance: true,
            subscription: SubscriptionInfo(typeName: "Annual", status: "trial", paid: false, expiresAt: now.addingTimeInterval(86_400)),
            firstName: "Ada", lastName: "Lovelace"
        )
        var pending = member
        pending.nameRequest = NameRequestView(seq: 1, firstName: "Ada", lastName: "King", requestedAt: nil, state: .pending)
        for a in [nil, AccountInfo(emailHint: "a***@example.com"), member, pending] {
            #expect(height(AccountSheet(account: a, now: now, onLockVault: {}, onOpenPortal: {})) > 0)
        }
        let notice = OwnerCheckNotice(itemID: "1", kind: "owner_check.hold_changed", ref: "off", at: now, urgent: false)
        let gate = OwnerCheckGate(gated: false, warning: true, holdOff: true, notices: [notice], presenceUnrecorded: true)
        #expect(height(OwnerCheckBanners(gate: gate, now: now, onCheckNow: {}, onHoldOn: {}, onDismissNotices: {})) > 0)
        let chrome = ShellChrome(accountName: "Ada", onMenu: {}, onAvatar: {})
        for d in TopLevelDestination.allCases {
            #expect(height(ComingLaterScreen(destination: d, chrome: chrome)) > 0)
        }
        let repo = FakeVaultRepository(.unlocked)
        repo.account = member
        let shell = AppShell(
            account: repo, vault: repo, ownerChecks: repo, credential: repo, profiles: repo, appLock: StillAppLock(),
            model: ShellModel(account: repo, vault: repo, ownerChecks: repo), gate: gate, now: now,
            version: AppVersion(name: "2.0.0", build: 1), installedFrom: .apple, promptReason: "Unlock VettID"
        ) {}
        #expect(height(shell) > 0)
        // Connections: the list in the placeholder's place, and a connection's detail over it.
        let connections = FakeConnections()
        var c = ConnectionInfo(id: "c1", name: "", state: .active)
        c.firstName = "Ada"
        c.lastName = "Lovelace"
        connections.connections = [c]
        let model = ShellModel(account: repo, vault: repo, ownerChecks: repo)
        model.navigate(.connections)
        for path in [[], [ShellRoute.connection("c1")]] {
            model.path = path
            let withConnections = AppShell(
                account: repo, vault: repo, ownerChecks: repo, credential: repo, profiles: repo, appLock: StillAppLock(),
                model: model, gate: gate, now: now, version: AppVersion(name: "2.0.0", build: 1), installedFrom: .apple,
                promptReason: "Unlock VettID", connections: connections, connectionRequests: connections
            ) {}
            #expect(height(withConnections) > 0)
        }
    }

    /// Messages: the list in the placeholder's place, the picker and a conversation over it.
    @Test func theMessagesRender() {
        let repo = FakeVaultRepository(.unlocked)
        let gate = OwnerCheckGate(gated: false, warning: false, holdOff: false, notices: [], presenceUnrecorded: false)
        let connections = FakeConnections()
        var c = ConnectionInfo(id: "c1", name: "", state: .active)
        c.firstName = "Ada"
        connections.connections = [c]
        let messages = FakeMessages()
        messages.connections = connections.connections
        let model = ShellModel(account: repo, vault: repo, ownerChecks: repo)
        let attachments = FakeAttachments()
        let photo = ShellRoute.photo(connectionID: "c1", messageID: "m1")
        let routes = [[], [ShellRoute.newMessage], [ShellRoute.conversation("c1")], [.conversation("c1"), photo]]
        for path in routes {
            model.path = path
            let withMessages = AppShell(
                account: repo, vault: repo, ownerChecks: repo, credential: repo, profiles: repo, appLock: StillAppLock(),
                model: model, gate: gate, now: now, version: AppVersion(name: "2.0.0", build: 1), installedFrom: .apple,
                promptReason: "Unlock VettID", connections: connections, connectionRequests: connections, messages: messages,
                attachments: attachments
            ) {}
            #expect(height(withMessages) > 0)
        }
    }

    /// What a connection can see, a share rule and what it shares, over the Vault's items and tags.
    @Test func theSharingScreensRender() {
        let repo = FakeVaultRepository(.unlocked)
        let gate = OwnerCheckGate(gated: false, warning: false, holdOff: false, notices: [], presenceUnrecorded: false)
        let connections = FakeConnections()
        var c = ConnectionInfo(id: "c1", name: "", state: .active)
        c.firstName = "Ada"
        connections.connections = [c]
        let model = ShellModel(account: repo, vault: repo, ownerChecks: repo)
        let routes: [[ShellRoute]] = [
            [.connectionSharing("c1")], [.ruleEdit(connectionID: "c1", ruleID: nil)], [.ruleEdit(connectionID: "c1", ruleID: "r1")],
            [.sharedWithYou(connectionID: "c1", ask: false)], [.sharedWithYou(connectionID: "c1", ask: true)],
        ]
        for path in routes {
            model.path = path
            let shell = AppShell(
                account: repo, vault: repo, ownerChecks: repo, credential: repo, profiles: repo, appLock: StillAppLock(),
                model: model, gate: gate, now: now, version: AppVersion(name: "2.0.0", build: 1), installedFrom: .apple,
                promptReason: "Unlock VettID", connections: connections, items: FakeItems(), sharing: FakeSharing()
            ) {}
            #expect(height(shell) > 0)
        }
        // The Vault's host opens a rule, the sharing screen and what is shared over the page, as the model does.
        model.path = [.connection("c1")]
        let shell = AppShell(
            account: repo, vault: repo, ownerChecks: repo, credential: repo, profiles: repo, appLock: StillAppLock(),
            model: model, gate: gate, now: now, version: AppVersion(name: "2.0.0", build: 1), installedFrom: .apple,
            promptReason: "Unlock VettID", connections: connections, items: FakeItems(), sharing: FakeSharing()
        ) {}
        shell.itemsHost.onOpenRule("c1", nil)
        shell.itemsHost.onOpenRule("c1", "r1")
        #expect(model.path == [.connection("c1"), .ruleEdit(connectionID: "c1", ruleID: nil), .ruleEdit(connectionID: "c1", ruleID: "r1")])
        // The connection page's hooks: Manage, Shared with you, "Ask for something", a new rule and a rule.
        model.path = [.connection("c1")]
        let host = shell.connectHost
        host.onOpenSharing?("c1")
        host.onOpenShared?("c1")
        host.onAskFor?("c1")
        host.onOpenShareRule?("c1", nil)
        host.onOpenShareRule?("c1", "r2")
        #expect(model.path == [
            .connection("c1"), .connectionSharing("c1"), .sharedWithYou(connectionID: "c1", ask: false),
            .sharedWithYou(connectionID: "c1", ask: true), .ruleEdit(connectionID: "c1", ruleID: nil),
            .ruleEdit(connectionID: "c1", ruleID: "r2"),
        ])
    }

    /// Approvals in the placeholder's place, a decision and the Notifications screens over it; the drawer's counts.
    @Test func theApprovalsAndNotificationsRender() {
        let repo = FakeVaultRepository(.unlocked)
        let gate = OwnerCheckGate(gated: false, warning: false, holdOff: false, notices: [], presenceUnrecorded: false)
        let connections = FakeConnections()
        let request = ConnectionRequest(pendingID: "p1", sas: "123456", remote: false, name: "Ada Lovelace", receivedAt: now, exp: nil)
        connections.requests = [.incoming(request)]
        let approvals = FakeApprovals(connections: connections)
        let feed = FakeFeed()
        feed.items = [
            FeedItem(
                itemID: "f1", seq: 1, kind: "recovery.attempt", at: "2026-10-19T12:00:00.000Z", status: "active", priority: "urgent",
                ref: "2/3/not_success/counter"
            ),
        ]
        let model = ShellModel(account: repo, vault: repo, ownerChecks: repo)
        model.navigate(.approvals)
        let routes: [[ShellRoute]] = [[], [.approval("connection:p1")], [.notifications(archived: false)], [.notifications(archived: true)]]
        for path in routes {
            model.path = path
            let shell = AppShell(
                account: repo, vault: repo, ownerChecks: repo, credential: repo, profiles: repo, appLock: StillAppLock(),
                model: model, gate: gate, now: now, version: AppVersion(name: "2.0.0", build: 1), installedFrom: .apple,
                promptReason: "Unlock VettID", connections: connections, connectionRequests: connections, feed: feed, approvals: approvals
            ) {}
            #expect(height(shell) > 0)
        }
        let items = TopLevelDestination.drawerSections(badges: [.approvals: 1]).flatMap { $0 }
        #expect(items.first { $0.key == "approvals" }?.badge == 1 && items.first { $0.key == "messages" }?.badge == 0)
    }

    /// History in the placeholder's place, an entry and a connection's History over it; a connection's page offers it.
    @Test func theHistoryRenders() {
        let repo = FakeVaultRepository(.unlocked)
        let gate = OwnerCheckGate(gated: false, warning: false, holdOff: false, notices: [], presenceUnrecorded: false)
        let connections = FakeConnections()
        connections.connections = [ConnectionInfo(id: "c1", name: "", state: .active)]
        let log = FakeAuditLog(FakeAuditLog.chain(5, connection: "c1"))
        let history = HistoryManager { log }
        let export = HistoryExportManager { log }
        let model = ShellModel(account: repo, vault: repo, ownerChecks: repo)
        model.navigate(.history)
        for path: [ShellRoute] in [[], [.historyEntry(3)], [.connection("c1")], [.connection("c1"), .connectionHistory("c1")]] {
            model.path = path
            let shell = AppShell(
                account: repo, vault: repo, ownerChecks: repo, credential: repo, profiles: repo, appLock: StillAppLock(),
                model: model, gate: gate, now: now, version: AppVersion(name: "2.0.0", build: 1), installedFrom: .apple,
                promptReason: "Unlock VettID", connections: connections, connectionRequests: connections, history: history,
                historyExport: export
            ) {}
            #expect(height(shell) > 0)
        }
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.dark)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}

/// An app lock that is off and stays so.
@MainActor
@Observable
final class StillAppLock: AppLockSettings {
    var state: AppLockState = .disabled
    var invalidated = false
    var method: AppLockMethod = .biometrics
    var timeout: AppLockTimeout = .standard

    func enable(_ m: AppLockMethod, reason: String) async throws -> Bool { false }
    func disable() throws {}
    func chooseMethod(_ m: AppLockMethod) throws {}
    func setTimeout(_ t: AppLockTimeout) throws {}
    func acknowledgeInvalidated() {}
}
#endif
