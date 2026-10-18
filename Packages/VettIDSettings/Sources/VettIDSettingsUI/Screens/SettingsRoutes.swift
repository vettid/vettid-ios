#if os(iOS)
import SwiftUI
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

/// Attestation with its view model. Mirrors vettid-android's `AttestationRoute` destination.
public struct AttestationRoute: View {
    private let vault: any VaultRepository
    private let onBack: @MainActor () -> Void
    @State private var model: AttestationViewModel?

    public init(vault: any VaultRepository, onBack: @escaping @MainActor () -> Void) {
        self.vault = vault
        self.onBack = onBack
    }

    public var body: some View {
        AttestationContent(state: model?.state ?? LoadState(), onBack: onBack)
            .onAppear { if model == nil { model = AttestationViewModel(vault: vault) } }
    }
}
#endif
