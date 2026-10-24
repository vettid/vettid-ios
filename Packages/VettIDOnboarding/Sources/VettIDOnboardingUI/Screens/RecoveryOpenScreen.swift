#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// What the recovery open can ask for: ``RecoveryOpenViewModel``'s actions as closures (previews, the screen catalog and the
/// tests pass their own). The PIN is the keypad's, handed over once, by [setPin].
public struct RecoveryOpenActions {
    public var setPin: @MainActor (_ pin: String) -> Void = { _ in }
    public var setPassword: @MainActor (_ password: String) -> Void = { _ in }
    public var review: @MainActor () -> Void = {}
    public var change: @MainActor () -> Void = {}
    public var send: @MainActor () -> Void = {}
    public var again: @MainActor () -> Void = {}
    public var finishLostOk: @MainActor () -> Void = {}
    public var askErase: @MainActor () -> Void = {}
    public var dismissErase: @MainActor () -> Void = {}
    public var erase: @MainActor () -> Void = {}
    public var openApp: @MainActor () -> Void = {}
    public var forgetSecrets: @MainActor () -> Void = {}

    public init() {}

    /// The actions of [model].
    @MainActor public init(_ model: RecoveryOpenViewModel) {
        setPin = { model.setPin($0) }
        setPassword = { model.setPassword($0) }
        review = { model.review() }
        change = { model.change() }
        send = { model.send() }
        again = { model.again() }
        finishLostOk = { model.finishLostOk() }
        askErase = { model.askErase() }
        dismissErase = { model.dismissErase() }
        erase = { model.erase() }
        openApp = { model.openApp() }
        forgetSecrets = { model.forgetSecrets() }
    }
}

/// What the recovery flow says on the open step besides the fields: the guidance of a refused start over, or its failure.
enum OpenSideNotice: Equatable {
    case guidance(RecoverGuidance)
    case failure(FailureKind)
}

/// The recovery's PIN and password (ANDROID-PLAN 0.1.40 "Recovery on the new phone"), one step for [state] (stateless): both
/// fields on one screen, the check before sending, the answer with a countdown to the next possible attempt, the PIN alone to
/// finish an `ok` whose handover did not complete, and the `ok` text. The PIN is typed on the in-app keypad (IOS-PLAN §6.5),
/// the password in a secret field (no AutoFill); both are dropped when the app leaves the foreground and when the iPhone
/// locks, and the screen is out of captures (§6.4). [onStartOver]: "Start over" (after a confirmation; never after `ok`).
/// [onOpened]: the vault opened on this phone after `ok`, the end of setup. Mirrors vettid-android `RecoveryOpenPane`.
public struct RecoveryOpenContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.scenePhase) private var scenePhase
    let state: RecoveryOpenState
    let actions: RecoveryOpenActions
    let problem: OpenSideNotice?
    let onStartOver: (@MainActor () -> Void)?
    let onOpened: @MainActor () -> Void
    @State private var pin: PinBuffer

    /// [pin]: the keypad's buffer (a test passes its own).
    init(
        state: RecoveryOpenState,
        actions: RecoveryOpenActions = RecoveryOpenActions(),
        problem: OpenSideNotice? = nil,
        onStartOver: (@MainActor () -> Void)? = nil,
        onOpened: @escaping @MainActor () -> Void = {},
        pin: PinBuffer = PinBuffer()
    ) {
        self.state = state
        self.actions = actions
        self.problem = problem
        self.onStartOver = onStartOver
        self.onOpened = onOpened
        _pin = State(initialValue: pin)
    }

    public init(
        state: RecoveryOpenState,
        actions: RecoveryOpenActions = RecoveryOpenActions(),
        onStartOver: (@MainActor () -> Void)? = nil,
        onOpened: @escaping @MainActor () -> Void = {}
    ) {
        self.init(state: state, actions: actions, problem: nil, onStartOver: onStartOver, onOpened: onOpened, pin: PinBuffer())
    }

    private var pinReady: Bool { pin.count >= RecoveryOpenState.minPin }

    public var body: some View {
        screen
            .confirmDialog(
                isPresented: Binding(get: { state.confirmErase && state.canErase }, set: { if !$0 { actions.dismissErase() } }),
                title: OnboardingStrings.unlockEraseConfirmTitle, message: RecoveryScreenStrings.onboardingOpenFinishEraseBody,
                confirmLabel: OnboardingStrings.unlockEraseConfirm, destructive: true, onConfirm: { actions.erase() }
            )
            .onChange(of: state.opened, initial: true) { _, opened in if opened { onOpened() } }
            .onChange(of: state.step) { _, now in
                // The keypad holds nothing once the PIN was handed over or the fields are left.
                if now == .sending || now == .done { pin.clear() }
            }
            .onDisappear { pin.clear() }
            .onChange(of: scenePhase) { _, now in if now == .background { forgetSecrets() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                forgetSecrets()
            }
            .accessibilityIdentifier("recovery_open")
    }

    /// IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
    private func forgetSecrets() {
        pin.clear()
        actions.forgetSecrets()
    }

    /// The screen is out of captures whatever the app-wide setting says (as vettid-android's `SecureWindow`).
    @ViewBuilder private var screen: some View {
        SecureContainer(isSecure: true) {
            switch state.step {
            case .enter: OpenEntry(state: state, actions: actions, problem: problem, onStartOver: onStartOver, pin: pin)
            case .check: OpenCheck(state: state, actions: actions, timeScale: timeScale)
            case .sending: OpenSending()
            case .answered:
                OpenAnswer(state: state, actions: actions, onStartOver: onStartOver, timeScale: timeScale)
            case .finish: OpenFinish(state: state, actions: actions, timeScale: timeScale, pin: pin)
            case .done: OpenDone(state: state, actions: actions, timeScale: timeScale)
            }
        }
    }
}

