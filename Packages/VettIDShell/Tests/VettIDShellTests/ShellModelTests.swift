import Foundation
import Testing
import VettIDData
@testable import VettIDShell

/// The shell's decisions: the drawer's destinations in vettid-android's order and groups, the avatar sheet's lines, the
/// owner check's notices.
@Suite struct ShellModelTests {
    let now = Date(timeIntervalSince1970: 1_791_384_000)

    /// vettid-android `TopLevelDestination`: Messages, Connections, Approvals | Vault, History | Settings, Help.
    @Test func theDrawerIsAndroids() {
        #expect(TopLevelDestination.sections == [[.messages, .connections, .approvals, .votes], [.items, .history], [.settings, .help]])
        let keys = ["messages", "connections", "approvals", "votes", "items", "history", "settings", "help"]
        #expect(TopLevelDestination.allCases.map(\.key) == keys)
        #expect(TopLevelDestination.fromKey("settings") == .settings && TopLevelDestination.fromKey("nope") == nil)
        #expect(TopLevelDestination.start == .messages)
        #expect(TopLevelDestination.allCases.filter(\.available) == [.settings, .help])
    }

    @Test func theVersion() {
        #expect(AppVersion.of(["CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "17"]) == AppVersion(name: "2.0.0", build: 17))
        #expect(AppVersion.of([:]) == AppVersion(name: "", build: 0))
    }

    /// vettid-android `AccountSheet`: the names, else the address, else the placeholder; under the names the address, else
    /// the membership.
    @Test func theSheetsHeader() {
        let named = AccountInfo(
            emailHint: "a***@example.com", state: "member", firstName: "Ada", lastName: "Lovelace", email: "ada@example.com"
        )
        #expect(AccountHeader.name(named, placeholder: "P") == "Ada Lovelace")
        #expect(AccountHeader.detailEmail(named) == "ada@example.com")
        #expect(AccountHeader.name(nil, placeholder: "P") == "P")
    }

    /// While the vault is not open (IOS-PLAN §4.7) the top bar and the sheet's header show no name and no address, not
    /// even the masked hint the account record keeps for the unlock screen: the placeholder and the initial tile. Mirrors
    /// vettid-android `AccountSheetTest.whileTheVaultIsNotOpenTheSheetShowsNoAddressAndNoName`.
    @Test func whileTheVaultIsNotOpenTheHeaderShowsNoAddressAndNoName() {
        let hint = AccountInfo(emailHint: "a***@example.com")
        #expect(AccountHeader.name(hint, placeholder: "P") == "P" && AccountHeader.detailEmail(hint) == nil)
        // Locked with a name request still in the record of an older build: nothing of it either.
        var held = hint
        held.nameRequest = NameRequestView(seq: 1, firstName: "Ada", lastName: "King", requestedAt: nil, state: .pending)
        #expect(AccountHeader.name(held, placeholder: "P") == "P")
        #expect(MembershipLine.of(hint) == .unknown)
    }

    @Test func theMembership() {
        #expect(MembershipLine.of(nil) == .unknown)
        #expect(MembershipLine.of(AccountInfo(emailHint: "x")) == .unknown)
        #expect(MembershipLine.of(AccountInfo(emailHint: "x", state: "member")) == .member)
        #expect(MembershipLine.of(AccountInfo(emailHint: "x", state: "registered")) == .registered)
        let deletes = now.addingTimeInterval(86_400)
        #expect(MembershipLine.of(AccountInfo(emailHint: "x", state: "member", accountStatus: "canceled", deletesAt: deletes))
            == .canceled(deletesAt: deletes))
    }

    /// A trial whose end passed reads expired; a blank name is the default name; an unknown status shows the name alone.
    @Test func theSubscription() {
        let until = now.addingTimeInterval(86_400)
        #expect(SubscriptionLine.of(nil, now: now) == SubscriptionLine.none)
        #expect(SubscriptionLine.of(SubscriptionInfo(typeName: "Annual", status: "trial", paid: false, expiresAt: until), now: now)
            == .trial(name: "Annual", until: until))
        #expect(SubscriptionLine.of(SubscriptionInfo(typeName: " ", status: "trial", paid: false, expiresAt: until), now: until)
            == .expired(name: nil))
        #expect(SubscriptionLine.of(SubscriptionInfo(typeName: nil, status: "active", paid: true, expiresAt: nil), now: now)
            == .active(name: nil, until: nil))
        #expect(SubscriptionLine.of(SubscriptionInfo(typeName: "A", status: "canceled", paid: true, expiresAt: until), now: until)
            == .canceled(name: "A"))
        #expect(SubscriptionLine.of(SubscriptionInfo(typeName: "A", status: "paused", paid: true, expiresAt: nil), now: now)
            == .other(name: "A"))
    }

    /// vettid-android `noticeText` and `holdChangedText`.
    @Test func theNoticesSayWhatHappened() {
        func notice(_ kind: String, _ ref: String?) -> OwnerCheckNotice {
            OwnerCheckNotice(itemID: "1", kind: kind, ref: ref, at: nil, urgent: false)
        }
        #expect(OwnerCheckNoticeText.of(notice("owner_check.locked", "10")) == .locked)
        #expect(OwnerCheckNoticeText.of(notice("owner_check.failed", "pin")) == .failedPin)
        #expect(OwnerCheckNoticeText.of(notice("owner_check.failed", "password")) == .failedPassword)
        #expect(OwnerCheckNoticeText.of(notice("owner_check.hold_changed", "off")) == .holdOff)
        #expect(OwnerCheckNoticeText.of(notice("owner_check.hold_changed", "on")) == .holdOn)
        #expect(OwnerCheckNoticeText.of(notice("owner_check.hold_changed", "on:expired")) == .holdExpired)
        #expect(OwnerCheckNoticeText.of(notice("owner_check.hold_changed", "off_until:2026-10-20T10:00:00Z"))
            == .holdOffUntil(Date(timeIntervalSince1970: 1_792_490_400)))
        #expect(OwnerCheckNoticeText.of(notice("owner_check.hold_changed", "off_until:garbage")) == .holdOff)
        #expect(OwnerCheckNoticeText.of(notice("owner_check.hold_changed", nil)) == .holdOn)
    }
}
