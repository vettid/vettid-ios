#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
import VettIDKeys
import VettIDOnboarding
import VettIDSettings
import VettIDShell
@testable import VettIDShellUI
import VettIDUI

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
        #expect(keys.count == 74)
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
        #expect(ShellStrings.alarmBanner == "Your credential was presented by another device")
        #expect(ShellStrings.rotateOffer == "You can now rotate your vault's keys: every older copy of your credential stops working.")
        #expect(ShellStrings.rotateOfferAction == "Rotate now")
    }

    /// vettid-android `OwnerCheckBanners`: the warning names the deadline's time, the hold-off its end; a notice says when
    /// and how many more.
    @Test func theBannersSayWhatIsDue() {
        let deadline = now.addingTimeInterval(1_800)
        #expect(OwnerCheckBanners.warningText(deadline) == "Your daily check is due at \(ShellTimes.time(deadline)).")
        #expect(OwnerCheckBanners.warningText(nil) == "Your daily check is due within the hour.")
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
