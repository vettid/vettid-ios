#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The update's own screens with their view model, shown by the root over every phase while an update runs or its outcome
/// is shown (``ReleaseUpdateRepository/progress``). Mirrors vettid-android `ReleaseUpdateFlowRoute`.
public struct ReleaseUpdateFlowRoute: View {
    private let updates: any ReleaseUpdateRepository
    @State private var model: ReleaseUpdateFlowViewModel?

    public init(updates: any ReleaseUpdateRepository) {
        self.updates = updates
    }

    public var body: some View {
        ReleaseUpdateFlowContent(state: model?.state ?? ReleaseUpdateFlowState(progress: updates.progress), actions: actions)
            .onAppear { if model == nil { model = ReleaseUpdateFlowViewModel(updates: updates) } }
    }

    private var actions: ReleaseUpdateFlowActions {
        var a = ReleaseUpdateFlowActions()
        let m = model
        a.retry = { pin in m?.retry(pin: pin) ?? false }
        a.typingStarts = { m?.pinTypingStarted() }
        a.askAbandon = { m?.askAbandon() }
        a.dismissAbandon = { m?.dismissAbandon() }
        a.confirmAbandon = { pin in m?.confirmAbandon(pin: pin) ?? false }
        a.finish = { m?.finish() }
        return a
    }
}

/// What the update's screens can ask for. The PIN is the keypad's, handed over once.
public struct ReleaseUpdateFlowActions {
    public var retry: @MainActor (_ pin: String) -> Bool = { _ in false }
    /// The first digit was typed into the empty keypad (``ReleaseUpdateFlowViewModel/pinTypingStarted()``).
    public var typingStarts: @MainActor () -> Void = {}
    public var askAbandon: @MainActor () -> Void = {}
    public var dismissAbandon: @MainActor () -> Void = {}
    public var confirmAbandon: @MainActor (_ pin: String) -> Bool = { _ in false }
    public var finish: @MainActor () -> Void = {}

    public init() {}
}

/// The update's screens for [state] (stateless): progress, the outcome, a PIN to try again, the way back. Mirrors
/// vettid-android `ReleaseUpdateFlowContent`.
public struct ReleaseUpdateFlowContent: View {
    @Environment(\.scenePhase) private var scenePhase
    let state: ReleaseUpdateFlowState
    let actions: ReleaseUpdateFlowActions
    @State private var pin = PinBuffer()

    public init(state: ReleaseUpdateFlowState, actions: ReleaseUpdateFlowActions = ReleaseUpdateFlowActions()) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        Group {
            if let p = state.progress {
                screen(p)
            }
        }
        .confirmDialog(
            isPresented: Binding(get: { state.abandonConfirm }, set: { if !$0 { actions.dismissAbandon() } }),
            title: OnboardingStrings.releaseUpdateReturnConfirmTitle(from),
            message: OnboardingStrings.releaseUpdateReturnConfirmBody(from, to),
            confirmLabel: OnboardingStrings.releaseUpdateReturn(from)
        ) {
            if !actions.confirmAbandon(pin.take()) { pin.clear() }
        }
        .onDisappear { pin.clear() }
        .onChange(of: pin.count) { before, now in
            // VAULT-MESSAGING §11.14.9 step 2: which PIN the vault expects is read as the PIN starts being typed.
            if before == 0, now > 0 { actions.typingStarts() }
        }
        .onChange(of: state.pinAllowed) { _, allowed in
            // Digits typed before a step ran or a backoff began are not kept for after it (a fresh reading then).
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

    private var from: Int { Int(state.progress?.from.number ?? 0) }
    private var to: Int { Int(state.progress?.to.number ?? 0) }

    @ViewBuilder private func screen(_ p: UpdateProgress) -> some View {
        switch p.step {
        case .locking, .approving, .reopening, .abandoning:
            UpdateProgressScreen(progress: p)
        case .done:
            outcome(
                OnboardingStrings.releaseUpdateDoneTitle, OnboardingStrings.releaseUpdateDoneBody(to, p.to.fingerprint),
                "release_update_done"
            )
        case .refused:
            UpdateRefusedScreen(progress: p, onContinue: actions.finish)
        case .abandoned:
            outcome(
                OnboardingStrings.releaseUpdateAbandonedTitle(from), OnboardingStrings.releaseUpdateAbandonedBody(from, to),
                "release_update_abandoned"
            )
        case .badPin, .failed:
            UpdateRetryScreen(progress: p, state: state, pin: pin, retry: retry, onSecondary: actions.finish)
        case .newReleaseFailed:
            UpdateNewReleaseFailedScreen(
                progress: p, state: state, pin: pin, retry: retry, askAbandon: actions.askAbandon, onBack: actions.finish
            )
        }
    }

    private func retry() {
        guard state.retryAllowed(pinTyped: pin.count) else { return }
        if !actions.retry(pin.take()) { pin.clear() }
    }

    private func outcome(_ title: String, _ message: String, _ identifier: String) -> some View {
        FormScaffold(
            title: title, message: message, primaryLabel: OnboardingStrings.releaseUpdateContinue, onPrimary: actions.finish,
            header: { UpdateGlyph() }
        ) {
            EmptyView()
        }
        .accessibilityIdentifier(identifier)
    }
}

/// The steps while the update runs: lock, move, open on the new release (or the return).
private struct UpdateProgressScreen: View {
    @Environment(\.vettIDColors) private var colors
    let progress: UpdateProgress

