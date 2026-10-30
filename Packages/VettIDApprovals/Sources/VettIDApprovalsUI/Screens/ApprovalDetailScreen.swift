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
    /// A renewal request (VAULT-MESSAGING 0.78.0 §6.8 step 3): "Deny and end access now" asks the confirmation; it ends
    /// access; it closes; a failure's OK.
    public var onAskEndAccess: @MainActor () -> Void = {}
    public var onEndAccess: @MainActor () -> Void = {}
    public var onDismissEndAccess: @MainActor () -> Void = {}
    public var onDismissEndFailure: @MainActor () -> Void = {}
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
                if let status = state.criticalResult {
                    result(status)
                } else if state.retryUntil != nil || a.exp != nil || state.sessionEnd != nil {
                    // A password backoff counts down and the approve button comes back at its end; a request that expires
                    // while open turns into "Already decided"; a renewal whose session passes reads as a first request.
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

    /// Decided on another device, or expired. A failed end of a renewal's access is said here too, never silent, with Try
    /// again while the session is live; a confirmation already open stays and still ends access (0.78.0 §6.8 step 3).
    private var gone: some View {
        FormScaffold(
            title: ApprovalsStrings.goneTitle, message: ApprovalsStrings.goneBody, primaryLabel: ApprovalsStrings.back,
            onPrimary: actions.onBack, onBack: actions.onBack
        ) { LeftEndAccess(state: state, actions: actions) }
        .endAccessConfirmation(state, actions)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval_gone")
    }

    /// Not on this phone since a lock or a restart, and never said to be decided or expired (chosen; not in the spec). A
    /// hold drops a session request too: a failed end stays said here (chosen; not in the spec).
    private var notHeld: some View {
        FormScaffold(
            title: ApprovalsStrings.notHeldTitle, message: ApprovalsStrings.notHeldBody, primaryLabel: ApprovalsStrings.back,
            onPrimary: actions.onBack, onBack: actions.onBack
        ) { LeftEndAccess(state: state, actions: actions) }
        .endAccessConfirmation(state, actions)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval_not_held")
    }

    private enum Step { case decision, result, notHeld, gone }

    /// Which of the screen's steps shows, apart from an expiry while open (``live(_:now:)``).
    private var step: Step {
        if state.approval == nil || state.gone { return state.notHeld ? .notHeld : .gone }
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
        .endAccessConfirmation(state, actions)
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
            default: Facts(approval: approval, name: state.connectionName, renewal: state.renewalUntil(at: now) != nil)
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
            RenewalNotices(state: state, actions: actions, now: now)
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
