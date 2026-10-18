#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import VettIDData
import VettIDSettings
import VettIDUI

/// What Settings needs from the app shell. Mirrors vettid-android `SettingsHost`.
public struct SettingsHost {
    public var onBack: @MainActor () -> Void = {}
    /// Opens the avatar sheet.
    public var onAccount: @MainActor () -> Void = {}
    public var onOpenAccountSite: @MainActor () -> Void = {}
    public var onVaultStatus: @MainActor () -> Void = {}
    public var onAttestation: @MainActor () -> Void = {}
    public var onChangePin: @MainActor () -> Void = {}
    /// Settings → Security → Credential.
    public var onCredential: @MainActor () -> Void = {}
    /// Opens the owner check (VAULT-MESSAGING §3.6.5): [holdOff] true turns the hold off with it (VAULT-MESSAGING §3.6.7).
    public var onOwnerCheck: @MainActor (_ holdOff: Bool) -> Void = { _ in }

    public init() {}
}

/// Settings with its view models, made when it first appears and released (their work cancelled) when the screen goes.
/// Mirrors vettid-android's `SettingsRoute` destination.
public struct SettingsRoute: View {
    private let account: any AccountRepository
    private let vault: any VaultRepository
    private let ownerChecks: any OwnerCheckRepository
    private let appLock: any AppLockSettings
    private let promptReason: String
    private let host: SettingsHost
    @State private var model: SettingsViewModel?
    @State private var ownerCheck: OwnerCheckSettingsViewModel?

    /// [promptReason]: what the Face ID, Touch ID or passcode prompt says when the app lock is turned on.
    public init(
        account: any AccountRepository,
        vault: any VaultRepository,
        ownerChecks: any OwnerCheckRepository,
        appLock: any AppLockSettings,
        promptReason: String,
        host: SettingsHost
    ) {
        self.account = account
        self.vault = vault
        self.ownerChecks = ownerChecks
        self.appLock = appLock
        self.promptReason = promptReason
        self.host = host
    }

    public var body: some View {
        Group {
            if let model, let ownerCheck {
                SettingsContent(
                    state: model.state, ownerCheck: ownerCheck.state, actions: actions(model),
                    ownerCheckActions: ownerCheckActions(ownerCheck)
                )
            } else {
                // Until the view models are made (the first appearance): the same screen from the repositories, no blank frame.
                SettingsContent(
                    state: SettingsState(
                        account: account.account, appLockOn: appLock.state.isOn, appLockMethod: appLock.method,
                        appLockTimeout: appLock.timeout
                    ),
                    ownerCheck: OwnerCheckSettingsState(view: ownerChecks.ownerCheck)
                )
            }
        }
        .onAppear {
            if model == nil {
                model = SettingsViewModel(account: account, vault: vault, appLock: appLock, promptReason: promptReason)
                ownerCheck = OwnerCheckSettingsViewModel(repo: ownerChecks)
            }
        }
    }

    private func actions(_ m: SettingsViewModel) -> SettingsActions {
        var a = SettingsActions()
        a.back = host.onBack
        a.account = host.onAccount
        a.vaultStatus = host.onVaultStatus
        a.attestation = host.onAttestation
        a.changePin = host.onChangePin
        a.credential = host.onCredential
        a.accountSite = host.onOpenAccountSite
        a.lockVault = { m.lockVault() }
        a.setAppLock = { m.setAppLock($0) }
        a.setAppLockMethod = { m.setAppLockMethod($0) }
        a.setTimeout = { m.setAppLockTimeout($0) }
        a.acknowledgeInvalidated = { m.acknowledgeInvalidated() }
        a.dismissAppLockUnavailable = { m.dismissAppLockUnavailable() }
        a.dismissError = { m.dismissError() }
        return a
    }

    private func ownerCheckActions(_ m: OwnerCheckSettingsViewModel) -> OwnerCheckSettingsActions {
        var a = OwnerCheckSettingsActions()
        let host = host
        a.setIntervalHours = { m.setIntervalHours($0) }
        // Off is a check with the hold change (VAULT-MESSAGING §3.6.7); on is a plain setting.
        a.setHold = { on in if on { m.turnHoldOn() } else { host.onOwnerCheck(true) } }
        a.checkNow = { host.onOwnerCheck(false) }
        a.dismissOffer = { m.dismissOffer() }
        a.dismissError = { m.dismissError() }
        return a
    }
}

