#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboardingUI
import VettIDSettings
import VettIDUI

/// What the new credential's form can ask for. The PIN is the keypad's, handed over once with the first press
/// (``submit``). Mirrors vettid-android `NewCredentialActions`.
public struct NewCredentialActions {
    public var setCurrent: @MainActor (String) -> Void = { _ in }
    public var setPassword: @MainActor (String) -> Void = { _ in }
    public var setConfirm: @MainActor (String) -> Void = { _ in }
    public var setAcknowledged: @MainActor (Bool) -> Void = { _ in }
    /// The PIN from the keypad (nil: none typed since it was handed over), then the form checked and the final
    /// confirmation asked for.
    public var submit: @MainActor (_ pin: String?) -> Void = { _ in }
    public var cancelConfirm: @MainActor () -> Void = {}
    public var confirm: @MainActor () -> Void = {}
    public var forgetSecrets: @MainActor () -> Void = {}
    public var back: @MainActor () -> Void = {}

    public init() {}
}

/// Credential → New credential (VAULT-MESSAGING §3.5.5, `credential.reset`): the warning that every critical item is
/// destroyed, the PIN on the in-app keypad (IOS-PLAN §6.5), the current password, the new one under the rules of release R
/// and again, the acknowledgement, then a final confirmation. Mirrors vettid-android `NewCredentialContent`.
public struct NewCredentialContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.vettIDColors) private var colors
    @Environment(\.scenePhase) private var scenePhase
    let state: NewCredentialState
    let actions: NewCredentialActions
    @State private var pin = PinBuffer()

    public init(state: NewCredentialState, actions: NewCredentialActions = NewCredentialActions()) {
        self.state = state
        self.actions = actions
    }

    private var ready: Bool { !state.busy && state.filled(pinTyped: pin.count) }

    private func submit() {
        guard ready else { return }
        actions.submit(pin.count > 0 ? pin.take() : nil)
    }

    public var body: some View {
        if state.done {
            FormScaffold(
                title: CredentialStrings.newDone, message: CredentialStrings.newDoneBody, primaryLabel: CredentialStrings.done,
                onPrimary: actions.back
            ) {
                EmptyView()
            }
            .accessibilityIdentifier("new_credential_done")
        } else {
            form
        }
    }

    private var form: some View {
        FormScaffold(
            title: CredentialStrings.newTitle, message: CredentialStrings.newBody, primaryLabel: CredentialStrings.newSubmit,
            primaryEnabled: ready, busy: state.busy, destructive: true, onPrimary: submit, onBack: actions.back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                NoticeCard(.urgent, title: CredentialStrings.newWarningTitle, message: CredentialStrings.newWarning)
                PinEntry(label: CredentialStrings.newPin, buffer: pin, identifier: "new_credential_pin")
                SecretField(CredentialStrings.passwordCurrent, text: Binding(get: { state.current }, set: { actions.setCurrent($0) }))
                    .accessibilityIdentifier("new_credential_current")
                VStack(alignment: .leading, spacing: Spacing.s) {
                    SecretField(CredentialStrings.passwordNew, text: Binding(get: { state.password }, set: { actions.setPassword($0) }))
                        .accessibilityIdentifier("new_credential_new")
                    PasswordRuleText(rule: state.rule, refused: state.refused).accessibilityIdentifier("password_rule")
                }
                SecretField(
                    CredentialStrings.passwordConfirm, text: Binding(get: { state.confirm }, set: { actions.setConfirm($0) }),
                    error: state.mismatch ? CredentialStrings.passwordMismatch : nil, onSubmit: submit
                )
                .accessibilityIdentifier("new_credential_confirm")
                acknowledgement
                if let check = state.check, let text = Self.text(check) {
                    // VAULT-MESSAGING 0.48.0 §11.14.9 "A lost answer to `credential.reset`": no failure while it is decided.
                    NoticeCard(.info, title: CredentialStrings.newTitle, message: text).accessibilityIdentifier("change_check")
                }
                if let error = state.error {
                    NoticeCard(.urgent, title: CredentialStrings.newTitle, message: error.message(timeScale: timeScale))
                        .accessibilityIdentifier("error")
                }
            }
            .disabled(state.busy)
        }
        .accessibilityIdentifier("new_credential")
        // The final confirmation (vettid-android `ConfirmDialog`, destructive). Each button tells the view model, which
        // ends the confirmation; the alert's own dismissal changes nothing, whichever comes first.
        .alert(CredentialStrings.newConfirmTitle, isPresented: Binding(get: { state.confirming }, set: { _ in })) {
            Button(CredentialStrings.newSubmit, role: .destructive, action: actions.confirm).accessibilityIdentifier("confirm_button")
            Button(CredentialStrings.cancel, role: .cancel, action: actions.cancelConfirm)
        } message: {
            Text(CredentialStrings.newWarning)
        }
        .forgetsSecrets(scenePhase: scenePhase) {
            pin.clear()
            actions.forgetSecrets()
        }
    }

    /// The text of a lost answer's decision shown on the form.
    static func text(_ check: ChangeCheck.Status) -> String? {
        switch check {
        case .checking: CredentialStrings.newChecking
        case .unreachable: CredentialStrings.newUnreachable
        case .notApplied: CredentialStrings.newNotMade
        case .ended: CredentialStrings.newEnded
        case .notHolder: ChangeCheckNotice.holderMoved
        default: nil
        }
    }

    /// The acknowledgement: a checkbox row; the whole row toggles.
    private var acknowledgement: some View {
        Button { actions.setAcknowledged(!state.acknowledged) } label: {
            HStack(spacing: Spacing.m) {
                (state.acknowledged ? VettIDSymbol.checkBox : VettIDSymbol.checkBoxOutline).image
                    .font(.system(size: 22))
                    .foregroundStyle(state.acknowledged ? colors.primary : colors.onSurfaceVariant)
                    .accessibilityHidden(true)
                Text(CredentialStrings.newAck)
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(state.acknowledged ? "1" : "0")
        .accessibilityIdentifier("new_credential_ack")
    }
}
#endif