/// Both fields on one screen. The keypad is filled again from what the model holds when the member comes back from the check
/// or from an answer: the entries are kept ("Change", "Try again").
private struct OpenEntry: View {
    let state: RecoveryOpenState
    let actions: RecoveryOpenActions
    let problem: OpenSideNotice?
    let onStartOver: (@MainActor () -> Void)?
    let pin: PinBuffer

    private var canContinue: Bool { pin.count >= RecoveryOpenState.minPin && !state.password.isEmpty }

    private func review() {
        guard canContinue else { return }
        actions.setPin(pin.take())
        actions.review()
    }

    private func refill() {
        guard pin.count == 0 else { return }
        for character in state.pin { if let digit = character.wholeNumberValue { pin.append(digit) } }
    }

    var body: some View {
        FormScaffold(
            title: RecoveryScreenStrings.onboardingOpenTitle, primaryLabel: RecoveryScreenStrings.onboardingOpenContinue,
            primaryEnabled: canContinue, secondaryLabel: onStartOver == nil ? nil : RecoveryScreenStrings.recoverStartOver,
            onPrimary: review, onSecondary: { onStartOver?() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                OpenSideNoticeView(problem: problem, onFinishWithPin: { actions.finishLostOk() })
                PinEntry(label: RecoveryScreenStrings.onboardingOpenPin, buffer: pin, identifier: "open_pin")
                SecretField(
                    RecoveryScreenStrings.onboardingOpenPassword,
                    text: Binding(get: { state.password }, set: { actions.setPassword($0) }), onSubmit: review
                )
                .accessibilityIdentifier("open_password")
                Text(RecoveryScreenStrings.onboardingOpenTen).vettIDFont(.bodyMedium)
            }
        }
        .onAppear { refill() }
        .accessibilityIdentifier("open_enter")
    }
}

/// What the flow says on the open step besides the fields: the guidance of a refused start over (with the lost-ok finish where
/// it applies), or the failure.
private struct OpenSideNoticeView: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let problem: OpenSideNotice?
    let onFinishWithPin: @MainActor () -> Void

    var body: some View {
        if case .guidance(let g) = problem {
            GuidanceNotice(guidance: g, onFinishWithPin: g == .finishWithPin || g == .tryOpenAgain ? onFinishWithPin : nil)
        } else if case .failure(let kind) = problem {
            NoticeCard(.urgent, title: MoveStrings.recoverFailedTitle, message: kind.message(timeScale: timeScale))
                .accessibilityIdentifier("error")
        }
    }
}

/// "This is what will be sent": a step that cannot be skipped. The PIN and the password are shown here, out of captures,
/// because the keypad shows only dots.
private struct OpenCheck: View {
    let state: RecoveryOpenState
    let actions: RecoveryOpenActions
    let timeScale: UInt64

    var body: some View {
        FormScaffold(
            title: RecoveryScreenStrings.onboardingOpenTitle, primaryLabel: RecoveryScreenStrings.onboardingOpenSend,
            secondaryLabel: RecoveryScreenStrings.onboardingOpenChange, onPrimary: actions.send, onSecondary: actions.change
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let w = state.warning {
                    NoticeCard(
                        .warning, title: RecoveryScreenStrings.onboardingOpenWarningTitle,
                        message: RecoveryTexts.openWarning(w, used: state.used, timeScale: timeScale)
                    )
                    .accessibilityIdentifier("open_warning")
                }
                CaptureProtected {
                    Text(RecoveryScreenStrings.onboardingOpenCheck(state.pin, state.password))
                        .vettIDFont(.bodyLarge)
                        .accessibilityIdentifier("open_check")
                }
            }
        }
        .accessibilityIdentifier("open_check_step")
    }
}