/// Vault status with its view model. Mirrors vettid-android's `VaultStatusRoute` destination.
public struct VaultStatusRoute: View {
    private let vault: any VaultRepository
    private let installedFrom: InstalledFrom
    private let onBack: @MainActor () -> Void
    @State private var model: VaultStatusViewModel?

    public init(vault: any VaultRepository, installedFrom: InstalledFrom, onBack: @escaping @MainActor () -> Void) {
        self.vault = vault
        self.installedFrom = installedFrom
        self.onBack = onBack
    }

    public var body: some View {
        VaultStatusContent(
            state: model?.state ?? LoadState(), installedFrom: installedFrom, retry: { model?.load() }, onBack: onBack
        )
        .onAppear { if model == nil { model = VaultStatusViewModel(vault: vault) } }
    }
}

/// Attestation with its view model. [canary] and [canaryInbox]: the canary manifest, shown when one is installed, and
/// the file importer that hands a picked file to the root's dialog (``CanaryManifestHost``), which asks before anything
/// is installed. The importer's row is shown to every member (chosen; not in the spec: vettid-android has no picker, only
/// the share intent). Mirrors vettid-android's `AttestationRoute` destination.
public struct AttestationRoute: View {
    private let vault: any VaultRepository
    private let canary: (any CanaryManifestRepository)?
    private let canaryInbox: CanaryManifestInbox?
    private let onBack: @MainActor () -> Void
    @State private var model: AttestationViewModel?
    @State private var importing = false

    public init(
        vault: any VaultRepository,
        canary: (any CanaryManifestRepository)? = nil,
        canaryInbox: CanaryManifestInbox? = nil,
        onBack: @escaping @MainActor () -> Void
    ) {
        self.vault = vault
        self.canary = canary
        self.canaryInbox = canaryInbox
        self.onBack = onBack
    }

    public var body: some View {
        AttestationContent(
            state: model?.state ?? LoadState(), onBack: onBack, canary: model?.canary, onRemoveCanary: { model?.removeCanary() },
            onLoadCanary: canaryInbox == nil ? nil : { importing = true }
        )
        .onAppear { if model == nil { model = AttestationViewModel(vault: vault, canary: canary) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard let inbox = canaryInbox else { return }
            let url = try? result.get()
            Task { @MainActor in
                // Read off the main actor, bounded; a file that cannot be read is said so ("It could not be checked").
                let doc = await Task.detached { url.flatMap { try? CanaryManifestInbox.readBounded($0) } }.value
                if let doc { inbox.offer(doc) } else if url != nil { inbox.offerUnreadable() }
            }
        }
    }
}
#endif

#if os(iOS)
/// The name change with its view model, made when it first appears. [onClose] leaves the flow. Mirrors vettid-android's
/// `ChangeNameRoute` destination: back from the PIN and password returns to the names; from the names (or the result) it
/// leaves.
public struct ChangeNameRoute: View {
    private let accounts: any AccountRepository
    private let profiles: any ProfileRepository
    private let onClose: @MainActor () -> Void
    @State private var model: ChangeNameViewModel?

    public init(accounts: any AccountRepository, profiles: any ProfileRepository, onClose: @escaping @MainActor () -> Void) {
        self.accounts = accounts
        self.profiles = profiles
        self.onClose = onClose
    }

    public var body: some View {
        ChangeNameContent(state: model?.state ?? ChangeNameState(account: accounts.account), actions: actions)
            .onAppear { if model == nil { model = ChangeNameViewModel(accounts: accounts, profiles: profiles) } }
    }

    private var actions: ChangeNameActions {
        var a = ChangeNameActions()
        let m = model
        let onClose = onClose
        a.onFirst = { m?.setFirst($0) }
        a.onLast = { m?.setLast($0) }
        a.onNext = { m?.next() }
        a.onPassword = { m?.setPassword($0) }
        a.onSubmit = { pin in
            m?.setPin(pin)
            m?.submit()
        }
        a.onBackToNames = { m?.back() }
        a.onForgetSecrets = { m?.cancel() }
        a.onClose = {
            m?.cancel()
            onClose()
        }
        return a
    }
}

/// Settings → Vault → Change vault PIN with its view model. [fromAttempts]: opened from a notice about recovery
/// attempts (the warning first). Mirrors vettid-android's `ChangePinRoute` destination.
public struct ChangePinRoute: View {
    private let vault: any VaultRepository
    private let fromAttempts: Bool
    private let onClose: @MainActor () -> Void
    @State private var model: ChangePinViewModel?

