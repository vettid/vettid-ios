#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDOnboardingUI
import VettIDSettings
import VettIDSettingsUI
import VettIDShell
import VettIDUI

/// The open app (IOS-PLAN ID14): the slide-in drawer, the only top-level navigation (no tab bar), with its destinations in
/// vettid-android's order; the owner check's banners above every screen; a navigation stack per destination for the
/// screens pushed over it, with the system back gesture; the avatar sheet; and the owner check the member asks for
/// ("Check now", turning the hold off) over everything. The check past the deadline is the root's (``OwnerCheckGate``),
/// before the shell. The banners of later rows (the clone alarm, a pending deletion, a release update, the notifications
/// note, the rotation offer) go above the owner check's, in vettid-android's order. Mirrors vettid-android `AppShell`.
public struct AppShell: View {
    private let account: any AccountRepository
    private let vault: any VaultRepository
    private let ownerChecks: any OwnerCheckRepository
    private let credential: any CredentialRepository
    private let profiles: any ProfileRepository
    private let appLock: any AppLockSettings
    @Bindable private var model: ShellModel
    private let gate: OwnerCheckGate
    private let now: Date
    private let version: AppVersion
    private let installedFrom: InstalledFrom
    private let promptReason: String
    private let canary: (any CanaryManifestRepository)?
    private let canaryInbox: CanaryManifestInbox?
    private let onOpenPortal: @MainActor () -> Void

    /// [model]: where the member is, owned above the owner check's gate. [gate]: the owner check at [now] (the root re-reads
    /// it as time passes). [promptReason]: what the Face ID, Touch ID or passcode prompt says when the app lock is turned on.
    /// [canary] and [canaryInbox]: the canary manifest on Settings → Attestation (VAULT-RELEASES §10.1 step 9).
    public init(
        account: any AccountRepository,
        vault: any VaultRepository,
        ownerChecks: any OwnerCheckRepository,
        credential: any CredentialRepository,
        profiles: any ProfileRepository,
        appLock: any AppLockSettings,
        model: ShellModel,
        gate: OwnerCheckGate,
        now: Date,
        version: AppVersion,
        installedFrom: InstalledFrom,
        promptReason: String,
        canary: (any CanaryManifestRepository)? = nil,
        canaryInbox: CanaryManifestInbox? = nil,
        onOpenPortal: @escaping @MainActor () -> Void
    ) {
        self.account = account
        self.vault = vault
        self.ownerChecks = ownerChecks
        self.credential = credential
        self.profiles = profiles
        self.appLock = appLock
        self.model = model
        self.gate = gate
        self.now = now
        self.version = version
        self.installedFrom = installedFrom
        self.promptReason = promptReason
        self.canary = canary
        self.canaryInbox = canaryInbox
        self.onOpenPortal = onOpenPortal
    }

    /// A lost answer's decision reached while its screen was closed (VAULT-MESSAGING §11.14.9): once, until "OK".
    @ViewBuilder private var changeCheckNotice: some View {
        // A change screen waiting for it shows the decision itself.
        if let check = vault.changeCheck, let text = ChangeCheckNotice.text(check), !vault.changeCheckAwaited {
            if ChangeCheckNotice.urgent(check) {
                UrgentBanner(text, actionLabel: ShellStrings.ownerCheckNoticeOk, action: { vault.acknowledgeChangeCheck() })
                    .accessibilityIdentifier("change_check_notice")
            } else {
                InfoBanner(text, actionLabel: ShellStrings.ownerCheckNoticeOk, onAction: { vault.acknowledgeChangeCheck() })
                    .accessibilityIdentifier("change_check_notice")
            }
        }
    }