private struct OpenSending: View {
    var body: some View {
        FormScaffold(title: RecoveryScreenStrings.recoverTitle, primaryLabel: nil, onPrimary: {}) {
            WaitingRow(text: RecoveryScreenStrings.iosRecoverOpenSending, identifier: "open_sending")
        }
    }
}

/// The vault's answer, with a countdown to the next possible attempt during a wait.
private struct OpenAnswer: View {
    let state: RecoveryOpenState
    let actions: RecoveryOpenActions
    let onStartOver: (@MainActor () -> Void)?
    let timeScale: UInt64

    var body: some View {
        if let o = state.outcome {
            TimelineView(.periodic(from: .now, by: 1)) { context in answer(o, now: context.date) }
        } else {
            noAnswer
        }
    }

    private func answer(_ o: RecoveryOpenOutcome, now: Date) -> some View {
        let t = openAnswerText(o, rightButIncomplete: state.rightButIncomplete)
        let waiting = o.retryAt.map { $0 > now } ?? false
        let canAgain = openCanTryAgain(o.code) && !waiting
        let newRecovery = openNeedsNewRecovery(o.code) && onStartOver != nil
        let primary: String? = canAgain ? RecoveryScreenStrings.onboardingOpenTryAgain
            : newRecovery ? RecoveryScreenStrings.onboardingOpenNewRecovery : nil
        let ended = o.code == "exhausted" || o.code == "stored_mismatch"
        return FormScaffold(
            title: RecoveryScreenStrings.recoverTitle, primaryLabel: primary,
            secondaryLabel: onStartOver != nil && !newRecovery ? RecoveryScreenStrings.recoverStartOver : nil,
            onPrimary: { if canAgain { actions.again() } else { onStartOver?() } }, onSecondary: { onStartOver?() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                NoticeCard(
                    ended ? .urgent : .warning, title: RecoveryOpenStrings.onboardingOpenAnswerTitle,
                    message: RecoveryTexts.openAnswer(t, retryAt: RecoveryTexts.retryAt(o.retryAt))
                )
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("open_answer_\(o.code)")
                if let left = t.attemptsLeft {
                    Text(RecoveryOpenStrings.onboardingOpenAttemptsLeft(left)).vettIDFont(.bodyMedium)
                }
                if let at = o.retryAt, waiting {
                    Text(RecoveryOpenStrings.onboardingOpenCountdown(openCountdown(until: at, now: now)))
                        .vettIDFont(.bodyMedium)
                        .accessibilityIdentifier("open_countdown")
                }
                if o.code == "no_recovery" && o.afterUnanswered {
                    PrimaryButton(RecoveryScreenStrings.onboardingOpenLostTitle) { actions.finishLostOk() }
                        .accessibilityIdentifier("open_lost_ok")
                }
            }
        }
        .accessibilityIdentifier("open_answered")
    }

    /// No readable answer (a failure before the vault answered, or random bytes): the text, and the ways on.
    private var noAnswer: some View {
        let failure = state.failure
        let unreadable = state.failureCode == RecoveryOpenState.codeUnreadable
        let text = unreadable
            ? RecoveryOpenStrings.onboardingOpenUnreadable : (failure ?? .other).message(timeScale: timeScale)
        return FormScaffold(
            title: RecoveryScreenStrings.recoverTitle, primaryLabel: RecoveryScreenStrings.onboardingOpenTryAgain,
            secondaryLabel: onStartOver == nil ? nil : RecoveryScreenStrings.recoverStartOver,
            onPrimary: actions.again, onSecondary: { onStartOver?() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                NoticeCard(.warning, title: RecoveryOpenStrings.onboardingOpenAnswerTitle, message: text)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("open_no_answer")
                // The answer may have been a lost `ok` (§11.14.6): the PIN finishes it, without an attempt.
                if unreadable || failure == .noResponse {
                    TextLink(RecoveryScreenStrings.onboardingOpenLostTitle, identifier: "open_lost_ok") { actions.finishLostOk() }
                }
            }
        }
        .accessibilityIdentifier("open_answered")
    }
}

/// The vault answered `ok` earlier: the PIN alone finishes opening it. No new open, no start over. After a lost answer the way
/// back to the open stays (only an `ok` the vault confirmed has none).
private struct OpenFinish: View {
    let state: RecoveryOpenState
    let actions: RecoveryOpenActions
    let timeScale: UInt64
    let pin: PinBuffer

