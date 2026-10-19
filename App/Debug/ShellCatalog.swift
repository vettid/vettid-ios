#if DEBUG
import SwiftUI
import VettIDData
import VettIDKeys
import VettIDOnboarding
import VettIDSettings
import VettIDSettingsUI
import VettIDShell
import VettIDShellUI
import VettIDUI

/// Debug only: the app's shell (the drawer, the owner check's banners, the avatar sheet, a destination still to come) and
/// Settings with Vault status, Attestation, the name change, the PIN change and the Credential screen, in each of their
/// states with sample data, for the screen catalog and the previews. Fixed states with actions that do nothing. The release check refuses its strings.
enum ShellCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let screen: Screen
    }

    enum Screen: Sendable {
        case drawer
        case comingLater(TopLevelDestination)
        case banners(OwnerCheckGate)
        case accountSheet(AccountInfo?)
        case settings(SettingsState, OwnerCheckSettingsState)
        case vaultStatus(LoadState<VaultOverview>, InstalledFrom)
        case attestation(LoadState<AttestationInfo>)
        /// Attestation on a canary phone (VAULT-RELEASES §10.1 step 9): the installed test release manifest.
        case attestationCanary(LoadState<AttestationInfo>, CanaryManifestView)
        /// The canary manifest dialog over the shell.
        case canaryDialog(CanaryManifestPrompt)
        case changeName(ChangeNameState)
        case changePin(ChangePinState)
        case credential(CredentialState)
        case changePassword(ChangePasswordState)
        case newPhoneSecret(NewPhoneSecretState)
        case deleteVault(DeleteVaultState)
        /// Settings with Allow screenshots' confirmation shown.
        case settingsAskScreenshots(SettingsState)
    }

    static let now = Date(timeIntervalSince1970: 1_791_384_000)

    static let member = AccountInfo(
        emailHint: "a***@example.com", state: "member", accountStatus: "active",
        subscription: SubscriptionInfo(
            typeName: "Annual", status: "active", paid: true, expiresAt: now.addingTimeInterval(86_400 * 200)
        ),
        votingRights: true, firstName: "Ada", lastName: "Lovelace", email: "ada@example.com"
    )

    static let overview = VaultOverview(
        vaultID: "0123456789abcdef0123456789abcdef", state: "unlocked",
        release: ReleaseInfoView(number: 3, status: "active", endsAt: nil, newestActive: 4, notice: "update_available"),
        lastRelease: 3, recoveryState: nil, provisional: false, devices: 2, connections: 5,
        recovery: RecoveryStatusView(state: "armed", used: 0, counterUnavailable: false)
    )

    static let ownerCheck = OwnerCheckView(state: .ok, deadline: now.addingTimeInterval(20 * 3_600), intervalSeconds: 86_400)

    static let entries: [Entry] = shellEntries + settingsEntries + canaryEntries + flowEntries

    /// A canary manifest of serial 2 signed by production key A, listing release 1 deprecated and release 2 active.
    static let canary = CanaryManifestView(
        serial: 2, keyID: "4353463f85c4012f", sha256: String(repeating: "ab", count: 32),
        releases: [release(1, "deprecated"), release(2, "active")]
    )

    private static func release(_ n: UInt64, _ status: String) -> ReleaseView {
        ReleaseView(
            number: n, pcr0: String(repeating: n < 10 ? "0\(n)" : String(n % 100), count: 48), status: status, endsAt: nil,
            notes: "https://vettid.org/security/releases/\(n)/"
        )
    }

    private static var canaryEntries: [Entry] {
        let production = AttestationInfo.iPhone(
            environment: "PRODUCTION", appAttest: AppAttestInfo(accepted: true), lastRelease: 1,
            lastReleaseFingerprint: "0101 0101 0101 0101"
        )
        return [
            Entry(
                id: "attestation_canary", title: "Attestation: test release manifest",
                screen: .attestationCanary(LoadState(loading: false, value: production), canary)
            ),
            Entry(id: "canary_confirm", title: "Test release manifest: confirm", screen: .canaryDialog(.confirm(canary))),
            Entry(
                id: "canary_refused", title: "Test release manifest: refused",
                screen: .canaryDialog(.refused(code: CanaryManifestCodes.signature))
            ),
            Entry(id: "canary_installed", title: "Test release manifest: installed", screen: .canaryDialog(.installed(canary))),
        ]
    }

    private static var shellEntries: [Entry] {
        let notice = OwnerCheckNotice(itemID: "1", kind: "owner_check.failed", ref: "pin", at: now, urgent: true)
        return [
            Entry(id: "drawer", title: "Drawer open", screen: .drawer),
            Entry(id: "messages", title: "Messages: coming later", screen: .comingLater(.messages)),
            Entry(id: "banners", title: "Banners: warning, hold off, presence", screen: .banners(OwnerCheckGate(
                gated: false, warning: true, holdOff: true, deadline: now.addingTimeInterval(1_800),
                holdOffUntil: now.addingTimeInterval(86_400 * 3), presenceUnrecorded: true
            ))),
            Entry(id: "banner_notice", title: "Banners: a failed check, and more", screen: .banners(OwnerCheckGate(
                gated: false, warning: false, holdOff: false, notices: [notice, notice]
            ))),
            Entry(id: "sheet_member", title: "Avatar sheet: a member", screen: .accountSheet(member)),
            Entry(
                id: "sheet_waiting", title: "Avatar sheet: no snapshot yet",
                screen: .accountSheet(AccountInfo(emailHint: "a***@example.com"))
            ),
        ]
    }

    private static var settingsEntries: [Entry] {
        var lockOn = SettingsState(account: member, appLockOn: true, appLockMethod: .passcode, appLockTimeout: .oneMinute)
        lockOn.appLockInvalidated = true
        var holdOff = OwnerCheckSettingsState(view: ownerCheck)
        holdOff.view?.hold = false
        holdOff.view?.holdOffUntil = now.addingTimeInterval(86_400 * 7)
        holdOff.view?.intervalSeconds = 4 * 3_600
        let failure = SettingsState(account: member, error: .network, appLockUnavailable: true)
        let iPhone = AttestationInfo.iPhone(
            environment: "debug", appAttest: AppAttestInfo(accepted: true), lastRelease: 3,
            lastReleaseFingerprint: "a3a3 a3a3 a3a3 a3a3"
        )
        let loaded = LoadState(loading: false, value: overview)
        return [
            Entry(id: "settings", title: "Settings", screen: .settings(SettingsState(account: member), .init(view: ownerCheck))),
            Entry(id: "settings_lock_on", title: "Settings: app lock on, hold off", screen: .settings(lockOn, holdOff)),
            Entry(id: "settings_failures", title: "Settings: failures", screen: .settings(failure, OwnerCheckSettingsState())),
            Entry(id: "settings_release_r", title: "Settings: phone secret", screen: .settings(
                SettingsState(account: member, phoneSecret: true), OwnerCheckSettingsState()
            )),
            Entry(id: "status", title: "Vault status", screen: .vaultStatus(loaded, InstalledFromBuild.current)),
            Entry(id: "status_apple", title: "Vault status: from Apple", screen: .vaultStatus(loaded, .apple)),
            Entry(id: "status_loading", title: "Vault status: loading", screen: .vaultStatus(LoadState(), .apple)),
            Entry(id: "status_failed", title: "Vault status: failed", screen: .vaultStatus(.init(loading: false, error: .network), .apple)),
            Entry(id: "attestation", title: "Attestation", screen: .attestation(LoadState(loading: false, value: iPhone))),
        ]
    }

    /// The screen for [entry], with actions that do nothing.
    @MainActor @ViewBuilder
    static func screen(_ entry: Entry) -> some View {
        let chrome = ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {})
        switch entry.screen {
        case .drawer:
            DrawerContainer(isOpen: .constant(true)) {
                VettIDDrawerSheet(
                    sections: TopLevelDestination.drawerSections, selectedKey: "messages", versionLabel: "VettID 2.0.0 (1)"
                ) { _ in }
            } content: {
                ComingLaterScreen(destination: .messages, chrome: chrome)
            }
        case .comingLater(let d):
            ComingLaterScreen(destination: d, chrome: chrome)
        case .banners(let gate):
            VStack(spacing: 0) {
                OwnerCheckBanners(gate: gate, now: now, onCheckNow: {}, onHoldOn: {}, onDismissNotices: {})
                ComingLaterScreen(destination: .messages, chrome: chrome)
            }
        case .accountSheet(let account):
            AccountSheet(account: account, now: now, onLockVault: {}, onOpenPortal: {})
        case .settings(let state, let ownerCheck):
            SettingsContent(state: state, ownerCheck: ownerCheck, now: now)
        case .vaultStatus(let state, let installedFrom):
            VaultStatusContent(state: state, installedFrom: installedFrom)
        case .attestation(let state):
            AttestationContent(state: state, onLoadCanary: {})
        case .attestationCanary(let state, let canary):
            AttestationContent(state: state, canary: canary, onLoadCanary: {})
        case .canaryDialog(let prompt):
            ComingLaterScreen(destination: .messages, chrome: chrome).canaryManifestDialog(prompt, onConfirm: {}, onDismiss: {})
        case .changeName, .changePin, .credential, .changePassword, .newPhoneSecret, .deleteVault, .settingsAskScreenshots:
            flowScreen(entry.screen)
        }
    }
}

/// Debug-only: the shell and Settings in each of their states (``ShellCatalog``). Opened from the screen catalog, or at
/// launch with `-vettid.start shell`.
struct ShellCatalogScreen: View {
    let onBack: @MainActor () -> Void
    @State private var shown: String?

    var body: some View {
        DetailScaffold(onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle("Shell and settings")
                    SettingsGroup {
                        ForEach(ShellCatalog.entries) { entry in
                            SettingsRow(entry.title) { shown = entry.id }
                                .accessibilityIdentifier("catalog_shell_\(entry.id)")
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $shown) { id in
            if let entry = ShellCatalog.entries.first(where: { $0.id == id }) {
                ShellCatalog.screen(entry)
                    .overlay(alignment: .topTrailing) {
                        IconButton(.close, label: "Close") { shown = nil }.padding(.horizontal, Spacing.xs)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

#Preview("Shell and settings") {
    TabView {
        ForEach(ShellCatalog.entries) { entry in
            ShellCatalog.screen(entry).tabItem { Text(verbatim: entry.title) }
        }
    }
    .tabViewStyle(.page)
    .vettIDTheme(.dark)
}
#endif
