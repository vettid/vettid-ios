#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboardingUI
import VettIDSettings
import VettIDUI

/// What the deletion screen can ask for. The PIN is the keypad's, handed over once with the first press (``submit``).
/// Mirrors vettid-android `DeleteVaultActions`.
public struct DeleteVaultActions {
    public var setPhrase: @MainActor (String) -> Void = { _ in }
    public var setPassword: @MainActor (String) -> Void = { _ in }
    public var setAcknowledged: @MainActor (Bool) -> Void = { _ in }
    /// The PIN from the keypad (nil: none typed since it was handed over), then the phrase checked and the final
    /// confirmation asked for.
    public var submit: @MainActor (_ pin: String?) -> Void = { _ in }
    public var cancelConfirm: @MainActor () -> Void = {}
    public var confirm: @MainActor () -> Void = {}
    /// (iPhone) After a lost answer: asks the account service again.
    public var checkAgain: @MainActor () -> Void = {}
    /// The app leaves the foreground or the iPhone locks: typed secrets are dropped.
    public var forgetSecrets: @MainActor () -> Void = {}
    public var back: @MainActor () -> Void = {}

    public init() {}
}

/// Settings → Account → Delete vault (VAULT-MESSAGING §12.5): the phrase, the PIN on the in-app keypad (IOS-PLAN §6.5), the
/// credential password, the acknowledgement, then a final confirmation. After the vault's answer VettID's data on this phone is erased and
/// the welcome screen follows. A lost answer is said, with a check that sends nothing to the vault (chosen; not in the
/// spec). Mirrors vettid-android `DeleteVaultContent`.
public struct DeleteVaultContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.vettIDColors) private var colors
    @Environment(\.scenePhase) private var scenePhase
    let state: DeleteVaultState
    let actions: DeleteVaultActions
    @State private var pin = PinBuffer()

    public init(state: DeleteVaultState, actions: DeleteVaultActions = DeleteVaultActions()) {
        self.state = state
        self.actions = actions
    }

    private var ready: Bool { state.ready(pinTyped: max(pin.count, state.pin.count)) }

    private func submit() {
        guard ready, !state.busy else { return }
        actions.submit(pin.count > 0 ? pin.take() : nil)
    }

    public var body: some View {
        FormScaffold(
            title: SecurityStrings.deleteTitle, message: SecurityStrings.deleteBody, primaryLabel: SecurityStrings.deleteSubmit,
            primaryEnabled: ready, busy: state.busy, destructive: true, onPrimary: submit, onBack: actions.back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                phraseField
                PinEntry(label: SecurityStrings.deletePin, buffer: pin, identifier: "delete_pin")
                SecretField(SecurityStrings.deletePassword, text: Binding(get: { state.password }, set: { actions.setPassword($0) }))
                    .accessibilityIdentifier("delete_password")
                acknowledgement
                if state.unconfirmed {
                    NoticeCard(.warning, title: SecurityStrings.deleteTitle, message: SecurityStrings.deleteUnconfirmed) {
                        NoticeAction(label: SecurityStrings.deleteCheckAgain, identifier: "delete_check_again", action: actions.checkAgain)
                    }
                    .accessibilityIdentifier("delete_unconfirmed")
                }
                if state.notDeleted {
                    NoticeCard(.info, title: SecurityStrings.deleteTitle, message: SecurityStrings.deleteNotDeleted)
                        .accessibilityIdentifier("delete_not_deleted")
                }
                if let error = state.error {
                    NoticeCard(.urgent, title: SecurityStrings.deleteTitle, message: error.message(timeScale: timeScale))
                        .accessibilityIdentifier("error")
                }
            }
            .disabled(state.busy)
        }
        .accessibilityIdentifier("delete_vault_screen")
        // The final confirmation (vettid-android `ConfirmDialog`). Each button tells the view model, which ends the
        // confirmation; the alert's own dismissal changes nothing, whichever comes first.
        .alert(SecurityStrings.deleteConfirmTitle, isPresented: Binding(get: { state.confirming }, set: { _ in })) {
            Button(SecurityStrings.deleteConfirm, role: .destructive, action: actions.confirm).accessibilityIdentifier("confirm_button")
            Button(SettingsStrings.cancel, role: .cancel, action: actions.cancelConfirm)
        } message: {
            Text(SecurityStrings.deleteConfirmBody)
        }
        .onDisappear { forget() }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
            if now == .background { forget() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            forget()
        }
    }

    /// The phrase: not a secret, but kept from AutoFill (a plain field beside the password could be taken for a user
    /// name) and from any autocorrection, capitalization or suggestion that would change what the member types.
    private var phraseField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(SecurityStrings.deletePhraseLabel)
                .vettIDFont(.labelMedium)
                .foregroundStyle(state.phraseWrong ? colors.error : colors.onSurfaceVariant)
            VisibleSecretField(
                SecurityStrings.deletePhraseLabel, text: Binding(get: { state.phrase }, set: { actions.setPhrase($0) }),
                placeholder: "", isError: state.phraseWrong
            )
            .accessibilityIdentifier("delete_phrase")
            if state.phraseWrong {
                Text(SecurityStrings.deletePhraseWrong).vettIDFont(.bodySmall).foregroundStyle(colors.error)
            }
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
                Text(SecurityStrings.deleteAck)
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
        .accessibilityIdentifier("delete_ack")
    }

    private func forget() {
        pin.clear()
        actions.forgetSecrets()
    }
}
#endif
