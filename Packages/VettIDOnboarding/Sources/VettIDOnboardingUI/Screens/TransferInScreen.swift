#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The direct transfer on this (new) phone (VAULT-MESSAGING §6.7.1), one step for [state] (stateless): the choice between
/// scanning and pasting the old phone's code, the camera, the pasted code, the wait for the vault, the safety code to
/// compare, and the outcomes. [camera] replaces the camera preview (previews, the screen catalog). [finishPane]: "Finish the
/// move" after the approval of a transfer that gave this phone its own secret (release R, VAULT-MESSAGING §11.14.10);
/// without it (or without a phone secret) the move's own last screen. [onLeave] returns to the onboarding choice. Mirrors
/// vettid-android `TransferInContent`.
public struct TransferInContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: TransferInState
    let actions: any TransferInActions
    let onLeave: @MainActor () -> Void
    let camera: AnyView?
    let finishPane: AnyView?

    public init(
        state: TransferInState,
        actions: any TransferInActions = NoTransferInActions(),
        onLeave: @escaping @MainActor () -> Void = {},
        camera: AnyView? = nil,
        finishPane: AnyView? = nil
    ) {
        self.state = state
        self.actions = actions
        self.onLeave = onLeave
        self.camera = camera
        self.finishPane = finishPane
    }

    private var back: @MainActor () -> Void {
        let actions = actions
        let onLeave = onLeave
        return { if !actions.back() { onLeave() } }
    }

    public var body: some View {
        Group { screen }.announcesStepChanges(of: state.step)
    }

    @ViewBuilder private var screen: some View {
        switch state.step {
        case .intro: intro
        case .scan: scan
        case .paste: paste
        case .connecting:
            FormScaffold(
                title: MoveStrings.transferInTitle, primaryLabel: nil, secondaryLabel: MoveStrings.transferInCancel,
                onPrimary: {}, onSecondary: actions.cancel
            ) {
                WaitingRow(text: MoveStrings.transferInConnecting, identifier: "connecting")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transfer_in_connecting")
        case .compare: compare
        case .done:
            if state.phoneSecret, let finishPane {
                finishPane
            } else {
                MovedScreen(
                    body: state.canUnlockLater
                        ? MoveStrings.onboardingMovedTransferredBody : MoveStrings.onboardingMovedTransferredNoGuidBody,
                    onGo: actions.finish
                )
            }
        case .rejected:
            Outcome(
                title: MoveStrings.transferInRejectedTitle, body: MoveStrings.transferInRejectedBody,
                primary: MoveStrings.transferInAgain, onPrimary: actions.again, onBack: onLeave
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transfer_rejected")
        case .timedOut:
            Outcome(
                title: MoveStrings.transferInTimeoutTitle, body: MoveStrings.transferInTimeoutBody,
                primary: MoveStrings.transferInAgain, onPrimary: actions.again, onBack: onLeave
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transfer_timed_out")
        case .notAnswered:
            Outcome(
                title: MoveStrings.transferInNoAnswerTitle, body: MoveStrings.transferInNoAnswer,
                primary: MoveStrings.transferInScanNew, onPrimary: actions.again, onBack: onLeave
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transfer_not_answered")
        }
    }

    private var intro: some View {
        FormScaffold(
            title: MoveStrings.transferInTitle, message: MoveStrings.transferInBody, primaryLabel: MoveStrings.transferInScan,
            secondaryLabel: MoveStrings.transferInPaste, onPrimary: actions.scan, onSecondary: actions.paste, onBack: back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                NoticeCard(.info, title: MoveStrings.recoverNeedTitle, message: MoveStrings.transferInNeedBody)
                MoveFailure(kind: state.error, timeScale: timeScale)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_in")
    }

    private var scan: some View {
        FormScaffold(
            title: MoveStrings.transferInScanTitle, message: MoveStrings.transferInScanBody, primaryLabel: nil,
            secondaryLabel: MoveStrings.transferInPaste, onPrimary: {}, onSecondary: actions.paste, onBack: back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ScannerBox(onText: actions.scanned, onTypeInstead: actions.paste, camera: camera, typeLabel: MoveStrings.transferInPaste)
                InputProblem(kind: state.inputProblem)
                MoveFailure(kind: state.error, timeScale: timeScale)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_in_scan")
    }

    private var paste: some View {
        FormScaffold(
            title: MoveStrings.transferInPasteTitle, message: MoveStrings.transferInPasteBody,
            primaryLabel: MoveStrings.transferInPasteSubmit,
            primaryEnabled: !state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, busy: state.busy,
            onPrimary: actions.submitInput, onBack: back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                // The code is typed or pasted in a field without AutoFill, suggestions or keyboard learning (IOS-PLAN §6.5), and
                // out of captures (§6.4; chosen; not in the spec).
                CaptureProtected {
                    SecretTextEditor(
                        MoveStrings.transferInPasteLabel, text: Binding(get: { state.input }, set: { actions.setInput($0) }),
                        placeholder: MoveStrings.transferInPasteLabel, isError: state.inputProblem != nil
                    )
                }
                .accessibilityIdentifier("transfer_code")
                InputProblem(kind: state.inputProblem)
                MoveFailure(kind: state.error, timeScale: timeScale)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_in_paste")
    }

    private var compare: some View {
        FormScaffold(
            title: MoveStrings.transferInCompareTitle, message: MoveStrings.transferInCompareBody, primaryLabel: nil,
            secondaryLabel: MoveStrings.transferInCancel, onPrimary: {}, onSecondary: actions.cancel
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if let sas = state.sas { SasBox(sas: sas) }
                WaitingRow(text: MoveStrings.transferInWaiting(formatWait(state.secondsLeft)), identifier: "waiting_old_phone")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_in_compare")
    }
}

/// A failure as a notice: the vault's own text, or "Your vault did not answer…" when it did not answer.
private struct MoveFailure: View {
    let kind: FailureKind?
    let timeScale: UInt64

    var body: some View {
        if let kind {
            NoticeCard(
                .urgent, title: MoveStrings.recoverFailedTitle,
                message: kind == .noResponse ? MoveStrings.transferInNoAnswer : kind.message(timeScale: timeScale), announce: .assertive
            )
            .accessibilityIdentifier("error")
        }
    }
}

/// Why the scanned or pasted text is not used.
private struct InputProblem: View {
    let kind: FailureKind?

    var body: some View {
        if let kind {
            NoticeCard(
                .warning, title: MoveStrings.recoverFailedTitle,
                message: kind == .inviteExpired ? MoveStrings.transferInExpiredCode : MoveStrings.transferInNotTransfer,
                announce: .assertive
            )
            .accessibilityIdentifier("code_refused")
        }
    }
}

/// An outcome with "Try again" and "Back".
private struct Outcome: View {
    let title: String
    let message: String
    let primary: String
    let onPrimary: @MainActor () -> Void
    let onBack: @MainActor () -> Void

    init(
        title: String, body: String, primary: String, onPrimary: @escaping @MainActor () -> Void,
        onBack: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.message = body
        self.primary = primary
        self.onPrimary = onPrimary
        self.onBack = onBack
    }

    var body: some View {
        FormScaffold(
            title: title, message: message, primaryLabel: primary, secondaryLabel: MoveStrings.moveBack, onPrimary: onPrimary,
            onSecondary: onBack
        ) { EmptyView() }
    }
}

/// "Your vault is connected to this phone now", after a recovery or a transfer: the vault itself never is on a phone.
/// Mirrors vettid-android `MovedScreen`.
public struct MovedScreen: View {
    let message: String
    let onGo: @MainActor () -> Void

    public init(body: String, onGo: @escaping @MainActor () -> Void) {
        self.message = body
        self.onGo = onGo
    }

    public var body: some View {
        FormScaffold(
            title: MoveStrings.onboardingMovedTitle, message: message, primaryLabel: MoveStrings.onboardingMovedGo, onPrimary: onGo,
            header: {
                VStack(spacing: Spacing.l) {
                    Spacer().frame(height: Spacing.xl)
                    RookLogo(height: 72)
                }
            }
        ) { EmptyView() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moved")
    }
}

/// The transfer on this phone with its view model, made when it first appears. [vault]: also the repository "Finish the move"
/// reads. The model is owned here; a transfer under way is cancelled (nothing was approved, so nothing changes) and the
/// pasted code forgotten when the screen goes, whatever took it away; after the approval the screen goes on to the move's
/// last screen (``OnboardingRoutes/movedIn``) and the model is left as it is. Mirrors vettid-android `TransferInFlow`.
public struct TransferInRoute: View {
    private let move: any MoveRepository
    private let vault: any VaultRepository
    private let onLeave: @MainActor () -> Void
    private let camera: AnyView?
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TransferInViewModel?

    public init(
        move: any MoveRepository, vault: any VaultRepository, onLeave: @escaping @MainActor () -> Void, camera: AnyView? = nil
    ) {
        self.init(move: move, vault: vault, onLeave: onLeave, camera: camera, model: nil)
    }

    /// TEST ONLY: [model] is the route's own from the start (a transfer already under way).
    init(
        move: any MoveRepository, vault: any VaultRepository, onLeave: @escaping @MainActor () -> Void, camera: AnyView?,
        model: TransferInViewModel?
    ) {
        self.move = move
        self.vault = vault
        self.onLeave = onLeave
        self.camera = camera
        _model = State(initialValue: model)
    }

    public var body: some View {
        TransferInContent(
            state: model?.state ?? TransferInState(), actions: model ?? NoTransferInActions(), onLeave: onLeave, camera: camera,
            finishPane: AnyView(FinishMoveRoute(vault: vault) { model?.finish() })
        )
        .onAppear { if model == nil { model = TransferInViewModel(move: move, vault: vault) } }
        .onDisappear { Self.leave(model, move: move, movedIn: vault.movedIn) }
        // The pasted code is also forgotten when the app leaves the foreground and when the iPhone locks (IOS-PLAN §6.3;
        // chosen; vettid-android has no such rule).
        .onChange(of: scenePhase) { _, now in if now == .background { model?.setInput("") } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            model?.setInput("")
        }
    }

    /// The screen goes: a transfer under way is cancelled, and the pasted code is forgotten. Not when the transfer completed
    /// ([movedIn]): the approval can replace this screen with the move's last screen before the model shows it, and then
    /// nothing is dropped.
    static func leave(_ model: TransferInViewModel?, move: any MoveRepository, movedIn: Bool) {
        guard let model else { return }
        model.setInput("")
        guard cancels(model.state.step), !movedIn else { return }
        model.cancel()
        // The model is freed with the screen and takes its own work with it: the handshake is dropped from a task of its own
        // (best effort, as ``TransferOutViewModel/leave()`` rejects its code).
        Task { @MainActor in try? await move.abandonTransferIn() }
    }

    /// The steps in which leaving cancels the transfer (the handshake is under way); after the approval nothing is cancelled.
    static func cancels(_ step: TransferInStep) -> Bool { step == .connecting || step == .compare }
}
#endif