    private var canFinish: Bool { pin.count >= RecoveryOpenState.minPin }

    private func finish() {
        guard canFinish else { return }
        actions.setPin(pin.take())
        actions.send()
    }

    var body: some View {
        FormScaffold(
            title: state.lostOk ? RecoveryScreenStrings.onboardingOpenLostTitle : RecoveryScreenStrings.onboardingOpenFinishTitle,
            message: state.lostOk ? RecoveryScreenStrings.onboardingOpenLostBody : RecoveryScreenStrings.onboardingOpenFinishBody,
            primaryLabel: RecoveryScreenStrings.onboardingOpenFinishGo, primaryEnabled: canFinish,
            secondaryLabel: state.lostOk ? RecoveryScreenStrings.onboardingOpenBack : nil, onPrimary: finish,
            onSecondary: actions.again
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PinEntry(label: RecoveryScreenStrings.onboardingOpenPin, buffer: pin, identifier: "open_finish_pin")
                if let o = state.outcome, o.opened {
                    NoticeCard(
                        .warning, title: RecoveryOpenStrings.onboardingOpenAnswerTitle,
                        message: RecoveryTexts.openAnswer(openAnswerText(o, rightButIncomplete: false), retryAt: "")
                    )
                    .accessibilityIdentifier("open_finish_answer")
                } else if let failure = state.failure {
                    NoticeCard(
                        .warning, title: RecoveryOpenStrings.onboardingOpenAnswerTitle, message: failure.message(timeScale: timeScale)
                    )
                    .accessibilityIdentifier("open_finish_failure")
                }
                if state.canErase {
                    Text(RecoveryScreenStrings.onboardingOpenFinishGone).vettIDFont(.bodyMedium)
                    DestructiveLink(label: OnboardingStrings.unlockErase, identifier: "open_finish_erase") { actions.askErase() }
                }
            }
        }
        .accessibilityIdentifier("open_finish")
    }
}

/// Recovered: the plan's `ok` text, read before the app opens.
private struct OpenDone: View {
    let state: RecoveryOpenState
    let actions: RecoveryOpenActions
    let timeScale: UInt64

    var body: some View {
        let o = state.outcome ?? RecoveryOpenOutcome("ok", used: state.used)
        FormScaffold(
            title: RecoveryScreenStrings.recoverTitle, primaryLabel: RecoveryScreenStrings.onboardingOpenContinue,
            onPrimary: actions.openApp
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                NoticeCard(
                    .info, title: RecoveryOpenStrings.onboardingOpenAnswerTitle,
                    message: RecoveryTexts.openAnswer(openAnswerText(o, rightButIncomplete: false), retryAt: "")
                )
                .accessibilityIdentifier("open_answer_ok")
                if let failure = state.failure {
                    // A lock asked for meanwhile is pending: said as the unlock screen says it (the phone stays locked).
                    Text(
                        state.failureCode == MoveCodes.lockPending
                            ? OnboardingStrings.unlockLockUnconfirmedBody : failure.message(timeScale: timeScale)
                    )
                    .vettIDFont(.bodyMedium)
                    .accessibilityIdentifier("open_app_failure")
                }
            }
        }
        .accessibilityIdentifier("open_done")
    }
}

/// The recovery's PIN and password with their view model, made when the step first appears. The route owns the model: the PIN
/// and the password are dropped when the screen goes. [problem]: what the flow says on the open step (a refused start over).
/// [onOpened]: the vault opened on this phone, the end of setup (the flow's `finish`).
struct RecoveryOpenRoute: View {
    let move: any MoveRepository
    let account: any AccountRepository
    let problem: OpenSideNotice?
    let onStartOver: @MainActor () -> Void
    let onOpened: @MainActor () -> Void
    @State private var model: RecoveryOpenViewModel?

    init(
        move: any MoveRepository, account: any AccountRepository, problem: OpenSideNotice?,
        onStartOver: @escaping @MainActor () -> Void, onOpened: @escaping @MainActor () -> Void,
        model: RecoveryOpenViewModel? = nil
    ) {
        self.move = move
        self.account = account
        self.problem = problem
        self.onStartOver = onStartOver
        self.onOpened = onOpened
        _model = State(initialValue: model)
    }

    var body: some View {
        RecoveryOpenContent(
            state: model?.state ?? RecoveryOpenState(), actions: model.map(RecoveryOpenActions.init) ?? RecoveryOpenActions(),
            problem: problem, onStartOver: onStartOver, onOpened: onOpened
        )
        .onAppear { if model == nil { model = RecoveryOpenViewModel(move: move, account: account) } }
        .onDisappear { model?.forgetSecrets() }
    }
}
#endif
