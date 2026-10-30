#if os(iOS)
import SwiftUI
import UIKit
import VettIDApprovals
import VettIDData
import VettIDUI

/// What the decision screen can ask for. Mirrors vettid-android `DecisionActions`.
public struct DecisionActions {
    public var onBack: @MainActor () -> Void = {}
    public var onPassword: @MainActor (String) -> Void = { _ in }
    public var onApprove: @MainActor () -> Void = {}
    public var onDeny: @MainActor () -> Void = {}
    public var onAskBlock: @MainActor (Bool) -> Void = { _ in }
    public var onBlock: @MainActor () -> Void = {}
    /// Ticks or unticks an item of a share decision.
    public var onToggleShareItem: @MainActor (String) -> Void = { _ in }
    /// A grant request (§10.12): tick an entry, answer a category entry with an item, set uses and lifetime.
    public var onToggleGrant: @MainActor (Int) -> Void = { _ in }
    public var onAnswerGrant: @MainActor (Int, String) -> Void = { _, _ in }
    public var onGrantUses: @MainActor (Int?) -> Void = { _ in }
    public var onGrantExpiresIn: @MainActor (Int?) -> Void = { _ in }
    /// Leaves a critical use's result.
    public var onFinish: @MainActor () -> Void = {}
    /// A withdrawn request's "Mute requests from …": asks (true) or cancels (false); a service connection's is confirmed.
    public var onAskMute: @MainActor (Bool) -> Void = { _ in }
    /// The mute confirmed.
    public var onMute: @MainActor () -> Void = {}
    /// The screen left or the app went to the background: the password goes.
    public var onForgetSecrets: @MainActor () -> Void = {}

    public init() {}
}

