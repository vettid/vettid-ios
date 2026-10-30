#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// One recovery step for [state] (stateless), up to the open: what is needed, the scan, the typed code, the registration, the
/// ways out of a vault without a backup, and the guidance of a refusal. [camera] replaces the camera preview (previews, the
/// screen catalog). [openPane]: the PIN and password pane of ``RecoverStep/open`` (``RecoveryOpenRoute``). [onLeave] returns to
/// the onboarding choice; [onNewVault] starts a new vault after a recovery that cannot happen. Mirrors vettid-android
/// `RecoverContent` for release R (IOS-PLAN ID8: the earlier recovery's PIN, password and "ended" steps are not on iOS).
public struct RecoverContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The width of a line of the typed code, once laid out.
    @State private var codeWidth: CGFloat?
    let state: RecoverState
    let actions: any RecoverActions
    let onLeave: @MainActor () -> Void
    let onNewVault: @MainActor () -> Void
    let onOpenAccountSite: @MainActor () -> Void
    let camera: AnyView?
    let openPane: AnyView?

    public init(
        state: RecoverState,
        actions: any RecoverActions = NoRecoverActions(),
        onLeave: @escaping @MainActor () -> Void = {},
        onNewVault: @escaping @MainActor () -> Void = {},
        onOpenAccountSite: @escaping @MainActor () -> Void = {},
        camera: AnyView? = nil,
        openPane: AnyView? = nil
    ) {
        self.state = state
        self.actions = actions
        self.onLeave = onLeave
        self.onNewVault = onNewVault
        self.onOpenAccountSite = onOpenAccountSite
        self.camera = camera
        self.openPane = openPane
    }

    /// Steps the member leaves the recovery from (the stage that could not be read is one: nothing else is offered there).
    static func leaveable(_ step: RecoverStep) -> Bool { [.intro, .loading, .stageFailed].contains(step) }

    private var leaveable: Bool { Self.leaveable(state.step) }

    private var canBack: Bool { leaveable || state.step == .scan || state.step == .type }

    private var back: (@MainActor () -> Void)? {
        guard canBack else { return nil }
        let actions = actions
        let onLeave = onLeave
        let leaveable = leaveable
        return { if !actions.back() && leaveable { onLeave() } }
    }

    public var body: some View {
        screen
            // Loading and the intro are one screen.
            .announcesStepChanges(of: state.step == .loading ? .intro : state.step)
            .confirmDialog(
                isPresented: Binding(get: { state.confirmStartOver }, set: { if !$0 { actions.dismissStartOver() } }),
                // What "Start over" does, said plainly: the app cannot cancel the recovery itself (§11.11.4).
                title: RecoveryScreenStrings.recoverStartOverTitle, message: RecoveryScreenStrings.recoverStartOverBody,
                confirmLabel: RecoveryScreenStrings.recoverStartOver, destructive: true, onConfirm: { actions.confirmStartOver() }
            )
    }

    @ViewBuilder private var screen: some View {
        switch state.step {
        case .loading, .intro: intro
        case .stageFailed: stageFailed
        case .scan: scan
        case .type: type
        case .registering: registering
        case .open: openPane ?? AnyView(EmptyView())
        case .noBackup: noBackup
        case .couldNotTell: couldNotTell
        }
    }

    private var goToOpen: (@MainActor () -> Void)? {
        let actions = actions
        return { actions.showOpen() }
    }

    private var intro: some View {
        let loading = state.step == .loading
        return FormScaffold(
            title: RecoveryScreenStrings.recoverTitle,
            message: RecoveryScreenStrings.recoverBody(TimeScales.text(TimeScales.recoveryDelay, by: timeScale)),
            primaryLabel: loading ? nil : RecoveryScreenStrings.recoverScan,
            busy: state.busy || loading,
            secondaryLabel: loading ? nil : RecoveryScreenStrings.recoverType,
            onPrimary: actions.scan, onSecondary: actions.type, onBack: back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                SmallNote(TimeScales.stagingNote(timeScale))
                NoticeCard(.info, title: MoveStrings.recoverNeedTitle, message: RecoveryScreenStrings.recoverNeedBody)
                CodeRefusalNotice(state: state)
                ClaimFailure(state: state, onGoToOpen: goToOpen)
                TextLink(RecoveryScreenStrings.recoverOpenSite, identifier: "recover_open_site", action: onOpenAccountSite)
            }
        }
        .accessibilityIdentifier("recover_intro")
    }

    /// (IOS-PLAN §4.9) An open got no readable answer and its recovery ended: a new code may use this phone (vettid-android's
    /// ended step with `recover_could_not_tell`; the scan step offers typing).
    private var couldNotTell: some View {
        FormScaffold(
            title: RecoveryStrings.recoverEndedTitle, message: RecoveryStrings.recoverCouldNotTell,
            primaryLabel: RecoveryStrings.recoverUndecidedNewCode, busy: state.busy, onPrimary: actions.scan, onBack: back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                CodeRefusalNotice(state: state)
                ClaimFailure(state: state, onGoToOpen: goToOpen)
            }
        }
        .accessibilityIdentifier("recover_could_not_tell")
    }

    /// Where the recovery stands could not be read: only a retry, so that a registered recovery is never taken for none.
    private var stageFailed: some View {
        FormScaffold(
            title: RecoveryScreenStrings.recoverTitle, message: RecoveryScreenStrings.iosRecoverStageFailed,
            primaryLabel: RecoveryScreenStrings.onboardingOpenTryAgain, onPrimary: actions.retryStage, onBack: back
        ) {
            if let kind = state.error {
                NoticeCard(
                    .urgent, title: MoveStrings.recoverFailedTitle, message: kind.message(timeScale: timeScale),
                    announce: .assertive
                )
                    .accessibilityIdentifier("error")
            }
        }
        .accessibilityIdentifier("recover_stage_failed")
    }

    private var scan: some View {
        // After a refusal or a failure the camera reads the same QR again at once and it is not sent again: "Try again" scans
        // anew (the model forgets the refused text).
        let retry = state.refusal != nil || state.error != nil
        return FormScaffold(
            title: RecoveryScreenStrings.recoverScanTitle, message: RecoveryScreenStrings.recoverScanBody,
            primaryLabel: retry ? RecoveryScreenStrings.onboardingOpenTryAgain : nil, busy: state.busy,
            secondaryLabel: RecoveryScreenStrings.recoverType, onPrimary: actions.scan, onSecondary: actions.type, onBack: back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ScannerBox(
                    onText: actions.scanned, onTypeInstead: actions.type, camera: camera,
                    typeLabel: RecoveryScreenStrings.recoverType
                )
                CodeRefusalNotice(state: state)
                ClaimFailure(state: state, onGoToOpen: goToOpen)
            }
        }
        .accessibilityIdentifier("recover_scan")
    }

    /// The code typed or pasted (VAULT-MESSAGING §11.11.10): in groups of four, in a field without AutoFill, suggestions or
    /// keyboard learning (IOS-PLAN §6.5), out of captures (§6.4) and never copied (no Copy or Cut).
    private var type: some View {
        let problem = RecoveryTexts.typedProblem(state)
        let groups = RecoveryScreenStrings.recoverTypeGroups(state.typedGroups, RecoverState.codeGroups)
        let perRow = codeWidth.map { width in
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
            return TypedCodeFormat.groupsPerRow(fitting: width, font: SecretTextEditor.font(monospaced: true, compatibleWith: traits))
        } ?? TypedCodeFormat.groupsPerRow
        return FormScaffold(
            title: RecoveryScreenStrings.recoverTypeTitle, message: RecoveryScreenStrings.recoverTypeBody,
            primaryLabel: OnboardingStrings.continueLabel, primaryEnabled: state.typedComplete, busy: state.busy,
            secondaryLabel: RecoveryScreenStrings.recoverScanInstead, onPrimary: actions.submitTyped, onSecondary: actions.scan,
            onBack: back
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CaptureProtected {
                    SecretTextEditor(
                        RecoveryScreenStrings.recoverTypeLabel,
                        text: Binding(get: { TypedCodeFormat.grouped(state.typed, perRow: perRow) }, set: { actions.setTyped($0) }),
                        placeholder: RecoveryScreenStrings.recoverTypeLabel, isError: problem != nil, pasteOnly: true,
                        // Return is Done (as on Android): it continues when Continue is enabled.
                        onSubmit: { if state.typedComplete && !state.busy { actions.submitTyped() } },
                        keeps: RecoverState.keepsTyped, monospaced: true, onTextWidth: { codeWidth = $0 }
                    )
                    .disabled(state.busy)
                }
                .accessibilityIdentifier("recover_typed")
                Text(groups)
                    .vettIDFont(.bodySmall)
                    // Spoken as it changes, not when the step opens (as vettid-android's live region).
                    .onChange(of: groups) { _, now in Announcer.announce(now) }
                    .accessibilityIdentifier("typed_groups")
                if let problem {
                    TypedProblemText(text: problem)
                }
                CodeRefusalNotice(state: state)
                ClaimFailure(state: state, onGoToOpen: goToOpen)
            }
        }
        .accessibilityIdentifier("recover_type")
    }

    private var registering: some View {
        FormScaffold(title: RecoveryScreenStrings.recoverTitle, primaryLabel: nil, onPrimary: {}) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                WaitingRow(text: RecoveryScreenStrings.recoverRegistering, identifier: "registering")
                Text(RecoveryScreenStrings.recoverRegisteringStarting)
                    .vettIDFont(.bodySmall)
                    .accessibilityIdentifier("registering_starting")
            }
        }
    }

    /// The vault keeps no backup copy of its credential (`no_backup`): nothing to recover, only a deletion on the account site
    /// and a new vault.
    private var noBackup: some View {
        let url = URL(string: state.startOverURL)
        return FormScaffold(
            title: RecoveryScreenStrings.recoverNoBackupTitle, message: RecoveryScreenStrings.recoverNoBackupBody,
            primaryLabel: RecoveryScreenStrings.recoverNoBackupStartOver, primaryEnabled: url != nil,
            secondaryLabel: RecoveryScreenStrings.recoverNoBackupNewVault,
            onPrimary: { if let url { openURL(url) } }, onSecondary: onNewVault
        ) {
            NoticeCard(.urgent, title: RecoveryScreenStrings.recoverNoBackupTitle, message: RecoveryScreenStrings.recoverNoBackupNotice)
        }
        .accessibilityIdentifier("recover_no_backup")
    }
}

