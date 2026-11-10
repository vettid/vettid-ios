#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

/// Settings, Vault status and Attestation: their texts (vettid-android's, word for word; IOS-PLAN ID15's) and every state
/// rendered.
@MainActor
@Suite struct SettingsScreensTests {
    let now = Date(timeIntervalSince1970: 1_791_384_000)

    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDSettingsUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 472)
        let missing = "\u{0}missing"
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            // `root_change_`: the one-time notice of a change's decision, under the Android app module's keys.
            let prefixes = [
                "settings_", "credential_", "canary_", "root_change_", "help_", "ios_settings_", "ios_credential_", "ios_app_lock_",
                "ios_help_",
            ]
            #expect(prefixes.contains { key.hasPrefix($0) }, "\(key)")
        }
    }

    @Test func theTextsAreAndroids() {
        #expect(SettingsStrings.vaultLockBody == "Locks your vault now. You need your PIN to open it again.")
        #expect(SettingsStrings.vaultUpdate == "Update available")
        #expect(SettingsStrings.vaultUpdateBody(5, 4) == "Release 5 (your vault runs release 4)")
        #expect(SettingsStrings.ownerCheckEvery(1) == "Every hour")
        #expect(SettingsStrings.ownerCheckEvery(4) == "Every 4 hours")
        #expect(SettingsStrings.ownerCheckNext("Oct 18") == "next by Oct 18")
        // Release L (VAULT-MESSAGING §3.6.8): the idle lock's setting, as ANDROID-PLAN §4 "Locking the vault" part 2 words it.
        #expect(SettingsStrings.idleLock == "Lock my vault by itself after")
        #expect(SettingsStrings.idleLockNextCheck == "This takes effect after your next check.")
        #expect(SettingsStrings.idleLockBody
            == "If you don't pass the daily check for this long, your vault locks itself and stops receiving until you unlock it.")
        #expect(IdleLockSetting.choices.map { OwnerCheckSettingsRows.idleLockUnits($0) }
            == ["1 hour", "1 day", "7 days", "14 days", "30 days"])
        #expect(SettingsStrings.statusReleaseValue(3, "active") == "Release 3 (active)")
        #expect(SettingsStrings.statusAdvisory
            == "Status comes from the account service and is for information only; your vault's own answers decide.")
        #expect(SettingsStrings.attestationReleaseValue(3, "a3a3 a3a3") == "Release 3 · a3a3 a3a3")
        #expect(VaultStatusContent.recoveryLine(.armed(used: 0)) == "Recovery: on. Attempts used: 0 of 10.")
        #expect(VaultStatusContent.recoveryLine(.unknown) == "Recovery: cannot be checked right now.")
    }

    /// Settings → App → Theme: vettid-android's texts, its three choices in its order.
    @Test func theThemeRowIsAndroids() {
        #expect(SettingsStrings.appTheme == "Theme")
        #expect(ThemePreference.allCases.map(SettingsContent.themeLabel) == ["System default", "Light", "Dark"])
        for t in ThemePreference.allCases {
            #expect(height(SettingsContent(state: SettingsState(theme: t), now: now)) > 0)
        }
    }

    /// Settings → App → "Show in notifications": vettid-android's texts (Notification settings), its three choices in its
    /// order, each with its line; the row only with the app's setting.
    @Test func whatNotificationsShowIsAndroids() {
        #expect(SettingsStrings.notifyShow == "Show in notifications")
        #expect(NotificationPreviews.allCases.map(SettingsContent.previewsLabel) == ["Names", "Names and message text", "Nothing"])
        #expect(NotificationPreviews.allCases.map(SettingsContent.previewsDetail) == [
            "Who it is from and what it is, never message text or item names",
            "Also the message text and item names, never values or secrets",
            "“New activity in VettID” for everything",
        ])
        for p in NotificationPreviews.allCases {
            #expect(height(SettingsContent(state: SettingsState(notificationPreviews: p), now: now)) > 0)
        }
    }

    /// Help: vettid-android's sections, rows and pages, word for word; the iPhone's own texts of IOS-PLAN ID18 and ID11.
    @Test func helpIsAndroids() {
        #expect(HelpStrings.title == "Help")
        #expect(HelpStrings.sectionLearn == "Learn")
        #expect(HelpStrings.sectionSupport == "Support")
        #expect(HelpScreen.learn.map(\.label) == ["About VettID", "How VettID protects you"])
        #expect(HelpScreen.learn.map(\.url) == ["https://vettid.org/about", "https://vettid.org/security"])
        #expect(HelpScreen.support.map(\.label) == ["Contact us"])
        #expect(HelpScreen.support.map(\.url) == ["https://vettid.org/contact"])
        for link in HelpScreen.learn + HelpScreen.support {
            #expect(URL(string: link.url)?.scheme == "https", "\(link.url)")
        }
        #expect(HelpStrings.privacy == "Privacy" && HelpStrings.keyboards == "Keyboards")
        #expect(HelpStrings.privacyBody == """
            When you set up, move or recover a vault, your iPhone asks Apple to vouch for the VettID app. Apple learns that \
            VettID was set up on an iPhone, nothing about your vault.
            """)
        #expect(HelpStrings.keyboardsBody
            == "VettID uses only Apple's keyboard, so that other keyboards never see your PIN, password or codes.")
        #expect(height(HelpScreen {}) > 0)
    }

    /// "Delete your VettID account" (the account, not the vault) is hidden while the account site has no deletion page, and
    /// shown once the one constant is set (chosen; not in the spec).
    @Test func deleteYourAccountShowsOnceTheAccountSiteHasAPage() throws {
        // The page is the environment's account site's: Release's and Staging's own.
        #expect(AccountDeletion.url(origin: "https://account.vettid.org")?.absoluteString == "https://account.vettid.org/account/delete/")
        #expect(AccountDeletion.url(origin: "https://account.staging.vettid.org")?.host == "account.staging.vettid.org")
        #expect(EnvironmentValues().accountDeletionURL == nil)
        #expect(!SettingsContent(state: SettingsState()).accountDeletionShown)
        // Without a page the row is hidden; with one it is shown.
        #expect(!SettingsContent(state: SettingsState(), accountDeletionURL: nil).accountDeletionShown)
        let page = try #require(AccountDeletion.url(origin: "https://account.vettid.org"))
        let shown = SettingsContent(state: SettingsState(), accountDeletionURL: page)
        #expect(shown.accountDeletionShown && height(shown) > 0)
        #expect(SecurityStrings.deleteAccount == "Delete your VettID account")
        #expect(SecurityStrings.deleteAccountBody == "Your email and membership, on the account site")
        #expect(SecurityStrings.deleteAccountExplain == """
            Your vault and your VettID account are separate. Delete vault erases your vault and everything in it. Your VettID \
            account, your email and membership, is deleted on the account site.
            """)
        #expect(SecurityStrings.deleteAccountOpen == "Open the account site")
    }

    /// Help's Legal section: the privacy policy opens the website's page (in Safari, like the other links), and Licenses is a
    /// screen of the app's own license and the bundled components' (the iPhone's own texts; chosen; not in the spec).
    @Test func helpHasThePrivacyPolicyAndTheLicenses() throws {
        #expect(HelpStrings.sectionLegal == "Legal")
        #expect(HelpScreen.legal.map(\.label) == ["Privacy policy"])
        #expect(HelpScreen.legal.map(\.url) == ["https://vettid.org/privacy/"])
        #expect(HelpScreen.legal.map(\.identifier) == ["help_privacy_policy"])
        #expect(HelpStrings.licenses == "Licenses" && HelpStrings.licensesBody == "The software VettID is built with")
        #expect(HelpStrings.licensesIntro
            == "VettID is open-source software. It includes the components below, each used under its own license.")
        let entries = Licences.all()
        #expect(entries.first?.id == "vettid")
        #expect(height(LicensesScreen(entries: entries) {}) > 0)
        #expect(LicensesScreen.title(entries[0]) == "VettID")
        let crypto = try #require(entries.first { $0.id == "swift-crypto" })
        #expect(LicensesScreen.title(crypto).hasPrefix("swift-crypto 5."))
    }

    /// The canary manifest's texts are vettid-android's, word for word (VAULT-RELEASES §10.1 step 9).
    @Test func theCanaryTextsAreAndroids() {
        let v = CanaryManifestView(
            serial: 2, keyID: "4353463f85c4012f", sha256: "",
            releases: [
                ReleaseView(number: 1, pcr0: "", status: "deprecated", endsAt: nil, notes: ""),
                ReleaseView(number: 2, pcr0: "", status: "active", endsAt: nil, notes: ""),
            ]
        )
        let expected = """
            This file is a list of vault releases signed by VettID (serial 2, key 4353463f85c4012f) that VettID has not \
            published yet. It lists release 1 (deprecated), release 2 (active). Use it only if VettID asked you to test a new \
            vault release. The app uses it instead of the published list until VettID publishes this list or a newer one.
            """
        #expect(CanaryManifestDialog.message(.confirm(v)) == expected)
        #expect(CanaryManifestDialog.message(.installed(v))
            == "The app now uses the test release manifest (serial 2). You can stop using it in Settings, Attestation.")
        #expect(CanaryManifestDialog.title(.refused(code: nil)) == "This file cannot be used")
        let refusals: [(String?, String)] = [
            (CanaryManifestCodes.signature, "It is not signed with a key this app trusts."),
            (CanaryManifestCodes.older, "It is older than the release list this phone already uses."),
            (CanaryManifestCodes.published, "VettID has already published this release list or a newer one, so it is not needed."),
            (CanaryManifestCodes.format, "It is not a VettID release manifest."),
            (CanaryManifestCodes.tooLarge, "It is not a VettID release manifest."),
            (CanaryManifestCodes.unchecked, "It could not be checked. Try again."),
            (nil, "It could not be checked. Try again."),
        ]
        for (code, text) in refusals { #expect(CanaryManifestDialog.message(.refused(code: code)) == text) }
        #expect(CanaryStrings.serialValue(2, "4353463f85c4012f") == "Serial 2 · key 4353463f85c4012f")
        #expect(CanaryStrings.settingsReleases(v) == "release 1 (deprecated), release 2 (active)")
        #expect(CanaryStrings.remove == "Stop using the test manifest")
        #expect(CanaryStrings.removeBody.hasPrefix("VettID's published release list is used again."))
    }

    /// IOS-PLAN ID15 and §14: the release and staging builds' line, the development builds' line from the app, and the
    /// App Attest line under it.
    @Test func installedFromIsTheBuilds() {
        #expect(VaultStatusContent.installedText(.apple) == "Installed from: Apple (App Store or TestFlight)")
        #expect(VaultStatusContent.installedText(.development(label: "dev")) == "dev")
        #expect(SettingsStrings.installedAppAttest == "Apple App Attest confirms this is the VettID app.")
    }

    /// The iPhone's own texts say what the app lock does: Face ID or Touch ID only, never the passcode in their place.
    @Test func theAppLockTextsAreTrue() {
        #expect(SettingsStrings.lockMethodBiometricsBody
            == "Face ID or Touch ID only. If they stop working, unlock your iPhone with its passcode and try again.")
        #expect(SettingsStrings.securityAppLockBody == "Ask for Face ID or Touch ID when opening VettID")
        #expect(SettingsStrings.appLockUsePasscode.contains("iPhone passcode"))
        #expect(SettingsStrings.attestationKeyNotAccepted == "Not accepted yet")
    }

    @Test func theStatusLines() {
        #expect(VaultStatusContent.stateText("unlocked") == "Unlocked" && VaultStatusContent.stateText("x") == "Unknown")
        #expect(VaultStatusContent.grouped("0123456789abcdef01", 8) == "01234567 89abcdef 01")
        #expect(VaultStatusContent.yesNo(nil) == "Unknown" && VaultStatusContent.yesNo(true) == "Yes")
        let notice = ReleaseInfoView(number: 3, status: "active", endsAt: nil, newestActive: 4, notice: "update_available")
        #expect(VaultStatusContent.releaseNotice(notice)?.hasPrefix("An update is available: release 4.") == true)
        #expect(VaultStatusContent.releaseNotice(ReleaseInfoView(number: 3, status: "active", endsAt: nil, newestActive: nil, notice: nil))
            == nil)
        var v = overview
        v.recoveryOffered = false
        #expect(VaultStatusContent.recoveryText(v) == "This vault's release does not offer recovery.")
        v.recoveryOffered = true
        v.recovery = nil
        #expect(VaultStatusContent.recoveryText(v) == "None")
    }

    /// The counter unavailable for a day (§11.14.5; STAGING-TIME-SCALE 0.1.1 S8, S7; vettid-android
    /// `settings_recovery_unknown_day`): the approved text verbatim at scale 1; at 24 both durations computed, with the
    /// staging note beside it.
    @Test func theRecoveryUnknownDayText() {
        let real = RecoveryStatusView(state: "unknown", used: nil, counterUnavailable: true, unknownForADay: true)
        #expect(VaultStatusContent.recoveryUnknownDayText(real) == """
            For a day your vault has not been able to check its recovery attempts or record that you were here. If this \
            goes on for three days, your vault is no longer protected against a recovery started by someone else, and until \
            it ends you cannot change your PIN or password. This is a fault of the VettID service or an attack on it. \
            Contact VettID.
            """)
        let staging = RecoveryStatusView(
            state: "unknown", used: nil, counterUnavailable: true, unknownForADay: true, unknownForSeconds: 3_600, timeScale: 24
        )
        let text = VaultStatusContent.recoveryUnknownDayText(staging)
        #expect(text.hasPrefix("For 1 hour your vault has not been able"))
        #expect(text.contains("If this goes on for 3 hours, your vault"))
        #expect(text.hasSuffix("Contact VettID.\n\nStaging: 1 day = 1 hour"))
        // A clock started in real time keeps its 24 hours on a vault scaled since; the quiet period follows the vault.
        let started = RecoveryStatusView(state: "unknown", used: nil, counterUnavailable: true, unknownForADay: true, timeScale: 24)
        #expect(VaultStatusContent.recoveryUnknownDayText(started).hasPrefix("For 24 hours"))
        var v = overview
        v.recovery = staging
        #expect(height(VaultStatusContent(state: LoadState(loading: false, value: v), installedFrom: .apple)) > 0)
    }

    /// The Credential key row (ANDROID-PLAN 0.1.119 §4 "Owner check and status"): vettid-android's texts word for word,
    /// every state rendered whatever the overview did, and the fingerprint's line for admins only with a fingerprint.
    @Test func theCredentialKeyRow() {
        #expect(SettingsStrings.statusCredentialKey == "Credential key")
        #expect(SettingsStrings.statusCredentialKeyAdmins
            == "If you are an admin of a service, the other admins may ask you to read this out when you become an admin, "
            + "or after you reset your credential. It is not a secret.")
        #expect(SettingsStrings.statusCredentialKeyUnknown == "Credential key: cannot be checked right now.")
        #expect(SettingsStrings.statusCredentialKeyNone == "Credential key: none yet")
        #expect(SettingsStrings.retry == "Try again" && TransferStrings.transferCopy == "Copy")
        let loaded = LoadState(loading: false, value: overview)
        // The screen fills the window, so its scroll content is what grows.
        func h(_ ck: CredentialKeyRow?, _ s: LoadState<VaultOverview>? = nil) -> CGFloat {
            contentHeight(VaultStatusContent(state: s ?? loaded, installedFrom: .apple, credentialKey: ck))
        }
        for ck in [CredentialKeyRow.loading, .unknown, .none, .shown("e939 754d 09aa a93a")] {
            #expect(h(ck) > h(nil), "\(ck)")
            #expect(h(ck, LoadState(loading: false, error: .network)) > h(nil, LoadState(loading: false, error: .network)), "\(ck)")
        }
        #expect(h(.shown("e939 754d 09aa a93a")) > h(.none) + 20, "the line for admins and Copy")
    }

    /// vettid-android `AccountCard`: the address and the membership under the names; without a snapshot, the default.
    @Test func theAccountCard() {
        let member = AccountInfo(
            emailHint: "a***@example.com", state: "member", firstName: "Ada", lastName: "L", email: "ada@example.com"
        )
        #expect(AccountCard.detail(member) == "ada@example.com\nMember")
        #expect(AccountCard.detail(AccountInfo(emailHint: "a***@example.com")) == "Membership and subscription")
        #expect(AccountCard.detail(nil) == "Membership and subscription")
    }

    /// The Settings account card (IOS-PLAN §4.7): the name and the address only while the vault is open; otherwise only
    /// the initial tile, without the masked hint. Mirrors vettid-android `AccountCardTest`.
    @Test func whileTheVaultIsNotOpenTheCardShowsNoNameAndNoHint() {
        let locked = AccountInfo(emailHint: "a***@example.org")
        #expect(AccountCard(account: locked) {}.account == nil)
        #expect(!AccountCard.detail(locked).contains("a***@example.org"))
        #expect(height(SettingsContent(state: SettingsState(account: locked), now: now)) > 0)
        let open = AccountInfo(
            emailHint: "a***@example.org", state: "member", firstName: "Ada", lastName: "Lovelace", email: "ada@example.org"
        )
        #expect(AccountCard(account: open) {}.account?.fullName == "Ada Lovelace")
        #expect(AccountCard.detail(open).contains("ada@example.org"))
    }

    var overview: VaultOverview {
        VaultOverview(
            vaultID: "0123456789abcdef0123456789abcdef", state: "unlocked",
            release: ReleaseInfoView(number: 3, status: "active", endsAt: "2026-12-01T00:00:00Z", newestActive: 4, notice: "final_warning"),
            lastRelease: 3, recoveryState: nil, provisional: false, devices: 2, connections: 5,
            recovery: RecoveryStatusView(state: "armed", used: 2, counterUnavailable: false)
        )
    }

    @Test func everyStateRenders() {
        let check = OwnerCheckView(
            state: .ok, deadline: now.addingTimeInterval(3_600), hold: false, holdOffUntil: now.addingTimeInterval(86_400)
        )
        let states = [
            SettingsState(),
            SettingsState(appLockOn: true, appLockInvalidated: true, appLockMethod: .passcode, error: .network, appLockUnavailable: true),
            SettingsState(appLockSuggestPasscode: true),
            SettingsState(update: ReleaseUpdateOffer(current: Self.release(4, "retired"), target: Self.release(5))),
        ]
        // The idle lock's row, also with a longer value waiting and its note, on a staging vault.
        let idle = [
            OwnerCheckSettingsState(view: check, idleLock: IdleLockSetting(seconds: 604_800)),
            OwnerCheckSettingsState(
                view: check, timeScale: 24, idleLock: IdleLockSetting(seconds: 2_592_000, inForceSeconds: 3_600), idleLongerNote: true
            ),
        ]
        for o in idle { #expect(height(SettingsContent(state: SettingsState(), ownerCheck: o, now: now)) > 0) }
        for s in states {
            #expect(height(SettingsContent(state: s, ownerCheck: OwnerCheckSettingsState(view: check), now: now)) > 0)
            #expect(height(SettingsContent(state: s, now: now)) > 0)
        }
        let iPhone = AttestationInfo.iPhone(
            environment: "test", appAttest: AppAttestInfo(accepted: false), lastRelease: 0, lastReleaseFingerprint: nil
        )
        let android = AttestationInfo(
            environment: "PRODUCTION", keyPresent: true, keyLevel: "TEE", strongBoxAvailable: false, attestationVersion: 300,
            verifiedBoot: "Verified", deviceLocked: true, bootKeyFingerprint: nil, lastRelease: 3, lastReleaseFingerprint: "aaaa"
        )
        for s in [LoadState(), LoadState(loading: false, value: overview), LoadState<VaultOverview>(loading: false, error: .network)] {
            #expect(height(VaultStatusContent(state: s, installedFrom: .apple)) > 0)
        }
        let attestations = [
            LoadState(), LoadState(loading: false, value: iPhone), LoadState(loading: false, value: android),
            LoadState(loading: false, error: .other),
        ]
        let canary = CanaryManifestView(
            serial: 8, keyID: "1edbb48b6669decd", sha256: String(repeating: "ab", count: 32),
            releases: [
                ReleaseView(number: 3, pcr0: String(repeating: "a3", count: 48), status: "active", endsAt: nil, notes: "https://x/3"),
            ]
        )
        for s in attestations {
            #expect(height(AttestationContent(state: s)) > 0)
            #expect(height(AttestationContent(state: s, canary: canary, onLoadCanary: {})) > 0)
        }
    }

    static func release(_ n: UInt64, _ status: String = "active") -> ReleaseView {
        ReleaseView(number: n, pcr0: String(repeating: "a\(n)", count: 48), status: status, endsAt: nil, notes: "https://x/\(n)")
    }

    /// The content height of the first scroll view of [view], hosted in a phone-sized window (0 without one).
    private func contentHeight(_ view: some View) -> CGFloat {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme(.light))
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        func views(in v: UIView) -> [UIView] { [v] + v.subviews.flatMap { views(in: $0) } }
        return views(in: window).compactMap { $0 as? UIScrollView }.first?.contentSize.height ?? 0
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
