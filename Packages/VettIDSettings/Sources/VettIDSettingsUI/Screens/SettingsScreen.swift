#if os(iOS)
import SwiftUI
import VettIDData
import VettIDKeys
import VettIDSettings
import VettIDUI

/// What the Settings screen can ask for. Mirrors vettid-android `SettingsActions`, with the rows the iPhone app has so
/// far.
public struct SettingsActions {
    public var back: @MainActor () -> Void = {}
    public var account: @MainActor () -> Void = {}
    public var vaultStatus: @MainActor () -> Void = {}
    public var lockVault: @MainActor () -> Void = {}
    public var attestation: @MainActor () -> Void = {}
    public var changePin: @MainActor () -> Void = {}
    public var credential: @MainActor () -> Void = {}
    public var setAppLock: @MainActor (Bool) -> Void = { _ in }
    public var setAppLockMethod: @MainActor (AppLockMethod) -> Void = { _ in }
    public var setTimeout: @MainActor (AppLockTimeout) -> Void = { _ in }
    public var acknowledgeInvalidated: @MainActor () -> Void = {}
    public var dismissAppLockUnavailable: @MainActor () -> Void = {}
    public var accountSite: @MainActor () -> Void = {}
    public var dismissError: @MainActor () -> Void = {}

    public init() {}
}

/// Settings (ANDROID-PLAN §4 "Screens", Settings): the account card, then Vault, Security and Account, in vettid-android's
/// order; grouped cards (Proton); the vault's lock confirms first. A row is shown only once its feature works; the rest
/// come with the rows of IOS-PLAN §8 that bring them: Update available (I1.8c, RELEASE-UPDATES §2), New phone secret
/// (I1.8, VAULT-MESSAGING §11.14.9), Allow screenshots (I1.8, IOS-PLAN §4) and Delete vault (I1.8, VAULT-MESSAGING §12.5),
/// Theme (I1.8c), Notifications (phase P, IOS-PLAN §6.7), Move to a new phone and Recovery (I3, VAULT-MESSAGING §6.7.1,
/// §11.11), and the Privacy section (shared profile, sharing rules: I2 and I3, VAULT-MESSAGING §10.8). Mirrors
/// vettid-android `SettingsContent`.
public struct SettingsContent: View {
    @Environment(\.vettIDColors) private var colors
    let state: SettingsState
    let ownerCheck: OwnerCheckSettingsState
    let actions: SettingsActions
    let ownerCheckActions: OwnerCheckSettingsActions
    let now: Date
    @State private var confirmLock = false
    @State private var picker: SecurityPicker?

    public init(
        state: SettingsState,
        ownerCheck: OwnerCheckSettingsState = OwnerCheckSettingsState(),
        actions: SettingsActions = SettingsActions(),
        ownerCheckActions: OwnerCheckSettingsActions = OwnerCheckSettingsActions(),
        now: Date = Date()
    ) {
        self.state = state
        self.ownerCheck = ownerCheck
        self.actions = actions
        self.ownerCheckActions = ownerCheckActions
        self.now = now
    }