    public var body: some View {
        ZStack {
            DrawerContainer(isOpen: $model.drawerOpen) {
                VettIDDrawerSheet(
                    sections: TopLevelDestination.drawerSections,
                    selectedKey: model.destination.key,
                    versionLabel: ShellStrings.drawerVersion(version.name, version.build)
                ) { item in
                    if let d = TopLevelDestination.fromKey(item.key) { model.navigate(d) } else { model.drawerOpen = false }
                }
            } content: {
                VStack(spacing: 0) {
                    OwnerCheckBanners(
                        gate: gate, now: now, onCheckNow: { model.ownerCheck(holdOff: false) },
                        onHoldOn: { Task { await model.turnHoldOn() } }, onDismissNotices: { Task { await model.dismissNotices() } }
                    )
                    changeCheckNotice
                    NavigationStack(path: $model.path) {
                        root
                            .toolbar(.hidden, for: .navigationBar)
                            .systemBackGesture()
                            .navigationDestination(for: ShellRoute.self) { route in
                                detail(route).toolbar(.hidden, for: .navigationBar)
                            }
                    }
                }
                // The open app, for UI tests (a container: what is inside keeps its own identifiers).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("app_shell")
            }
            // While the asked check is shown, nothing of the vault under it is visible or reachable, VoiceOver included
            // (VAULT-MESSAGING §3.6.5).
            .accessibilityHidden(model.asked != nil)
            .allowsHitTesting(model.asked == nil)
            if let mode = model.asked {
                OwnerCheckFlow(
                    mode: mode, repo: ownerChecks, vault: vault, onDone: { model.ownerCheckDone() }, onCancel: { model.ownerCheckDone() }
                )
                .accessibilityAddTraits(.isModal)
                .transition(.move(edge: .bottom))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.asked)
        .avatarSheet(isPresented: $model.showAccount) {
            AccountSheet(
                account: account.account,
                onLockVault: { Task { await model.lockVault() } },
                onChangeName: { model.changeName() },
                onOpenPortal: onOpenPortal
            )
        }
    }

    private var chrome: ShellChrome {
        ShellChrome(
            accountName: AccountHeader.name(account.account, placeholder: ShellStrings.accountPlaceholderName),
            onMenu: { model.drawerOpen = true },
            onAvatar: { model.showAccount = true }
        )
    }

    @ViewBuilder private var root: some View {
        switch model.destination {
        case .settings:
            SettingsRoute(
                account: account, vault: vault, ownerChecks: ownerChecks, appLock: appLock, promptReason: promptReason,
                host: settingsHost
            )
        default:
            ComingLaterScreen(destination: model.destination, chrome: chrome)
        }
    }

    @ViewBuilder private func detail(_ route: ShellRoute) -> some View {
        switch route {
        case .vaultStatus:
            VaultStatusRoute(vault: vault, installedFrom: installedFrom) { model.pop() }
        case .attestation:
            AttestationRoute(vault: vault, canary: canary, canaryInbox: canaryInbox) { model.pop() }
        case .changeName:
            ChangeNameRoute(accounts: account, profiles: profiles) { model.pop() }
        case .changePin(let fromAttempts):
            ChangePinRoute(vault: vault, fromAttempts: fromAttempts) { model.pop() }
        case .credential:
            CredentialRoute(
                repo: credential, onBack: { model.pop() }, onChangePassword: { model.push(.changePassword) },
                onOwnerCheck: { model.ownerCheck(holdOff: false) }
            )
        case .changePassword:
            ChangePasswordRoute(repo: credential, vault: vault) { model.pop() }
        }
    }

    private var settingsHost: SettingsHost {
        let model = model
        var h = SettingsHost()
        // Settings has a back arrow, as on Android, where it returns to the start destination.
        h.onBack = { model.back() }
        h.onAccount = { model.showAccount = true }
        h.onOpenAccountSite = onOpenPortal
        h.onVaultStatus = { model.push(.vaultStatus) }
        h.onAttestation = { model.push(.attestation) }
        h.onChangePin = { model.push(.changePin(fromAttempts: false)) }
        h.onCredential = { model.push(.credential) }
        h.onOwnerCheck = { holdOff in model.ownerCheck(holdOff: holdOff) }
        return h
    }
}
#endif
