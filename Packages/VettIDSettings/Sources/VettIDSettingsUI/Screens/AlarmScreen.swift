#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

/// What the clone alarm's screen can ask for. Mirrors vettid-android `AlarmActions`.
public struct AlarmActions {
    /// The member's answer ([mine]: "that was me"), confirmed next.
    public var answer: @MainActor (_ mine: Bool) -> Void = { _ in }
    public var cancelAnswer: @MainActor () -> Void = {}
    public var confirm: @MainActor () -> Void = {}
    public var setPassword: @MainActor (String) -> Void = { _ in }
    public var rotate: @MainActor () -> Void = {}
    public var forgetSecrets: @MainActor () -> Void = {}
    public var back: @MainActor () -> Void = {}

    public init() {}
}

/// The clone alarm (VAULT-MESSAGING §3.5.9), from the Credential screen's "Review" or the shell's banner: when and by whom
/// a copy was presented, "That was me" or "That was not me" (each confirmed), then the forced rotation with the
/// password, and the alert resolved. On "not me" the advice to change the password and the PIN. Mirrors vettid-android
/// `AlarmContent`.
public struct AlarmContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.vettIDCovered) private var covered
    @Environment(\.scenePhase) private var scenePhase
    let state: AlarmState
    let actions: AlarmActions

    public init(state: AlarmState, actions: AlarmActions = AlarmActions()) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        switch state.step {
        case .ask, .confirmMine, .confirmNotMine: ask
        case .rotate: rotate
        case .resolved: resolved
        }
    }

    /// Who presented the copy, as the alert said.
    static func presenter(_ a: CredentialAlarm?) -> String {
        switch a?.presenter {
        case "holder": CredentialStrings.alarmPresenterHolder
        case "other": CredentialStrings.alarmPresenterOther
        default: CredentialStrings.alarmPresenterUnknown
        }
    }

    /// When the copy was presented: the vault's time as a medium date and time, or as sent, or "-".
    static func at(_ a: CredentialAlarm?) -> String { CredentialContent.date(a?.at) ?? a?.at ?? "-" }

    private var ask: some View {
        FormScaffold(
            title: CredentialStrings.alarmTitle,
            message: CredentialStrings.alarmBody(Self.at(state.alarm), Self.presenter(state.alarm)),
            primaryLabel: CredentialStrings.alarmNotMine, busy: state.busy, destructive: true,
            secondaryLabel: CredentialStrings.alarmMine, onPrimary: { actions.answer(false) }, onSecondary: { actions.answer(true) },
            onBack: actions.back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                NoticeCard(.info, title: CredentialStrings.alarmMine, message: CredentialStrings.alarmMineBody)
                if let error = state.error {
                    NoticeCard(.urgent, title: error.title(or: CredentialStrings.title), message: error.message(timeScale: timeScale))
                        .accessibilityIdentifier("error")
                }
            }
        }
        .accessibilityIdentifier("alarm_ask")
        // The confirmation (vettid-android `ConfirmDialog`). Each button tells the view model; the alert's own dismissal
        // changes nothing, whichever comes first.
        .alert(confirmTitle, isPresented: Binding(get: { !covered && state.step != .ask && !state.busy }, set: { _ in })) {
            Button(CredentialStrings.alarmConfirm, action: actions.confirm).accessibilityIdentifier("alarm_confirm")
            Button(CredentialStrings.cancel, role: .cancel, action: actions.cancelAnswer)
        } message: {
            Text(CredentialStrings.alarmConfirmBody)
        }
    }

    private var confirmTitle: String {
        state.step == .confirmMine ? CredentialStrings.alarmConfirmMineTitle : CredentialStrings.alarmConfirmNotMineTitle
    }

    private var rotate: some View {
        FormScaffold(
            title: CredentialStrings.alarmRotateTitle, message: CredentialStrings.alarmRotateBody,
            primaryLabel: CredentialStrings.rotateSubmit, primaryEnabled: !state.password.isEmpty && !state.busy, busy: state.busy,
            onPrimary: actions.rotate, onBack: actions.back
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if state.notMine { advice }
                SecretField(
                    CredentialStrings.passwordLabel, text: Binding(get: { state.password }, set: { actions.setPassword($0) }),
                    onSubmit: actions.rotate
                )
                .accessibilityIdentifier("alarm_password")
                if let error = state.error {
                    NoticeCard(.urgent, title: error.title(or: CredentialStrings.title), message: error.message(timeScale: timeScale))
                        .accessibilityIdentifier("error")
                }
            }
            .disabled(state.busy)
        }
        .accessibilityIdentifier("alarm_rotate")
        .forgetsSecrets(scenePhase: scenePhase, actions.forgetSecrets)
    }

    private var resolved: some View {
        FormScaffold(
            title: CredentialStrings.alarmResolved, primaryLabel: CredentialStrings.done, onPrimary: actions.back, onBack: actions.back
        ) {
            if state.notMine { advice }
        }
        .accessibilityIdentifier("alarm_resolved")
    }

    private var advice: some View {
        NoticeCard(.warning, title: CredentialStrings.alarmNotMineAdviceTitle, message: CredentialStrings.alarmNotMineAdvice)
            .accessibilityIdentifier("alarm_not_mine_advice")
    }
}
#endif
