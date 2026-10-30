#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

/// What the rotation can ask for. Mirrors vettid-android `RotateContent`'s callbacks.
public struct RotateActions {
    public var onPassword: @MainActor (String) -> Void = { _ in }
    public var onSubmit: @MainActor () -> Void = {}
    public var onForgetSecrets: @MainActor () -> Void = {}
    public var onBack: @MainActor () -> Void = {}

    public init() {}
}

/// Credential → Rotate the credential key (VAULT-MESSAGING §3.5.5), also opened from the offer after a PIN or password
/// change: the credential password, then "Rotate now". Mirrors vettid-android `RotateContent`.
public struct RotateContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.scenePhase) private var scenePhase
    let state: RotateState
    let actions: RotateActions

    public init(state: RotateState, actions: RotateActions = RotateActions()) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        if state.done {
            FormScaffold(title: CredentialStrings.rotateDone, primaryLabel: CredentialStrings.done, onPrimary: actions.onBack) {
                EmptyView()
            }
            .accessibilityIdentifier("rotate_done")
        } else {
            form
        }
    }

    private var form: some View {
        FormScaffold(
            title: CredentialStrings.rotateTitle, message: CredentialStrings.rotateBody, primaryLabel: CredentialStrings.rotateSubmit,
            primaryEnabled: !state.password.isEmpty && !state.busy, busy: state.busy, onPrimary: actions.onSubmit,
            onBack: actions.onBack
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                SecretField(
                    CredentialStrings.passwordLabel, text: Binding(get: { state.password }, set: { actions.onPassword($0) }),
                    onSubmit: actions.onSubmit
                )
                .accessibilityIdentifier("rotate_password")
                if let error = state.error {
                    NoticeCard(
                        .urgent, title: error.title(or: CredentialStrings.title), message: error.message(timeScale: timeScale),
                        announce: .assertive
                    )
                        .accessibilityIdentifier("error")
                }
            }
            .disabled(state.busy)
        }
        .accessibilityIdentifier("rotate")
        .forgetsSecrets(scenePhase: scenePhase, actions.onForgetSecrets)
    }
}
#endif
