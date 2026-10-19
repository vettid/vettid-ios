#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboardingUI
import VettIDSettings
import VettIDUI

/// What New phone secret can ask for. The PIN is the keypad's, handed over once with ``onSubmit``.
public struct NewPhoneSecretActions {
    public var onPassword: @MainActor (String) -> Void = { _ in }
    /// The PIN from the keypad, then the renew.
    public var onSubmit: @MainActor (_ pin: String) -> Void = { _ in }
    /// The app leaves the foreground or the iPhone locks: typed secrets are dropped.
    public var onForgetSecrets: @MainActor () -> Void = {}
    public var onBack: @MainActor () -> Void = {}

    public init() {}
}

/// Settings → Security → New phone secret (release R, VAULT-MESSAGING §11.14.9): the warning that a new secret alone is
/// not enough (ANDROID-PLAN 0.1.43, before the PIN), the PIN on the in-app keypad (IOS-PLAN §6.5) and the credential
/// password; then the result. Mirrors vettid-android `NewPhoneSecretContent`.
public struct NewPhoneSecretContent: View {
    @Environment(\.scenePhase) private var scenePhase
    let state: NewPhoneSecretState
    let actions: NewPhoneSecretActions
    @State private var pin = PinBuffer()

    public init(state: NewPhoneSecretState, actions: NewPhoneSecretActions = NewPhoneSecretActions()) {
        self.state = state
        self.actions = actions
    }

    private var canSubmit: Bool { state.canSubmit(pinTyped: pin.count) }

    private func submit() {
        guard canSubmit else { return }
        actions.onSubmit(pin.take())
    }

    public var body: some View {
        if state.done {
            FormScaffold(
                title: SecurityStrings.newSecret, message: SecurityStrings.newSecretDone, primaryLabel: SettingsStrings.done,
                onPrimary: actions.onBack, onBack: actions.onBack, header: { HeaderGlyph(symbol: .checkCircle) }
            ) {
                EmptyView()
            }
            .accessibilityIdentifier("new_phone_secret_done")
        } else {
            form
        }
    }

    private var form: some View {
        FormScaffold(
            title: SecurityStrings.newSecret, message: SecurityStrings.newSecretBody, primaryLabel: SecurityStrings.newSecretSubmit,
            primaryEnabled: canSubmit, busy: state.busy, onPrimary: submit, onBack: actions.onBack
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                // ANDROID-PLAN 0.1.43: a new secret does not end what code that ran as the app could reach; said before the PIN.
                NoticeCard(.warning, title: SecurityStrings.newSecret, message: SecurityStrings.newSecretNotEnough)
                    .accessibilityIdentifier("new_secret_not_enough")
                PinEntry(label: SecurityStrings.deletePin, buffer: pin, identifier: "new_secret_pin").disabled(state.busy)
                SecretField(
                    PinStrings.pinPassword, text: Binding(get: { state.password }, set: { actions.onPassword($0) }), onSubmit: submit
                )
                .disabled(state.busy)
                .accessibilityIdentifier("new_secret_password")
                if let error = state.error {
                    NoticeCard(.urgent, title: SecurityStrings.newSecret, message: error.message).accessibilityIdentifier("error")
                }
            }
        }
        .accessibilityIdentifier("new_phone_secret")
        .onDisappear { forget() }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
            if now == .background { forget() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            forget()
        }
    }

    private func forget() {
        pin.clear()
        actions.onForgetSecrets()
    }
}
#endif
