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
        #expect(keys.count == 230)
        let missing = "\u{0}missing"
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            let prefixes = ["settings_", "credential_", "canary_", "ios_settings_", "ios_credential_", "ios_app_lock_"]
            #expect(prefixes.contains { key.hasPrefix($0) }, "\(key)")
        }
    }

    @Test func theTextsAreAndroids() {
        #expect(SettingsStrings.vaultLockBody == "Locks your vault now. You need your PIN to open it again.")
        #expect(SettingsStrings.ownerCheckEvery(1) == "Every hour")
        #expect(SettingsStrings.ownerCheckEvery(4) == "Every 4 hours")
        #expect(SettingsStrings.ownerCheckNext("Oct 18") == "next by Oct 18")
        #expect(SettingsStrings.statusReleaseValue(3, "active") == "Release 3 (active)")
        #expect(SettingsStrings.statusAdvisory
            == "Status comes from the account service and is for information only; your vault's own answers decide.")
        #expect(SettingsStrings.attestationReleaseValue(3, "a3a3 a3a3") == "Release 3 · a3a3 a3a3")
        #expect(VaultStatusContent.recoveryLine(.armed(used: 0)) == "Recovery: on. Attempts used: 0 of 10.")
        #expect(VaultStatusContent.recoveryLine(.unknown) == "Recovery: cannot be checked right now.")
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

    /// vettid-android `AccountCard`: the address and the membership under the names; without a snapshot, the default.
    @Test func theAccountCard() {
        let member = AccountInfo(
            emailHint: "a***@example.com", state: "member", firstName: "Ada", lastName: "L", email: "ada@example.com"
        )
        #expect(AccountCard.detail(member) == "ada@example.com\nMember")
        #expect(AccountCard.detail(AccountInfo(emailHint: "a***@example.com")) == "Membership and subscription")
        #expect(AccountCard.detail(nil) == "Membership and subscription")
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
        ]
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

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