/// The typed entry's problem, in the error colour, announced at once.
private struct TypedProblemText: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View {
        Text(text)
            .vettIDFont(.bodyMedium)
            .foregroundStyle(colors.error)
            .announced(text, .assertive)
            .accessibilityIdentifier("typed_problem")
    }
}

/// The recovery on this phone with its view model, made when it first appears. The route owns the model: the typed code is
/// forgotten when the screen goes, when the app leaves the foreground and when the iPhone locks (IOS-PLAN §6.3; chosen; not in
/// the spec). A registered recovery stays registered when the screen goes (only "Start over" and the account site end it,
/// §11.11.4). [onLeave], [onNewVault] and [onOpenAccountSite] as ``OnboardingRoutes/recover``. Mirrors vettid-android
/// `RecoverFlow`.
public struct RecoverRoute: View {
    private let move: any MoveRepository
    private let vault: any VaultRepository
    private let account: any AccountRepository
    private let onLeave: @MainActor () -> Void
    private let onNewVault: @MainActor () -> Void
    private let onOpenAccountSite: @MainActor () -> Void
    private let camera: AnyView?
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: RecoverViewModel?

    public init(
        move: any MoveRepository,
        vault: any VaultRepository,
        account: any AccountRepository,
        onLeave: @escaping @MainActor () -> Void,
        onNewVault: @escaping @MainActor () -> Void,
        onOpenAccountSite: @escaping @MainActor () -> Void,
        camera: AnyView? = nil
    ) {
        self.init(
            move: move, vault: vault, account: account, onLeave: onLeave, onNewVault: onNewVault,
            onOpenAccountSite: onOpenAccountSite, camera: camera, model: nil
        )
    }

