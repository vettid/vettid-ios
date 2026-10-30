#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

// The vault screens: PIN, its confirmation, the credential password, the backup choice, the progress and the end.
// Mirrors vettid-android `OnboardingScreens.kt`. The PIN is typed on the in-app keypad (IOS-PLAN §6.5, ID11), never a
// keyboard: its digits stay in the keypad's buffer, which hands them to the model once, on Continue, and is zeroed
// when the screen goes.

public struct PinCreateScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions
    @State private var pin = PinBuffer()

    public init(state: OnboardingState, actions: any OnboardingActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.pinTitle,
            message: OnboardingStrings.pinBody,
            primaryLabel: OnboardingStrings.continueLabel,
            primaryEnabled: pin.count > 0,
            onPrimary: {
                actions.setPin(pin.take())
                actions.submitPin()
            }
        ) {
            // The problem of the PIN just submitted, until the member types again.
            PinEntry(
                label: OnboardingStrings.pinLabel,
                buffer: pin,
                error: pin.count == 0 ? state.pinProblem?.message : nil,
                identifier: "pin"
            )
            ErrorNotice(state: state)
        }
        .onDisappear { pin.clear() }
    }
}

public struct PinConfirmScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions
    let onBack: (@MainActor () -> Void)?
    @State private var pin = PinBuffer()

    public init(state: OnboardingState, actions: any OnboardingActions, onBack: (@MainActor () -> Void)?) {
        self.state = state
        self.actions = actions
        self.onBack = onBack
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.pinConfirmTitle,
            message: OnboardingStrings.pinConfirmBody,
            primaryLabel: OnboardingStrings.continueLabel,
            primaryEnabled: pin.count > 0,
            onPrimary: {
                actions.setPinConfirm(pin.take())
                actions.submitPinConfirm()
            },
            onBack: onBack
        ) {
            PinEntry(
                label: OnboardingStrings.pinConfirmLabel,
                buffer: pin,
                error: state.pinMismatch && pin.count == 0 ? OnboardingStrings.pinMismatch : nil,
                identifier: "pin_confirm"
            )
        }
        .onDisappear { pin.clear() }
    }
}

/// The line under a new password for [rule]: the rule it breaks, or "Strong enough." ([refused]: the vault's verdict).
public struct PasswordRuleText: View {
    let rule: PasswordRule
    let refused: Bool

    public init(rule: PasswordRule, refused: Bool) {
        self.rule = rule
        self.refused = refused
    }

    public var body: some View {
        PasswordRuleLine(rule.message, passes: rule.passes && !refused, hint: rule.hint, refused: refused)
    }
}

/// What the password fields say under them: the rule, whether it is the vault's verdict, and a mismatch.
public struct PasswordVerdict: Equatable, Sendable {
    public var rule: PasswordRule
    public var refused: Bool
    public var mismatch: Bool

    public init(rule: PasswordRule, refused: Bool, mismatch: Bool) {
        self.rule = rule
        self.refused = refused
        self.mismatch = mismatch
    }
}

/// A new credential password with its confirmation and, under it, the password rules of release R as the member types
/// (ANDROID-PLAN "Passwords"; the credential feature has its own copy for password changes).
public struct NewPasswordFields: View {
    let password: Binding<String>
    let confirm: Binding<String>
    let verdict: PasswordVerdict
    let onDone: @MainActor () -> Void

    public init(
        password: Binding<String>, confirm: Binding<String>, verdict: PasswordVerdict, onDone: @escaping @MainActor () -> Void
    ) {
        self.password = password
        self.confirm = confirm
        self.verdict = verdict
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SecretField(OnboardingStrings.passwordLabel, text: password, next: true).accessibilityIdentifier("password")
            PasswordRuleText(rule: verdict.rule, refused: verdict.refused).padding(.top, Spacing.s).accessibilityIdentifier("password_rule")
            SecretField(
                OnboardingStrings.passwordConfirmLabel,
                text: confirm,
                error: verdict.mismatch ? OnboardingStrings.passwordMismatch : nil,
                onSubmit: onDone
            )
            .padding(.top, Spacing.l)
            .accessibilityIdentifier("password_confirm")
        }
    }
}

public struct PasswordScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions
    let onBack: (@MainActor () -> Void)?
    @State private var pin = PinBuffer()

    public init(state: OnboardingState, actions: any OnboardingActions, onBack: (@MainActor () -> Void)?) {
        self.state = state
        self.actions = actions
        self.onBack = onBack
    }

    /// The PIN asked for (release R) is entered: on the keypad, or handed to the model already.
    private var pinReady: Bool { !state.askPin || state.credentialPinReady || pin.count >= OnboardingState.minExistingPin }

    private var canSubmit: Bool {
        !state.password.isEmpty && !state.passwordConfirm.isEmpty && pinReady && state.passwordRule.passes && !state.passwordRefused
    }

    private func submit() {
        if state.askPin && pin.count > 0 { actions.setPin(pin.take()) }
        actions.submitPassword()
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.passwordTitle,
            message: OnboardingStrings.passwordBody,
            primaryLabel: OnboardingStrings.continueLabel,
            primaryEnabled: canSubmit,
            onPrimary: submit,
            onBack: onBack
        ) {
            if state.askPin {
                // Release R (§11.14.9): the vault verifies its PIN when the credential is created.
                PinEntry(label: OnboardingStrings.unlockPinLabel, buffer: pin, identifier: "credential_pin")
                    .padding(.bottom, Spacing.m)
            }
            NewPasswordFields(
                password: Binding(get: { state.password }, set: { actions.setPassword($0) }),
                confirm: Binding(get: { state.passwordConfirm }, set: { actions.setPasswordConfirm($0) }),
                verdict: PasswordVerdict(rule: state.passwordRule, refused: state.passwordRefused, mismatch: state.passwordMismatch),
                onDone: { if canSubmit { submit() } }
            )
            ErrorNotice(state: state)
        }
        .onDisappear { pin.clear() }
    }
}

