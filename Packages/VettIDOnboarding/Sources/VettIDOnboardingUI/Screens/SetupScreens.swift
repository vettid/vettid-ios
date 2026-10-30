#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

// The setup-code screens: welcome, scan, type, the account to confirm, and a vault that is elsewhere. Mirrors
// vettid-android `OnboardingScreens.kt`.

public struct WelcomeScreen: View {
    let onStart: @MainActor () -> Void
    let onTransfer: @MainActor () -> Void
    let onRecover: @MainActor () -> Void
    /// (IOS-PLAN §4.2) "Your vault was deleted…", once after a vault was deleted; seen when the member leaves.
    let deletedNotice: Bool
    let onOpenAccountSite: @MainActor () -> Void
    let onNoticeSeen: @MainActor () -> Void

    public init(
        onStart: @escaping @MainActor () -> Void,
        onTransfer: @escaping @MainActor () -> Void,
        onRecover: @escaping @MainActor () -> Void,
        deletedNotice: Bool = false,
        onOpenAccountSite: @escaping @MainActor () -> Void = {},
        onNoticeSeen: @escaping @MainActor () -> Void = {}
    ) {
        self.onStart = onStart
        self.onTransfer = onTransfer
        self.onRecover = onRecover
        self.deletedNotice = deletedNotice
        self.onOpenAccountSite = onOpenAccountSite
        self.onNoticeSeen = onNoticeSeen
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.welcomeTitle,
            message: OnboardingStrings.welcomeBody,
            primaryLabel: OnboardingStrings.welcomeStart,
            secondaryLabel: OnboardingStrings.welcomeTransfer,
            onPrimary: onStart,
            onSecondary: onTransfer,
            header: {
                RookLogo(height: 88)
                    .padding(.top, Spacing.xxl)
                    .padding(.bottom, Spacing.xl)
            }
        ) {
            if deletedNotice {
                NoticeCard(.info, title: OnboardingStrings.vaultDeletedNotice, message: "") {
                    TextLink(
                        OnboardingStrings.vaultDeletingAccountSite, identifier: "vault_deleted_account_site", action: onOpenAccountSite
                    )
                }
                .accessibilityIdentifier("vault_deleted_notice")
                .padding(.bottom, Spacing.l)
            }
            WelcomePoint(symbol: .key, text: OnboardingStrings.welcomePointKeys)
            WelcomePoint(symbol: .verifiedUser, text: OnboardingStrings.welcomePointMember).padding(.top, Spacing.l)
            TextLink(OnboardingStrings.welcomeRecover, identifier: "welcome_recover", action: onRecover).padding(.top, Spacing.l)
        }
        .onDisappear { if deletedNotice { onNoticeSeen() } }
    }
}

/// The setup QR from the account portal (VAULT-MESSAGING §11.12.1); typing the code is the fallback.
public struct SetupScanScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions
    let onBack: (@MainActor () -> Void)?
    let onOpenAccountSite: @MainActor () -> Void
    let camera: AnyView?

    public init(
        state: OnboardingState,
        actions: any OnboardingActions,
        onBack: (@MainActor () -> Void)?,
        onOpenAccountSite: @escaping @MainActor () -> Void,
        camera: AnyView? = nil
    ) {
        self.state = state
        self.actions = actions
        self.onBack = onBack
        self.onOpenAccountSite = onOpenAccountSite
        self.camera = camera
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.setupScanTitle,
            message: OnboardingStrings.setupScanBody,
            primaryLabel: nil,
            busy: state.busy,
            secondaryLabel: OnboardingStrings.setupType,
            onPrimary: {},
            onSecondary: actions.typeCode,
            onBack: onBack
        ) {
            if state.busy {
                NoticeCard(.info, title: OnboardingStrings.setupRedeeming, message: OnboardingStrings.setupRedeemingBody)
            } else {
                ScannerBox(onText: actions.scanned, onTypeInstead: actions.typeCode, camera: camera)
            }
            ScanRefusalNotice(state: state)
            ErrorNotice(state: state, override: .setupCodeInvalid, overrideText: OnboardingStrings.setupInvalid)
            TextLink(OnboardingStrings.setupOpenSite, action: onOpenAccountSite).padding(.top, Spacing.l)
            DevHintNotice(state: state)
        }
        .accessibilityIdentifier("setup_scan")
    }
}