    public var body: some View {
        DetailScaffold(background: colors.groupedBackground, onBack: actions.back) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle(SettingsStrings.title)
                    SettingsGroup { AccountCard(account: state.account, action: actions.account) }
                        .accessibilityIdentifier("account_card")
                    notices
                    vaultSection
                    SettingsSectionHeader(SettingsStrings.sectionSecurity)
                    SettingsGroup {
                        SettingsRow(
                            PinStrings.securityCredential, icon: .key, supporting: PinStrings.securityCredentialBody,
                            action: actions.credential
                        )
                        .accessibilityIdentifier("credential_row")
                        SettingsDivider()
                        SettingsRow(SettingsStrings.securityAttestation, icon: .verifiedUser, action: actions.attestation)
                            .accessibilityIdentifier("attestation")
                        OwnerCheckSettingsRows(state: ownerCheck, actions: ownerCheckActions, now: now)
                        AppLockRows(state: state, actions: actions, picker: $picker)
                    }
                    SettingsSectionHeader(SettingsStrings.sectionAccount)
                    SettingsGroup {
                        SettingsRow(SettingsStrings.accountSite, icon: .openInNew, showChevron: false, action: actions.accountSite)
                            .accessibilityIdentifier("account_site")
                    }
                    Spacer().frame(height: Spacing.xxl)
                }
            }
        }
        .confirmDialog(
            isPresented: $confirmLock, title: SettingsStrings.vaultLock, message: SettingsStrings.vaultLockBody,
            confirmLabel: SettingsStrings.vaultLock, dismissLabel: SettingsStrings.cancel, onConfirm: actions.lockVault
        )
        .choiceSheet(item: $picker) { p in
            SecurityPickerSheet(picker: p, state: state, actions: actions) { picker = nil }
        }
    }

    @ViewBuilder private var notices: some View {
        if let error = state.error {
            NoticeCard(.urgent, title: SettingsStrings.title, message: error.message) {
                NoticeAction(label: SettingsStrings.done, identifier: "settings_error_done", action: actions.dismissError)
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
        }
        if state.appLockInvalidated {
            NoticeCard(.warning, title: SettingsStrings.securityAppLock, message: SettingsStrings.securityAppLockInvalidated) {
                NoticeAction(label: SettingsStrings.done, action: actions.acknowledgeInvalidated)
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
        }
        if state.appLockSuggestPasscode {
            NoticeCard(.warning, title: SettingsStrings.securityAppLock, message: SettingsStrings.appLockUsePasscode) {
                NoticeAction(label: SettingsStrings.done, action: actions.dismissAppLockUnavailable)
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
            .accessibilityIdentifier("app_lock_use_passcode")
        }
        if state.appLockUnavailable {
            NoticeCard(.warning, title: SettingsStrings.securityAppLock, message: SettingsStrings.appLockEnableFailed) {
                NoticeAction(label: SettingsStrings.done, action: actions.dismissAppLockUnavailable)
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
            .accessibilityIdentifier("app_lock_unavailable")
        }
    }

    private var vaultSection: some View {
        VStack(spacing: 0) {
            SettingsSectionHeader(SettingsStrings.sectionVault)
            SettingsGroup {
                SettingsRow(SettingsStrings.vaultStatus, icon: .storage, action: actions.vaultStatus)
                    .accessibilityIdentifier("vault_status")
                SettingsDivider()
                SettingsRow(
                    SettingsStrings.vaultLock, icon: .lock, supporting: SettingsStrings.vaultLockBody, showChevron: false
                ) { confirmLock = true }
                .accessibilityIdentifier("lock_vault")
                SettingsDivider()
                SettingsRow(PinStrings.vaultPin, icon: .password, action: actions.changePin)
                    .accessibilityIdentifier("change_pin")
            }
        }
    }
}

/// The account card (ANDROID-PLAN §4 "Screens", Settings): the first and last name, the full address (VAULT-MESSAGING §11.13 `email`,
/// the masked hint from an older vault) and the membership state; it opens the avatar sheet. Mirrors vettid-android
/// `AccountCard`.
struct AccountCard: View {
    let account: AccountInfo?
    let action: @MainActor () -> Void

    var body: some View {
        SettingsAccountRow(name: account?.fullName ?? account?.displayEmail ?? "", detail: Self.detail(account), action: action)
    }

    static func detail(_ a: AccountInfo?) -> String {
        var lines: [String] = []
        if let a, a.fullName != nil, let email = a.displayEmail { lines.append(email) }
        if let line = membership(a) { lines.append(line) }
        return lines.isEmpty ? SettingsStrings.accountDetail : lines.joined(separator: "\n")
    }

    /// The membership state; nil before the vault's snapshot arrived.
    static func membership(_ a: AccountInfo?) -> String? {
        guard let a, a.hasSnapshot else { return nil }
        switch (a.canceled, a.state) {
        case (true, _): return SettingsStrings.accountCanceled
        case (false, "member"): return SettingsStrings.accountMember
        default: return SettingsStrings.accountRegistered
        }
    }
}

/// Which of the Security group's choices is open.
enum SecurityPicker: String, Identifiable {
    case method, timeout

    var id: String { rawValue }
}

/// The app lock's rows (ANDROID-PLAN D6, IOS-PLAN ID17): the switch, "Unlock with", and "Lock after" while it is on.
struct AppLockRows: View {
    let state: SettingsState
    let actions: SettingsActions
    @Binding var picker: SecurityPicker?

    var body: some View {
        let passcode = state.appLockMethod == .passcode
        SettingsDivider()
        SettingsSwitchRow(
            SettingsStrings.securityAppLock,
            isOn: Binding(get: { state.appLockOn }, set: { actions.setAppLock($0) }),
            icon: passcode ? .passcode : .faceID,
            supporting: passcode ? SettingsStrings.securityAppLockBodyPasscode : SettingsStrings.securityAppLockBody
        )
        .accessibilityIdentifier("app_lock")
        SettingsDivider()
        SettingsRow(
            SettingsStrings.securityLockMethod, icon: .lockOpen, supporting: Self.methodLabel(state.appLockMethod)
        ) { picker = .method }
        .accessibilityIdentifier("app_lock_method")
        if state.appLockOn {
            SettingsDivider()
            SettingsRow(
                SettingsStrings.securityLockTimeout, icon: .timer, supporting: Self.timeoutLabel(state.appLockTimeout)
            ) { picker = .timeout }
            .accessibilityIdentifier("app_lock_timeout")
        }
    }

    static func methodLabel(_ m: AppLockMethod) -> String {
        switch m {
        case .biometrics: SettingsStrings.lockMethodBiometrics
        case .passcode: SettingsStrings.lockMethodPasscode
        }
    }

    static func timeoutLabel(_ t: AppLockTimeout) -> String {
        switch t {
        case .immediately: SettingsStrings.timeoutImmediately
        case .oneMinute: SettingsStrings.timeoutOneMinute
        case .fiveMinutes: SettingsStrings.timeoutFiveMinutes
        case .fifteenMinutes: SettingsStrings.timeoutFifteenMinutes
        case .oneHour: SettingsStrings.timeoutOneHour
        }
    }
}

/// The method (with what each asks for, and the note that the app lock never replaces the PIN or the password) or the
/// timeout. Mirrors vettid-android `AppLockMethodDialog` and its timeout `ChoiceDialog`; an iPhone without a passcode
/// cannot use either method, so there is no "Open security settings" (chosen; not in the spec).
struct SecurityPickerSheet: View {
    let picker: SecurityPicker
    let state: SettingsState
    let actions: SettingsActions
    let close: @MainActor () -> Void

    var body: some View {
        switch picker {
        case .method:
            ChoiceSheet(
                title: SettingsStrings.securityLockMethod,
                options: [
                    ChoiceOption(
                        value: .biometrics, label: SettingsStrings.lockMethodBiometrics,
                        detail: SettingsStrings.lockMethodBiometricsBody
                    ),
                    ChoiceOption(
                        value: .passcode, label: SettingsStrings.lockMethodPasscode, detail: SettingsStrings.lockMethodPasscodeBody
                    ),
                ],
                selected: state.appLockMethod,
                note: SettingsStrings.lockMethodNote,
                onPick: { m in
                    close()
                    actions.setAppLockMethod(m)
                },
                onDismiss: close
            )
        case .timeout:
            ChoiceSheet(
                title: SettingsStrings.securityLockTimeout,
                options: AppLockTimeout.allCases.map { ChoiceOption(value: $0, label: AppLockRows.timeoutLabel($0)) },
                selected: state.appLockTimeout,
                onPick: { t in
                    close()
                    actions.setTimeout(t)
                },
                onDismiss: close
            )
        }
    }
}
#endif
