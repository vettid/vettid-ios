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
    /// The screen left or the app went to the background: the password goes.
    public var onForgetSecrets: @MainActor () -> Void = {}

    public init() {}
}

/// One approval (ANDROID-PLAN §4 Approvals): what is asked and by whom, then approve or deny, with the credential password
/// on the secret field of IOS-PLAN §6.5 for the critical actions. "Already decided" once it left the list without a
/// decision here; a critical use's result before the screen closes. Mirrors vettid-android `ApprovalDetailScreen`.
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
                } else if state.retryUntil != nil || a.exp != nil {
                    // A password backoff counts down and the approve button comes back at its end; a request that expires
                    // while open turns into "Already decided".
                    TimelineView(.periodic(from: .now, by: 1)) { context in live(a, now: context.date) }
                } else {
                    decision(a, now: Date())
                }
            } else {
                gone
            }
        }
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

    @ViewBuilder private func live(_ a: PendingApproval, now: Date) -> some View {
        if state.expired(at: now) { gone } else { decision(a, now: now) }
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
                Text(ApprovalTexts.failure(error, retryUntil: state.retryUntil, limit: state.limit, now: now, timeScale: timeScale))
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.error)
                    .padding(.top, Spacing.m)
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