/// The short code typed with the account's email (never the code alone, §11.12.1). The code is typed in a visible
/// field without AutoFill, autocorrection or suggestions (IOS-PLAN §6.5), in capitals, grouped `XXXX-XXXX`.
public struct SetupTypeScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions
    let onBack: (@MainActor () -> Void)?
    @FocusState private var emailFocused: Bool
    /// The code field takes the keyboard: after "Next" on the email, until the email has it again.
    @State private var codeFocused = false

    public init(state: OnboardingState, actions: any OnboardingActions, onBack: (@MainActor () -> Void)?) {
        self.state = state
        self.actions = actions
        self.onBack = onBack
    }

    public var body: some View {
        let actions = actions
        FormScaffold(
            title: OnboardingStrings.setupTypeTitle,
            message: OnboardingStrings.setupTypeBody,
            primaryLabel: OnboardingStrings.continueLabel,
            primaryEnabled: !state.email.trimmingCharacters(in: .whitespaces).isEmpty
                && !state.codeInput.trimmingCharacters(in: .whitespaces).isEmpty,
            busy: state.busy,
            onPrimary: actions.submitCode,
            onBack: onBack
        ) {
            LabeledField(
                label: OnboardingStrings.setupEmailLabel,
                supporting: state.emailInvalid ? OnboardingStrings.setupEmailInvalid : nil,
                isError: state.emailInvalid
            ) {
                TextField("", text: Binding(get: { state.email }, set: { actions.setEmail($0) }))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // "Next" goes on to the code (as vettid-android's `ImeAction.Next`).
                    .submitLabel(.next)
                    .focused($emailFocused)
                    .onSubmit { codeFocused = true }
                    .onChange(of: emailFocused) { _, now in if now { codeFocused = false } }
                    .accessibilityIdentifier("setup_email")
            }
            LabeledField(
                label: OnboardingStrings.setupCodeLabel,
                supporting: state.codeInvalid ? OnboardingStrings.setupCodeInvalid : OnboardingStrings.setupCodeHint,
                isError: state.codeInvalid,
                framed: false
            ) {
                // VettIDUI's visible secret field (IOS-PLAN §6.5): no AutoFill, suggestions or keyboard learning.
                VisibleSecretField(
                    OnboardingStrings.setupCodeLabel,
                    text: Binding(get: { state.codeInput }, set: { actions.setCode(SetupCodeFormat.grouped($0)) }),
                    placeholder: Self.placeholder,
                    capitalization: .allCharacters,
                    monospaced: true,
                    isError: state.codeInvalid,
                    focus: codeFocused,
                    onSubmit: { actions.submitCode() }
                )
                .accessibilityIdentifier("setup_code")
            }
            .padding(.top, Spacing.m)
            ErrorNotice(state: state, override: .setupCodeInvalid, overrideText: OnboardingStrings.setupInvalid)
            DevHintNotice(state: state)
        }
    }
}

extension SetupTypeScreen {
    /// What the empty code field shows (vettid-android writes it as is, not as a string resource).
    static let placeholder = "XXXX-XXXX"
}

/// "Setting up a vault for m***@example.com": the member checks the account before a PIN is asked for.
public struct ConfirmAccountScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions

    public init(state: OnboardingState, actions: any OnboardingActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.confirmAccountTitle,
            message: OnboardingStrings.confirmAccountBody(state.emailHint),
            primaryLabel: OnboardingStrings.confirmAccountYes,
            busy: state.busy,
            secondaryLabel: OnboardingStrings.confirmAccountNo,
            onPrimary: actions.confirmAccount,
            onSecondary: actions.useAnotherCode
        ) {
            NoticeCard(.info, title: OnboardingStrings.confirmAccountHintTitle, message: state.emailHint)
                .accessibilityIdentifier("email_hint")
            ErrorNotice(state: state)
        }
        .accessibilityIdentifier("confirm_account")
    }
}

public struct VaultElsewhereScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions
    let onOpenAccountSite: @MainActor () -> Void

    public init(state: OnboardingState, actions: any OnboardingActions, onOpenAccountSite: @escaping @MainActor () -> Void) {
        self.state = state
        self.actions = actions
        self.onOpenAccountSite = onOpenAccountSite
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.elsewhereTitle,
            message: OnboardingStrings.elsewhereBody,
            primaryLabel: OnboardingStrings.elsewhereTransfer,
            busy: state.busy,
            secondaryLabel: OnboardingStrings.elsewhereRecover,
            onPrimary: actions.transfer,
            onSecondary: actions.recover
        ) {
            NoticeCard(.info, title: OnboardingStrings.elsewhereTransferTitle, message: OnboardingStrings.elsewhereTransferBody)
                .accessibilityIdentifier("elsewhere_transfer")
            NoticeCard(.warning, title: OnboardingStrings.elsewhereRecoveryTitle, message: OnboardingStrings.elsewhereRecoveryBody) {
                TextLink(OnboardingStrings.elsewhereOpen, action: onOpenAccountSite)
            }
            .accessibilityIdentifier("elsewhere_recovery")
            .padding(.top, Spacing.m)
            TextLink(OnboardingStrings.elsewhereAnyway, action: actions.enrollAnyway).padding(.top, Spacing.l)
            TextLink(OnboardingStrings.otherCode, action: actions.useAnotherCode)
            // (iOS) The refresh after leaving a move, or "use a different code", can fail here.
            ErrorNotice(state: state)
        }
    }
}
#endif
