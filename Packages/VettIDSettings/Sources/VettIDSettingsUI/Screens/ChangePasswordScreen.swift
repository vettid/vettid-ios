#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboardingUI
import VettIDSettings
import VettIDUI

/// What the password change can ask for. Mirrors vettid-android `ChangePasswordContent`'s callbacks; the PIN is the
/// keypad's, handed over once with ``onSubmit``.
public struct ChangePasswordActions {
    public var onCurrent: @MainActor (String) -> Void = { _ in }
    public var onPassword: @MainActor (String) -> Void = { _ in }
    public var onConfirm: @MainActor (String) -> Void = { _ in }
    /// The PIN from the keypad (release R; nil when none is asked), then the change.
    public var onSubmit: @MainActor (_ pin: String?) -> Void = { _ in }
    public var onForgetSecrets: @MainActor () -> Void = {}
    public var onBack: @MainActor () -> Void = {}

    public init() {}
}

/// Credential → Change password (VAULT-MESSAGING §10.6; release R §11.14.9 with the PIN on the in-app keypad): the current
/// password, the new one under the rules of release R as the member types (ANDROID-PLAN "Passwords"), and the new one
/// again. Mirrors vettid-android `ChangePasswordContent`.
public struct ChangePasswordContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.scenePhase) private var scenePhase
    let state: ChangePasswordState
    let actions: ChangePasswordActions
    @State private var pin = PinBuffer()

    public init(state: ChangePasswordState, actions: ChangePasswordActions = ChangePasswordActions()) {
        self.state = state
        self.actions = actions
    }

    private var canSubmit: Bool { !state.busy && state.canSubmit(pinTyped: pin.count) }

    private func submit() {
        guard canSubmit else { return }
        actions.onSubmit(state.askPin ? pin.take() : nil)
    }

    public var body: some View {
        if state.done {
            FormScaffold(title: CredentialStrings.changeDone, primaryLabel: CredentialStrings.done, onPrimary: actions.onBack) {
                EmptyView()
            }
            .accessibilityIdentifier("change_password_done")
        } else {
            form
        }
    }

    private var form: some View {
        FormScaffold(
            title: CredentialStrings.changeTitle, message: CredentialStrings.changeBody, primaryLabel: CredentialStrings.changeSubmit,
            primaryEnabled: canSubmit, busy: state.busy, onPrimary: submit, onBack: actions.onBack
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if state.askPin {
                    // Release R (§11.14.9): the vault verifies its PIN with the password change.
                    PinEntry(label: CredentialStrings.changePin, buffer: pin, identifier: "change_password_pin").disabled(state.busy)
                }
                SecretField(CredentialStrings.passwordCurrent, text: Binding(get: { state.current }, set: { actions.onCurrent($0) }))
                    .accessibilityIdentifier("change_password_current")
                VStack(alignment: .leading, spacing: Spacing.s) {
                    SecretField(
                        CredentialStrings.passwordNew, text: Binding(get: { state.password }, set: { actions.onPassword($0) }),
                        error: state.same ? CredentialStrings.passwordSame : nil
                    )
                    .accessibilityIdentifier("change_password_new")
                    PasswordRuleText(rule: state.rule, refused: state.refused).accessibilityIdentifier("password_rule")
                }
                SecretField(
                    CredentialStrings.passwordConfirm, text: Binding(get: { state.confirm }, set: { actions.onConfirm($0) }),
                    error: state.mismatch ? CredentialStrings.passwordMismatch : nil, onSubmit: submit
                )
                .accessibilityIdentifier("change_password_confirm")
                if let check = state.check, let text = Self.text(check) {
                    // VAULT-MESSAGING §11.14.9 "A lost answer": no failure while the change is decided.
                    NoticeCard(.info, title: CredentialStrings.title, message: text).accessibilityIdentifier("change_check")
                }
                if let error = state.error {
                    NoticeCard(.urgent, title: error.title(or: CredentialStrings.title), message: error.message(timeScale: timeScale))
                        .accessibilityIdentifier("error")
                }
            }
            .disabled(state.busy)
        }
        .accessibilityIdentifier("change_password")
        .onDisappear { forget() }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
            if now == .background { forget() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            forget()
        }
    }

    /// The text of a lost answer's decision shown on the form.
    static func text(_ check: ChangeCheck.Status) -> String? {
        switch check {
        case .checking: CredentialStrings.passwordChecking
        case .unreachable: CredentialStrings.passwordUnreachable
        case .notApplied: CredentialStrings.passwordNotChanged
        case .ended: CredentialStrings.passwordEnded
        default: nil
        }
    }

    private func forget() {
        pin.clear()
        actions.onForgetSecrets()
    }
}
#endif