    public init(vault: any VaultRepository, fromAttempts: Bool = false, onClose: @escaping @MainActor () -> Void) {
        self.vault = vault
        self.fromAttempts = fromAttempts
        self.onClose = onClose
    }

    public var body: some View {
        ChangePinContent(
            state: model?.state ?? ChangePinState(withPassword: vault.usesPhoneSecret, fromAttempts: fromAttempts), actions: actions
        )
        .onAppear { if model == nil { model = ChangePinViewModel(vault: vault, fromAttempts: fromAttempts) } }
    }

    private var actions: ChangePinActions {
        var a = ChangePinActions()
        let m = model
        a.onCurrent = { m?.setCurrent($0) }
        a.onPin = { m?.setPin($0) }
        a.onConfirm = { m?.setConfirm($0) }
        a.onPassword = { m?.setPassword($0) }
        a.onNext = { m?.next() }
        a.onStepBack = { m?.back() }
        a.onForgetSecrets = { m?.forgetSecrets() }
        a.onClose = onClose
        return a
    }
}

/// Settings → Security → Credential with its view model. [onOwnerCheck]: turning the backup on asks for the PIN and the
/// password at once (the owner check), so that the sealed copy exists (VAULT-MESSAGING §3.5.6). Mirrors vettid-android's
/// `CredentialRoute` destination.
public struct CredentialRoute: View {
    private let repo: any CredentialRepository
    private let onBack: @MainActor () -> Void
    private let onChangePassword: @MainActor () -> Void
    private let onOwnerCheck: @MainActor () -> Void
    @State private var model: CredentialViewModel?

    public init(
        repo: any CredentialRepository,
        onBack: @escaping @MainActor () -> Void,
        onChangePassword: @escaping @MainActor () -> Void,
        onOwnerCheck: @escaping @MainActor () -> Void
    ) {
        self.repo = repo
        self.onBack = onBack
        self.onChangePassword = onChangePassword
        self.onOwnerCheck = onOwnerCheck
    }

    public var body: some View {
        CredentialContent(state: model?.state ?? CredentialState(), actions: actions)
            .onAppear { if model == nil { model = CredentialViewModel(repo: repo) } }
            .onChange(of: model?.state.notice) { _, notice in if notice == .backupOn { onOwnerCheck() } }
    }

    private var actions: CredentialActions {
        var a = CredentialActions()
        let m = model
        a.back = onBack
        a.retry = { m?.refresh() }
        a.showWindowDialog = { m?.showWindowDialog($0) }
        a.setWindowPassword = { m?.setWindowPassword($0) }
        a.openWindow = { m?.openWindow() }
        a.closeWindow = { m?.closeWindow() }
        a.setTtl = { m?.setTtl($0) }
        a.setBackup = { m?.setBackup($0) }
        a.dismissNotice = { m?.dismissNotice() }
        a.changePassword = onChangePassword
        return a
    }
}

/// Credential → Change password with its view model. Mirrors vettid-android's `CredentialPasswordRoute` destination.
public struct ChangePasswordRoute: View {
    private let repo: any CredentialRepository
    private let vault: any VaultRepository
    private let onBack: @MainActor () -> Void
    @State private var model: ChangePasswordViewModel?

    public init(repo: any CredentialRepository, vault: any VaultRepository, onBack: @escaping @MainActor () -> Void) {
        self.repo = repo
        self.vault = vault
        self.onBack = onBack
    }

    public var body: some View {
        ChangePasswordContent(state: model?.state ?? ChangePasswordState(askPin: vault.usesPhoneSecret), actions: actions)
            .onAppear { if model == nil { model = ChangePasswordViewModel(repo: repo, vault: vault) } }
    }

    private var actions: ChangePasswordActions {
        var a = ChangePasswordActions()
        let m = model
        a.onCurrent = { m?.setCurrent($0) }
        a.onPassword = { m?.setPassword($0) }
        a.onConfirm = { m?.setConfirm($0) }
        a.onSubmit = { pin in
            if let pin { m?.setPin(pin) }
            m?.submit()
        }
        a.onForgetSecrets = { m?.forgetSecrets() }
        a.onBack = onBack
        return a
    }
}
#endif