    var body: some View {
        let p = progress
        let from = Int(p.from.number)
        let to = Int(p.to.number)
        let returning = p.step == .abandoning
        FormScaffold(
            title: returning ? OnboardingStrings.releaseUpdateReturningTitle(from) : OnboardingStrings.releaseUpdateRunningTitle(to),
            primaryLabel: nil, onPrimary: {}, header: { UpdateGlyph() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if returning {
                    CheckingLine(label: OnboardingStrings.releaseUpdateStepReturn(from))
                } else {
                    StepList(steps)
                }
                if p.starting {
                    Text(OnboardingStrings.releaseUpdateStarting(p.step == .approving ? from : to))
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("release_update_starting")
                }
                Text(OnboardingStrings.releaseUpdateKeepOpen).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        .accessibilityIdentifier("release_update_progress")
    }

    private var steps: [(String, StepState)] {
        let order: [UpdateStep] = [.locking, .approving, .reopening]
        let at = order.firstIndex(of: progress.step) ?? 0
        let labels = [
            OnboardingStrings.releaseUpdateStepLock,
            OnboardingStrings.releaseUpdateStepApprove(Int(progress.from.number), Int(progress.to.number)),
            OnboardingStrings.releaseUpdateStepOpen(Int(progress.to.number)),
        ]
        return labels.enumerated().map { i, l in (l, i < at ? .done : i == at ? .active : .pending) }
    }
}

/// The vault refused the update; it stayed on its release and is open.
private struct UpdateRefusedScreen: View {
    let progress: UpdateProgress
    let onContinue: @MainActor () -> Void

    var body: some View {
        FormScaffold(
            title: OnboardingStrings.releaseUpdateRefusedTitle,
            message: OnboardingStrings.releaseUpdateRefusedBody(Int(progress.from.number)),
            primaryLabel: OnboardingStrings.releaseUpdateContinue, onPrimary: onContinue, header: { UpdateGlyph() }
        ) {
            NoticeCard(
                .warning, title: OnboardingStrings.releaseUpdateRefusedWhy,
                message: refusalText(progress.refusal ?? "", Int(progress.to.number))
            )
        }
        .accessibilityIdentifier("release_update_refused")
    }
}

/// The refusal codes of §11.10.4 step 4, and a step 6 write failure, in the member's words.
func refusalText(_ code: String, _ to: Int) -> String {
    switch code {
    case "target": OnboardingStrings.releaseUpdateRefusedTarget(to)
    case "downgrade": OnboardingStrings.releaseUpdateRefusedDowngrade(to)
    case "approval": OnboardingStrings.releaseUpdateRefusedApproval
    case "seal_key": OnboardingStrings.releaseUpdateRefusedSealKey(to)
    case "pending": OnboardingStrings.releaseUpdateRefusedPending
    case "write": OnboardingStrings.releaseUpdateRefusedWrite
    default: OnboardingStrings.releaseUpdateRefusedOther(code)
    }
}

/// What a failed step says, at the vault's [timeScale].
func updateFailureText(_ p: UpdateProgress, timeScale: UInt64) -> String {
    if p.failureCode == ReleaseUpdateManager.codeChangeHeld { return (p.failure ?? .changeUnresolved).message(timeScale: timeScale) }
    if p.failure == .badPin { return OnboardingStrings.unlockBadPin }
    if p.failure == .backoff { return OnboardingStrings.releaseUpdateBackoff }
    if p.failureCode == ReleaseUpdateManager.codeReleaseStarting { return OnboardingStrings.releaseUpdateStartFailed }
    return (p.failure ?? .other).message(timeScale: timeScale)
}

/// The PIN to try again, with the backoff's countdown.
private struct UpdatePin: View {
    let progress: UpdateProgress
    let state: ReleaseUpdateFlowState
    let pin: PinBuffer

    var body: some View {
        PinEntry(
            label: OnboardingStrings.unlockPinLabel, buffer: pin,
            error: progress.failure == .badPin && pin.count == 0 ? OnboardingStrings.unlockBadPin : nil,
            identifier: "release_update_pin"
        )
        .disabled(!state.pinAllowed)
        if state.waitSeconds > 0 {
            Text(OnboardingStrings.unlockWait(formatWait(state.waitSeconds)))
                .vettIDFont(.bodySmall)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("release_update_wait")
        }
    }
}

/// A wrong PIN, or a failure before anything moved: the approval again with the PIN, or leave.
private struct UpdateRetryScreen: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let progress: UpdateProgress
    let state: ReleaseUpdateFlowState
    let pin: PinBuffer
    let retry: @MainActor () -> Void
    let onSecondary: @MainActor () -> Void

    var body: some View {
        let p = progress
        let badPin = p.step == .badPin
        let from = Int(p.from.number)
        let body: String = if p.failureCode == VaultManager.codeUpdateLockPending {
            // The update's own lock is not confirmed: the vault is neither known open nor known locked.
            OnboardingStrings.releaseUpdateFailedBodyLockPending(from)
        } else if p.vaultOpen {
            OnboardingStrings.releaseUpdateFailedBodyOpen(from)
        } else {
            OnboardingStrings.releaseUpdateFailedBodyLocked(from)
        }
        FormScaffold(
            title: badPin ? OnboardingStrings.releaseUpdateTitle : OnboardingStrings.releaseUpdateFailedTitle,
            message: body,
            primaryLabel: badPin ? OnboardingStrings.releaseUpdateApprove : OnboardingStrings.releaseUpdateRetry,
            primaryEnabled: state.retryAllowed(pinTyped: pin.count),
            secondaryLabel: p.vaultOpen ? OnboardingStrings.releaseUpdateNotNow : OnboardingStrings.releaseUpdateUnlockOnly,
            onPrimary: retry, onSecondary: onSecondary, header: { UpdateGlyph() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                // (§11.14.9) Also on the PIN step: a change being decided holds the update ("still checking").
                if p.step == .failed || p.failureCode == ReleaseUpdateManager.codeChangeHeld {
                    NoticeCard(
                        .warning, title: OnboardingStrings.releaseUpdateFailedTitle, message: updateFailureText(p, timeScale: timeScale)
                    )
                }
                UpdatePin(progress: p, state: state, pin: pin)
            }
        }
        .accessibilityIdentifier(badPin ? "release_update_bad_pin" : "release_update_failed")
    }
}

/// Moved, but the new release did not open the vault: try again, or return while the move is unconfirmed.
private struct UpdateNewReleaseFailedScreen: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let progress: UpdateProgress
    let state: ReleaseUpdateFlowState
    let pin: PinBuffer
    let retry: @MainActor () -> Void
    let askAbandon: @MainActor () -> Void
    let onBack: @MainActor () -> Void

    var body: some View {
        let p = progress
        let from = Int(p.from.number)
        let to = Int(p.to.number)
        FormScaffold(
            title: OnboardingStrings.releaseUpdateNewFailedTitle(to),
            message: p.canAbandon
                ? OnboardingStrings.releaseUpdateNewFailedBody(to, from) : OnboardingStrings.releaseUpdateNewFailedBodyNoReturn(to),
            primaryLabel: OnboardingStrings.releaseUpdateRetry,
            primaryEnabled: state.retryAllowed(pinTyped: pin.count),
            secondaryLabel: p.canAbandon ? OnboardingStrings.releaseUpdateReturn(from) : nil,
            onPrimary: retry, onSecondary: askAbandon, onBack: onBack, header: { UpdateGlyph() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                NoticeCard(.urgent, title: OnboardingStrings.releaseUpdateNewFailedWhy, message: updateFailureText(p, timeScale: timeScale))
                UpdatePin(progress: p, state: state, pin: pin)
            }
        }
        .accessibilityIdentifier("release_update_new_failed")
    }
}
#endif
