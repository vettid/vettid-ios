#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboardingUI
import VettIDSettings
import VettIDUI

/// What the PIN change can ask for. The PINs are the keypad's, each handed over once with its step's "Continue"
/// (IOS-PLAN §6.5). Mirrors vettid-android `ChangePinContent`'s callbacks, with the keypad's steps.
public struct ChangePinActions {
    public var onCurrent: @MainActor (String) -> Void = { _ in }
    public var onPin: @MainActor (String) -> Void = { _ in }
    public var onConfirm: @MainActor (String) -> Void = { _ in }
    public var onPassword: @MainActor (String) -> Void = { _ in }
    /// The step's "Continue" (and, at the last step, "Change PIN").
    public var onNext: @MainActor () -> Void = {}
    /// Back one keypad step.
    public var onStepBack: @MainActor () -> Void = {}
    /// The app leaves the foreground or the iPhone locks: typed secrets are dropped.
    public var onForgetSecrets: @MainActor () -> Void = {}
    /// Leaves the screen.
    public var onClose: @MainActor () -> Void = {}
    /// "Lock and unlock now" (VAULT-MESSAGING §11.14.9): shown when ``offersLockAndUnlock``.
    public var onLockAndUnlock: @MainActor () -> Void = {}
    /// Whether the PIN is uncertain or a new phone secret undecided, which a lock and unlock settles.
    public var offersLockAndUnlock = false

    public init() {}
}

/// Settings → Vault → Change vault PIN (VAULT-MESSAGING §10.6; release R §11.14.9): the current PIN, the new one and the
/// new one again, each on the in-app keypad, one after the other (vettid-android shows three fields on one screen;
/// the iPhone's keypad takes one PIN at a time: chosen; not in the spec), the credential password with the last. From a
/// notice about recovery attempts it warns first that the password should change too. Mirrors vettid-android
/// `ChangePinContent`.
public struct ChangePinContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.scenePhase) private var scenePhase
    let state: ChangePinState
    let actions: ChangePinActions
    @State private var pin = PinBuffer()

    public init(state: ChangePinState, actions: ChangePinActions = ChangePinActions()) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        if state.done {
            FormScaffold(
                title: PinStrings.pinDone, message: state.withPassword ? PinStrings.pinDoneRecovery : nil,
                primaryLabel: SettingsStrings.done, onPrimary: actions.onClose, header: { HeaderGlyph(symbol: .checkCircle) }
            ) {
                EmptyView()
            }
            .accessibilityIdentifier("change_pin_done")
        } else {
            form
        }
    }

    private var last: Bool { state.step == .confirm }

    private var canContinue: Bool {
        pin.count > 0 && !state.busy && (!last || !state.withPassword || !state.password.isEmpty)
    }

    private func next() {
        guard canContinue else { return }
        let typed = pin.take()
        switch state.step {
        case .current: actions.onCurrent(typed)
        case .new: actions.onPin(typed)
        case .confirm: actions.onConfirm(typed)
        }
        actions.onNext()
    }

    private var form: some View {
        FormScaffold(
            title: PinStrings.pinTitle, message: PinStrings.pinBody,
            primaryLabel: last ? PinStrings.pinSubmit : PinStrings.pinContinue, primaryEnabled: canContinue, busy: state.busy,
            onPrimary: next, onBack: state.step == .current ? actions.onClose : actions.onStepBack
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if state.fromAttempts && state.withPassword {
                    NoticeCard(.warning, title: PinStrings.pinTitle, message: PinStrings.pinPasswordToo)
                        .accessibilityIdentifier("pin_password_too")
                }
                PinEntry(label: label, buffer: pin, error: pin.count == 0 ? pinError : nil, identifier: "change_pin_\(stepTag)")
                    .disabled(state.busy)
                if last && state.withPassword {
                    // Release R (§11.14.9): the credential password goes with the change.
                    SecretField(
                        PinStrings.pinPassword, text: Binding(get: { state.password }, set: { actions.onPassword($0) }), onSubmit: next
                    )
                    .disabled(state.busy)
                    .accessibilityIdentifier("change_pin_password")
                }
                if let check = state.check, let text = Self.text(check) {
                    // VAULT-MESSAGING §11.14.9 "A lost answer": no failure while the change is decided.
                    NoticeCard(.info, title: PinStrings.pinTitle, message: text).accessibilityIdentifier("change_check")
                }
                if let error = state.error {
                    NoticeCard(.urgent, title: PinStrings.pinTitle, message: error.message(timeScale: timeScale))
                        .accessibilityIdentifier("error")
                }
                if actions.offersLockAndUnlock {
                    SecondaryButton(PinStrings.pinLockUnlock, action: actions.onLockAndUnlock)
                        .accessibilityIdentifier("change_pin_lock_unlock")
                }
            }
        }
        .accessibilityIdentifier("change_pin")
        .onChange(of: state.step) { _, _ in pin.clear() }
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
        case .checking: PinStrings.pinChecking
        case .unreachable: PinStrings.pinUnreachable
        case .notApplied: PinStrings.pinNotChanged
        case .ended: PinStrings.pinEnded
        default: nil
        }
    }

    private var label: String {
        switch state.step {
        case .current: PinStrings.pinCurrent
        case .new: PinStrings.pinNew
        case .confirm: PinStrings.pinConfirm
        }
    }

    private var stepTag: String {
        switch state.step {
        case .current: "current"
        case .new: "new"
        case .confirm: "confirm"
        }
    }

    /// The problem of the PIN just taken, until the member types again.
    private var pinError: String? {
        switch state.step {
        case .current: nil
        case .new: state.problem?.message ?? (state.same ? PinStrings.pinSame : nil)
        case .confirm: state.mismatch ? PinStrings.pinMismatch : nil
        }
    }

    private func forget() {
        pin.clear()
        actions.onForgetSecrets()
    }
}
#endif
