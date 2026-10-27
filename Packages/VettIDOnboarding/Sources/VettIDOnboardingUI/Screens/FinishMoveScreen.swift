#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// What "Finish the move" can ask for. The PIN is the keypad's, handed over once.
public struct FinishMoveActions {
    /// "Finish the move" with the PIN from the keypad; false when it was not allowed (held, running, done, too short).
    public var finish: @MainActor (_ pin: String) -> Bool = { _ in false }
    /// The first digit was typed into the empty keypad (``FinishMoveViewModel/pinTypingStarted()``).
    public var typingStarts: @MainActor () -> Void = {}

    public init() {}
}

/// "Finish the move" on the new phone (VAULT-MESSAGING 0.33.0 §11.14.10 step 4), for [state] (stateless): the PIN on the
/// in-app keypad (IOS-PLAN §6.5), the hold and the failure, "Later" and the result. [onDone] leaves the pane ("Later", and
/// "Continue" after the move finished). Digits typed before a hold go with it, and the keypad is also emptied when the app
/// leaves the foreground. Mirrors vettid-android `FinishMovePane`.
public struct FinishMoveContent: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.scenePhase) private var scenePhase
    let state: FinishMoveState
    let actions: FinishMoveActions
    let onDone: @MainActor () -> Void
    @State private var pin: PinBuffer

    /// [pin]: the keypad's buffer (a test passes its own).
    public init(
        state: FinishMoveState, actions: FinishMoveActions = FinishMoveActions(), pin: PinBuffer = PinBuffer(),
        onDone: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.actions = actions
        self.onDone = onDone
        _pin = State(initialValue: pin)
    }

    private var canFinish: Bool { pin.count >= FinishMoveViewModel.minPin && state.pinAllowed }

    private func finish() {
        guard canFinish else { return }
        _ = actions.finish(pin.take())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(OnboardingStrings.finishMoveTitle).vettIDFont(.titleLarge).accessibilityAddTraits(.isHeader)
            if state.done {
                Text(MoveStrings.onboardingFinishMoveDone).vettIDFont(.bodyLarge)
                PrimaryButton(OnboardingStrings.continueLabel, action: onDone).accessibilityIdentifier("finish_move_continue")
            } else {
                form
            }
        }
        .padding(Spacing.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finish_move")
        .onDisappear { pin.clear() }
        .onChange(of: pin.count) { before, now in
            // VAULT-MESSAGING §11.14.9 step 2: which PIN the vault expects is read as the PIN starts being typed.
            if before == 0, now > 0 { actions.typingStarts() }
        }
        .onChange(of: state.pinAllowed) { _, allowed in
            // Digits typed before a hold (or while it runs) were typed before its decision: they go with it. Handed over
            // (running) or done, the keypad is empty as well.
            if !allowed { pin.clear() }
        }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
            if now == .background { pin.clear() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            pin.clear()
        }
    }

    @ViewBuilder private var form: some View {
        Text(MoveStrings.onboardingFinishMoveBody).vettIDFont(.bodyLarge)
        PinEntry(label: OnboardingStrings.pinLabel, buffer: pin, identifier: "finish_move_pin")
            .disabled(!state.pinAllowed)
        if let held = state.held {
            NoticeCard(.warning, title: OnboardingStrings.finishMoveTitle, message: held.message(timeScale: timeScale))
                .accessibilityIdentifier("finish_move_held")
        }
        if let failure = state.failure {
            NoticeCard(.warning, title: OnboardingStrings.finishMoveTitle, message: failure.message(timeScale: timeScale))
                .accessibilityIdentifier("finish_move_failure")
        }
        HStack(spacing: Spacing.m) {
            Button(action: onDone) {
                Text(MoveStrings.onboardingFinishMoveLater)
                    .vettIDFont(.labelLarge)
                    .foregroundStyle(colors.primary)
                    .frame(minHeight: Spacing.touchTarget)
            }
            .buttonStyle(.plain)
            .disabled(state.busy)
            .accessibilityIdentifier("finish_move_later")
            PrimaryButton(OnboardingStrings.finishMoveTitle, busy: state.busy, action: finish)
                .disabled(!canFinish)
                .accessibilityIdentifier("finish_move_go")
        }
    }
}

/// "Finish the move" with its view model, made when it first appears. [onDone]: "Later", and "Continue" after the move
/// finished. Nothing leaves the move while its lock and unlock run (the sheet that holds it is not dismissable meanwhile,
/// see ``FinishMoveSheet``). Mirrors vettid-android's `FinishMoveViewModel` use in `FinishMovePane`.
public struct FinishMoveRoute: View {
    private let vault: any VaultRepository
    private let onDone: @MainActor () -> Void
    @State private var model: FinishMoveViewModel?

    public init(vault: any VaultRepository, onDone: @escaping @MainActor () -> Void) {
        self.vault = vault
        self.onDone = onDone
    }

    public var body: some View {
        FinishMoveContent(state: model?.state ?? FinishMoveState(), actions: actions, onDone: onDone)
            .onAppear { if model == nil { model = FinishMoveViewModel(vault: vault) } }
    }

    private var actions: FinishMoveActions {
        var a = FinishMoveActions()
        let m = model
        a.finish = { pin in m?.finish(pin: pin) ?? false }
        a.typingStarts = { m?.pinTypingStarted() }
        return a
    }
}
#endif
