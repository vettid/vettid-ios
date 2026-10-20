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
    /// Settings → Vault → "Update available": the update screen.
    public var releaseUpdate: @MainActor () -> Void = {}
    public var lockVault: @MainActor () -> Void = {}
    public var attestation: @MainActor () -> Void = {}
    public var changePin: @MainActor () -> Void = {}
    public var credential: @MainActor () -> Void = {}
    public var newPhoneSecret: @MainActor () -> Void = {}
    public var setScreenshotsAllowed: @MainActor (Bool) -> Void = { _ in }
    public var deleteVault: @MainActor () -> Void = {}
    public var setAppLock: @MainActor (Bool) -> Void = { _ in }
    public var setAppLockMethod: @MainActor (AppLockMethod) -> Void = { _ in }
    public var setTimeout: @MainActor (AppLockTimeout) -> Void = { _ in }
    /// Settings → App → Theme.
    public var setTheme: @MainActor (ThemePreference) -> Void = { _ in }
    public var acknowledgeInvalidated: @MainActor () -> Void = {}
    public var dismissAppLockUnavailable: @MainActor () -> Void = {}
    public var accountSite: @MainActor () -> Void = {}
    public var dismissError: @MainActor () -> Void = {}

    public init() {}
}

/// Settings (ANDROID-PLAN §4 "Screens", Settings): the account card, then Vault, Security, App and Account, in
/// vettid-android's order; grouped cards (Proton); the vault's lock and Allow screenshots confirm first. A row is shown
/// only once its feature works; "Update available" while the vault has a release update to approve (RELEASE-UPDATES §2);
/// the rest come with the rows of IOS-PLAN §8 that bring them: Notifications (phase P, IOS-PLAN §6.7), Move to a new
/// phone and Recovery (I3, VAULT-MESSAGING §6.7.1, §11.11), the Privacy section (shared profile, sharing rules: I2 and I3,
/// VAULT-MESSAGING §10.8), and Allow screenshots (IOS-PLAN §4), which waits for the first screen that holds the secure
/// layer (`SecureContainer`: received photos, I2; the typed recovery code and the recovery open, I3): until then it would
/// turn off nothing (``screenshotsRowShown``). Mirrors vettid-android `SettingsContent`.
public struct SettingsContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    /// Allow screenshots is shown once a screen holds the secure layer it turns off (no `SecureContainer` is in use yet).
    static let screenshotsRowShown = false

    @Environment(\.vettIDColors) private var colors
    let state: SettingsState
    let ownerCheck: OwnerCheckSettingsState
    let actions: SettingsActions
    let ownerCheckActions: OwnerCheckSettingsActions
    let now: Date
    @State private var confirmLock = false
    @State private var confirmScreenshots: Bool
    @State private var picker: SettingsPicker?

    /// [askScreenshots]: Allow screenshots' confirmation shows from the start (the debug screen catalog).
    public init(
        state: SettingsState,
        ownerCheck: OwnerCheckSettingsState = OwnerCheckSettingsState(),
        actions: SettingsActions = SettingsActions(),
        ownerCheckActions: OwnerCheckSettingsActions = OwnerCheckSettingsActions(),
        now: Date = Date(),
        askScreenshots: Bool = false
    ) {
        self.state = state
        self.ownerCheck = ownerCheck
        self.actions = actions
        self.ownerCheckActions = ownerCheckActions
        self.now = now
        _confirmScreenshots = State(initialValue: askScreenshots)
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
                        if state.phoneSecret {
                            SettingsRow(
                                SecurityStrings.newSecret, icon: .key, supporting: SecurityStrings.newSecretRowBody,
                                action: actions.newPhoneSecret
                            )
                            .accessibilityIdentifier("new_phone_secret_row")
                            SettingsDivider()
                        }
                        SettingsRow(SettingsStrings.securityAttestation, icon: .verifiedUser, action: actions.attestation)
                            .accessibilityIdentifier("attestation")
                        OwnerCheckSettingsRows(state: ownerCheck, actions: ownerCheckActions, now: now)
                        AppLockRows(state: state, actions: actions, picker: $picker)
                    }
                    appSection
                    SettingsSectionHeader(SettingsStrings.sectionAccount)
                    SettingsGroup {
                        SettingsRow(SettingsStrings.accountSite, icon: .openInNew, showChevron: false, action: actions.accountSite)
                            .accessibilityIdentifier("account_site")
                        SettingsDivider()
                        SettingsRow(
                            SecurityStrings.deleteVault, icon: .delete, iconTint: colors.error, supporting: SecurityStrings.deleteVaultBody,
                            action: actions.deleteVault
                        )
                        .accessibilityIdentifier("delete_vault")
                    }
                    Spacer().frame(height: Spacing.xxl)
                }
            }
        }
        .confirmDialog(
            isPresented: $confirmLock, title: SettingsStrings.vaultLock, message: SettingsStrings.vaultLockBody,
            confirmLabel: SettingsStrings.vaultLock, dismissLabel: SettingsStrings.cancel, onConfirm: actions.lockVault
        )
        .confirmDialog(
            isPresented: $confirmScreenshots, title: SecurityStrings.screenshotsConfirmTitle,
            message: SecurityStrings.screenshotsConfirmBody, confirmLabel: SecurityStrings.screenshotsConfirm,
            dismissLabel: SettingsStrings.cancel, onConfirm: { actions.setScreenshotsAllowed(true) }
        )
        .choiceSheet(item: $picker) { p in
            SettingsPickerSheet(picker: p, state: state, actions: actions) { picker = nil }
        }
    }

    /// App: Theme (a choice of three, as vettid-android's `ChoiceDialog`), then Allow screenshots once it is shown.
    private var appSection: some View {
        VStack(spacing: 0) {
            SettingsSectionHeader(SecurityStrings.sectionApp)
            SettingsGroup {
                SettingsRow(SettingsStrings.appTheme, icon: .darkMode, supporting: Self.themeLabel(state.theme)) { picker = .theme }
                    .accessibilityIdentifier("theme")
                if Self.screenshotsRowShown {
                    SettingsDivider()
                    AllowScreenshotsRow(state: state, actions: actions, confirm: $confirmScreenshots)
                }
            }
        }
    }

    static func themeLabel(_ t: ThemePreference) -> String {
        switch t {
        case .system: SettingsStrings.themeSystem
        case .light: SettingsStrings.themeLight
        case .dark: SettingsStrings.themeDark
        }
    }

    @ViewBuilder private var notices: some View {
        if let error = state.error {
            NoticeCard(.urgent, title: error.title(or: SettingsStrings.title), message: error.message(timeScale: timeScale)) {
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
                // The proactive release update (owner decision 2026-10-09): while the vault has one to approve.
                if let o = state.update {
                    SettingsRow(
                        SettingsStrings.vaultUpdate, icon: .systemUpdate, iconTint: o.kind == .available ? colors.primary : colors.error,
                        supporting: SettingsStrings.vaultUpdateBody(Int(o.target.number), Int(o.current.number)),
                        action: actions.releaseUpdate
                    )
                    .accessibilityIdentifier("release_update_row")
                    SettingsDivider()
                }
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

/// "Allow screenshots" (IOS-PLAN §4; owner decision 2026-10-11): turns off only the secure layer of the screens that hold
/// it, the app switcher's cover and capture hiding staying on. Turning it on asks first, in a dialog that says plainly
/// what it does; turning it off does not ask. Mirrors vettid-android `AllowScreenshotsRow`.
struct AllowScreenshotsRow: View {
    let state: SettingsState
    let actions: SettingsActions
    @Binding var confirm: Bool

    var body: some View {
        SettingsSwitchRow(SecurityStrings.screenshots, isOn: isOn, icon: .screenshot, supporting: Self.supporting(state))
            .accessibilityIdentifier("allow_screenshots")
    }

    /// On asks first; off does not.
    private var isOn: Binding<Bool> {
        let actions = actions
        let confirm = $confirm
        return Binding(get: { state.screenshotsAllowed }, set: { on in
            if on { confirm.wrappedValue = true } else { actions.setScreenshotsAllowed(false) }
        })
    }

    static func supporting(_ s: SettingsState) -> String {
        if !s.screenshotsAllowed { return SecurityStrings.screenshotsOff }
        return s.screenshotsStayOn ? SecurityStrings.screenshotsOnDevelopment : SecurityStrings.screenshotsOn
    }
}

/// Which of the screen's choices is open: the app lock's method or timeout, or the theme.
enum SettingsPicker: String, Identifiable {
    case method, timeout, theme

    var id: String { rawValue }
}

/// The app lock's rows (ANDROID-PLAN D6, IOS-PLAN ID17): the switch, "Unlock with", and "Lock after" while it is on.
struct AppLockRows: View {
    let state: SettingsState
    let actions: SettingsActions
    @Binding var picker: SettingsPicker?

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

/// The method (with what each asks for, and the note that the app lock never replaces the PIN or the password), the
/// timeout or the theme. Mirrors vettid-android `AppLockMethodDialog` and its timeout and theme `ChoiceDialog`s; an iPhone
/// without a passcode cannot use either method, so there is no "Open security settings" (chosen; not in the spec).
struct SettingsPickerSheet: View {
    let picker: SettingsPicker
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
        case .theme:
            ChoiceSheet(
                title: SettingsStrings.appTheme,
                options: ThemePreference.allCases.map { ChoiceOption(value: $0, label: SettingsContent.themeLabel($0)) },
                selected: state.theme,
                onPick: { t in
                    close()
                    actions.setTheme(t)
                },
                onDismiss: close
            )
        }
    }
}
#endif