    /// TEST ONLY: [model] is the route's own from the start.
    init(
        move: any MoveRepository, vault: any VaultRepository, account: any AccountRepository,
        onLeave: @escaping @MainActor () -> Void, onNewVault: @escaping @MainActor () -> Void,
        onOpenAccountSite: @escaping @MainActor () -> Void, camera: AnyView?, model: RecoverViewModel?
    ) {
        self.move = move
        self.vault = vault
        self.account = account
        self.onLeave = onLeave
        self.onNewVault = onNewVault
        self.onOpenAccountSite = onOpenAccountSite
        self.camera = camera
        _model = State(initialValue: model)
    }

    public var body: some View {
        let state = model?.state ?? RecoverState()
        RecoverContent(
            state: state, actions: model ?? NoRecoverActions(), onLeave: onLeave, onNewVault: onNewVault,
            onOpenAccountSite: onOpenAccountSite, camera: camera, openPane: openPane(state)
        )
        .onAppear { if model == nil { model = RecoverViewModel(move: move, vault: vault, account: account) } }
        .onDisappear { Self.forget(model) }
        .onChange(of: scenePhase) { _, now in
            if now == .background { Self.forget(model) }
            // (IOS-PLAN §4.9) The rule is read again when the app comes back (when a read is due).
            if now == .active { model?.checkEnded() }
        }
        // The ended step replacing the open step while the member looks is announced, once (vettid-android's live region).
        .onChange(of: model?.state.step) { old, now in
            if old == .open && now == .couldNotTell { Announcer.announce(RecoveryStrings.recoverCouldNotTell) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            Self.forget(model)
        }
    }

    /// The PIN and password pane, with the open step's notice for what a start over was refused for. The end of setup is the
    /// flow's `finish` once the vault opened (the `ok` text is the recovered phone's last setup screen).
    private func openPane(_ state: RecoverState) -> AnyView? {
        guard state.step == .open, let model else { return nil }
        let problem: OpenSideNotice? = state.guidance.map(OpenSideNotice.guidance) ?? state.error.map(OpenSideNotice.failure)
        return AnyView(
            RecoveryOpenRoute(
                move: move, account: account, problem: problem, busy: state.busy, rule: state.couldNotTell,
                reopenLostOk: state.reopenLostOk, onStartOver: { model.askStartOver() },
                onNewCode: { model.useNewCode() }, onAnswered: { model.checkEnded() },
                onHold: { model.holdOpen($0) }, onReopened: { model.lostOkReopened() }, onOpened: { model.finish() }
            )
        )
    }

    /// The typed code is forgotten, whatever the step and whatever runs.
    static func forget(_ model: RecoverViewModel?) {
        model?.forgetTyped()
    }
}
#endif