/// A backup choice card, selected like a radio button.
private struct ChoiceCard: View {
    @Environment(\.vettIDColors) private var colors
    let selected: Bool
    let title: String
    let message: String
    let identifier: String
    let onSelect: @MainActor () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: Spacing.m) {
                (selected ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? colors.primary : colors.onSurfaceVariant)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title).vettIDFont(.titleSmall, weight: .semibold).foregroundStyle(colors.onSurface)
                    Text(message).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            }
            .padding(Spacing.l)
            .background(colors.surfaceContainer, in: VettIDShape.card)
            .overlay(VettIDShape.card.stroke(selected ? colors.primary.color : Color.clear, lineWidth: 2))
            .contentShape(VettIDShape.card)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// The backup choice cards and, when off, the warning with its acknowledgement (§3.5.6). Shared with Credential.
public struct BackupChoice: View {
    @Environment(\.vettIDColors) private var colors
    let backup: Bool
    let acknowledged: Bool
    let onBackup: @MainActor (Bool) -> Void
    let onAcknowledge: @MainActor (Bool) -> Void

    public init(
        backup: Bool,
        acknowledged: Bool,
        onBackup: @escaping @MainActor (Bool) -> Void,
        onAcknowledge: @escaping @MainActor (Bool) -> Void
    ) {
        self.backup = backup
        self.acknowledged = acknowledged
        self.onBackup = onBackup
        self.onAcknowledge = onAcknowledge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ChoiceCard(
                selected: backup, title: OnboardingStrings.backupOn, message: OnboardingStrings.backupOnBody, identifier: "backup_on"
            ) { onBackup(true) }
            ChoiceCard(
                selected: !backup, title: OnboardingStrings.backupOff, message: OnboardingStrings.backupOffBody, identifier: "backup_off"
            ) { onBackup(false) }
            if !backup {
                NoticeCard(.urgent, title: OnboardingStrings.backupOffWarningTitle, message: OnboardingStrings.backupOffWarningBody)
                    .padding(.top, Spacing.s)
                Toggle(isOn: Binding(get: { acknowledged }, set: { onAcknowledge($0) })) {
                    Text(OnboardingStrings.backupOffAck).vettIDFont(.bodyMedium)
                }
                .toggleStyle(CheckboxStyle())
                .accessibilityIdentifier("backup_off_ack")
            }
        }
    }
}

/// A checkbox row at least a touch target high (vettid-android's `Checkbox` with a toggleable row).
private struct CheckboxStyle: ToggleStyle {
    @Environment(\.vettIDColors) private var colors

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Spacing.s) {
                (configuration.isOn ? VettIDSymbol.checkBox : VettIDSymbol.checkBoxOutline).image
                    .font(.system(size: 22))
                    .foregroundStyle(configuration.isOn ? colors.primary : colors.onSurfaceVariant)
                    .accessibilityHidden(true)
                configuration.label.foregroundStyle(colors.onSurface).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }
}

public struct BackupScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions
    let onBack: (@MainActor () -> Void)?

    public init(state: OnboardingState, actions: any OnboardingActions, onBack: (@MainActor () -> Void)?) {
        self.state = state
        self.actions = actions
        self.onBack = onBack
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.backupTitle,
            message: OnboardingStrings.backupBody,
            primaryLabel: OnboardingStrings.backupSubmit,
            primaryEnabled: state.canContinueBackup,
            onPrimary: actions.submitBackup,
            onBack: onBack
        ) {
            BackupChoice(
                backup: state.backup,
                acknowledged: state.backupOffAcknowledged,
                onBackup: { actions.setBackup($0) },
                onAcknowledge: { actions.acknowledgeBackupOff($0) }
            )
        }
    }
}

public struct ProgressScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions

    public init(state: OnboardingState, actions: any OnboardingActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        let failed = state.progressFailed || (state.error != nil && !state.busy)
        // A pending app key lasts an hour (MEMBER-API 2.0.0): after a 401 only a new setup code helps.
        let expired = failed && state.error == .unauthorized && !state.credentialOnly
        let secondary: String? = !failed ? nil : expired ? OnboardingStrings.otherCode : OnboardingStrings.progressEdit
        FormScaffold(
            title: OnboardingStrings.progressTitle,
            message: OnboardingStrings.progressBody,
            primaryLabel: failed ? OnboardingStrings.progressRetry : nil,
            secondaryLabel: secondary,
            onPrimary: actions.run,
            onSecondary: expired ? actions.useAnotherCode : actions.editAfterFailure
        ) {
            StepList(state.progress.map { ($0.step.label, $0.state.stepState) }).accessibilityIdentifier("progress")
            ErrorNotice(state: state)
        }
    }
}

public struct DoneScreen: View {
    let state: OnboardingState
    let actions: any OnboardingActions

    public init(state: OnboardingState, actions: any OnboardingActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.doneTitle,
            message: OnboardingStrings.doneBody,
            primaryLabel: OnboardingStrings.doneGo,
            busy: state.busy,
            onPrimary: actions.finish,
            header: {
                RookLogo(height: 72)
                    .padding(.top, Spacing.xl)
                    .padding(.bottom, Spacing.l)
            }
        ) {
            NoticeCard(.info, title: OnboardingStrings.doneNextTitle, message: OnboardingStrings.doneNextBody)
            // (iOS) A failed finishSetup is shown here; vettid-android's done screen shows none.
            ErrorNotice(state: state)
        }
        .accessibilityIdentifier("onboarding_done")
    }
}
#endif