/// One approval (ANDROID-PLAN §4 Approvals): what is asked and by whom, then approve or deny, with the credential password
/// on the secret field of IOS-PLAN §6.5 for the critical actions. "Already decided" once it left the list without a
/// decision here, "No longer on this phone" when it was not held when the screen opened (IOS-PLAN §6.9); a critical use's
/// result before the screen closes. Mirrors vettid-android `ApprovalDetailScreen`.
public struct ApprovalDetailScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    let state: ApprovalDetailState
    let actions: DecisionActions

    public init(state: ApprovalDetailState, actions: DecisionActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        Group {
            if let a = state.approval, !state.gone {
                if state.withdrawn {
                    // No countdown: a withdrawn request no longer expires on screen.
                    withdrawn(a)
                } else if let status = state.criticalResult {
                    result(status)
                } else if state.retryUntil != nil || a.exp != nil {
                    // A password backoff counts down and the approve button comes back at its end; a request that expires
                    // while open turns into "Already decided".
                    TimelineView(.periodic(from: .now, by: 1)) { context in live(a, now: context.date) }
                } else {
                    decision(a, now: Date())
                }
            } else if state.notHeld {
                notHeld
            } else {
                gone
            }
        }
        // The result, "Already decided" or "No longer on this phone" replaces the request in place: a new screen for VoiceOver.
        .announcesStepChanges(of: step)
        .onChange(of: state.done, initial: true) { _, done in if done { actions.onBack() } }
        .onDisappear { actions.onForgetSecrets() }
        .onChange(of: scenePhase) { _, now in if now == .background { actions.onForgetSecrets() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            actions.onForgetSecrets()
        }
    }

    /// Decided on another device, or expired.
    private var gone: some View {
        FormScaffold(
            title: ApprovalsStrings.goneTitle, message: ApprovalsStrings.goneBody, primaryLabel: ApprovalsStrings.back,
            onPrimary: actions.onBack, onBack: actions.onBack
        ) { EmptyView() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval_gone")
    }

    /// Not on this phone since a lock or a restart, and never said to be decided or expired (chosen; not in the spec).
    private var notHeld: some View {
        FormScaffold(
            title: ApprovalsStrings.notHeldTitle, message: ApprovalsStrings.notHeldBody, primaryLabel: ApprovalsStrings.back,
            onPrimary: actions.onBack, onBack: actions.onBack
        ) { EmptyView() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval_not_held")
    }

    /// Withdrawn by its challenger (VAULT-MESSAGING 0.80.0 §10.4; ANDROID-PLAN 0.1.101): the request stays where it was,
    /// with the notice and Close in place of the decision, in a neutral style (never an error, never "declined"), and the
    /// existing mute as a secondary action until the connection's asks are muted. Without the connection's names the
    /// notice says "A connection", and the mute's confirmation is titled with the action's words (chosen; not in the spec).
    private func withdrawn(_ a: PendingApproval) -> some View {
        let who = AccountNames.isolateOrNull(state.connectionName) ?? ApprovalsStrings.aConnection
        return FormScaffold(
            title: ApprovalTexts.title(a, name: state.connectionName), primaryLabel: ApprovalsStrings.withdrawnClose,
            onPrimary: actions.onBack, onBack: actions.onBack
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                NoticeCard(.info, title: ApprovalsStrings.withdrawnNotice(who), announce: .polite)
                    .accessibilityIdentifier("approval_withdrawn")
                if !state.asksMuted, a.connectionID != nil {
                    NoticeAction(label: ApprovalsStrings.withdrawnMute(who), identifier: "withdrawn_mute") { actions.onAskMute(true) }
                        .disabled(state.muting)
                }
                if let text = state.muteError.map({ ApprovalTexts.failure($0, retryUntil: nil, limit: nil, now: Date()) }) {
                    Text(text).vettIDFont(.bodyMedium).announced(text, .assertive).accessibilityIdentifier("withdrawn_error")
                }
                Facts(approval: a, name: state.connectionName)
            }
        }
        .confirmDialog(
            isPresented: Binding(get: { state.confirmMute }, set: { if !$0 { actions.onAskMute(false) } }),
            title: ApprovalsStrings.withdrawnMute(who),
            message: ApprovalsStrings.withdrawnMuteConfirmService(who),
            confirmLabel: ApprovalsStrings.withdrawnMuteConfirm,
            dismissLabel: ApprovalsStrings.withdrawnMuteCancel,
            onConfirm: actions.onMute
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval_detail")
    }

    private enum Step { case decision, result, notHeld, gone, withdrawn }

    /// Which of the screen's steps shows, apart from an expiry while open (``live(_:now:)``).
    private var step: Step {
        if state.approval == nil || state.gone { return state.notHeld ? .notHeld : .gone }
        if state.withdrawn { return .withdrawn }
        return state.criticalResult == nil ? .decision : .result
    }

    @ViewBuilder private func live(_ a: PendingApproval, now: Date) -> some View {
        // Expired while open: "Already decided" in its place, a new screen for VoiceOver.
        if state.expired(at: now) { gone.onAppear { Announcer.screenChanged() } } else { decision(a, now: now) }
    }

    private func result(_ status: String) -> some View {
        let r = ApprovalTexts.criticalResult(status, name: state.connectionName)
        return FormScaffold(
            title: r.title, message: r.body, primaryLabel: ApprovalsStrings.back, onPrimary: actions.onFinish, onBack: actions.onFinish
        ) { EmptyView() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("critical_result")
    }

    private func decision(_ a: PendingApproval, now: Date) -> some View {
        FormScaffold(
            title: ApprovalTexts.title(a, name: state.connectionName),
            message: ApprovalTexts.body(a, name: state.connectionName),
            primaryLabel: ApprovalTexts.approveLabel(a),
            primaryEnabled: state.canApprove(at: now),
            busy: state.busy,
            secondaryLabel: ApprovalTexts.denyLabel(a),
            onPrimary: actions.onApprove,
            onSecondary: actions.onDeny,
            onBack: actions.onBack
        ) {
            DecisionContent(approval: a, state: state, actions: actions, now: now)
        }
        .confirmDialog(
            isPresented: Binding(get: { state.confirmBlock }, set: { if !$0 { actions.onAskBlock(false) } }),
            title: ApprovalsStrings.blockTitle,
            message: ApprovalsStrings.blockBody,
            confirmLabel: ApprovalsStrings.block,
            destructive: true,
            onConfirm: actions.onBlock
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval_detail")
    }
}

/// The decision's content: the facts of the request, the password, "Block this request", the failure.
struct DecisionContent: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let approval: PendingApproval
    let state: ApprovalDetailState
    let actions: DecisionActions
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch approval {
            case .share(let d):
                ShareFacts(decision: d, excluded: state.shareExcluded, name: state.connectionName, onToggle: actions.onToggleShareItem)
            case .grant(let g): GrantFacts(request: g, state: state, actions: actions)
            default: Facts(approval: approval, name: state.connectionName)
            }
            if state.needs == .password {
                SecretField(
                    ApprovalsStrings.password, text: Binding(get: { state.password }, set: { actions.onPassword($0) }),
                    supporting: ApprovalsStrings.passwordHint, onSubmit: actions.onApprove
                )
                .padding(.top, Spacing.l)
                .accessibilityIdentifier("approval_password")
            }
            if case .connection(.incoming) = approval {
                NoticeAction(label: ApprovalsStrings.block, identifier: "block_request", destructive: true) { actions.onAskBlock(true) }
                    .disabled(state.busy)
                    .padding(.top, Spacing.m)
            }
            if let error = state.error {
                let text = ApprovalTexts.failure(error, retryUntil: state.retryUntil, limit: state.limit, now: now, timeScale: timeScale)
                Text(text)
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.error)
                    .padding(.top, Spacing.m)
                    // Once: a password backoff counts down in it.
                    .announcedOnce(text, .assertive)
                    .accessibilityIdentifier("failure")
            }
        }
        .disabled(state.busy)
    }
}

/// Kept out of screenshots and screen recordings (IOS-PLAN §6.4 protection 3) unless the member allowed screenshots
/// (Settings → App): a connection request's safety code and a critical use's data to sign, as the connect screens keep
/// their codes (chosen; not in the spec).
struct CaptureProtected<Content: View>: View {
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    @ViewBuilder let content: () -> Content

    var body: some View {
        SecureContainer(isSecure: !(allowance?.allowed ?? false)) { content() }
    }
}
#endif
