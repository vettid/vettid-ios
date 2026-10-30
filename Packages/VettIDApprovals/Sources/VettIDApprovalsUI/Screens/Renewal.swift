#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDData
import VettIDUI

/// A renewal request's part of the decision (VAULT-MESSAGING 0.78.0 §6.8 step 3, texts approved by the owner): the notice
/// that a deny keeps the current access until the session's end, "Deny and end access now", and why ending access
/// failed. Session requests stay decline-only (owner decision 2026-10-29), so there is no Approve. "Deny and end access
/// now" sits under the notice rather than beside Deny (chosen; not in the spec). Mirrors vettid-android `RenewalNotices`.
struct RenewalNotices: View {
    let state: ApprovalDetailState
    let actions: DecisionActions
    let now: Date

    var body: some View {
        if let until = state.renewalUntil(at: now) {
            Text(ApprovalsStrings.renewalNotice(ApprovalTexts.deviceSentenceStart(state.endRequest), ApprovalTimes.full(until)))
                .vettIDFont(.bodyLarge)
                .padding(.top, Spacing.l)
                .accessibilityIdentifier("renewal_notice")
            NoticeAction(
                label: ApprovalsStrings.denyEndAccess, identifier: "deny_end_access", destructive: true, action: actions.onAskEndAccess
            )
            .disabled(state.busy)
            .padding(.top, Spacing.m)
        }
        if let failure = state.endFailure {
            EndFailureNotice(failure: failure, state: state, actions: actions, canRetry: state.renewalUntil(at: now) != nil)
                .padding(.top, Spacing.m)
        }
    }
}

/// On the screen of a request that left (decided elsewhere, expired, or dropped by a hold): a failed end is said, with
/// Try again while the session is live; nothing while the vault is held.
struct LeftEndAccess: View {
    let state: ApprovalDetailState
    let actions: DecisionActions

    var body: some View {
        if let failure = state.endFailure, !state.held {
            EndFailureNotice(failure: failure, state: state, actions: actions, canRetry: state.renewalUntil() != nil)
        }
    }
}

/// Ending access failed (the words of vettid-android's Devices page): the request stays open; Try again asks the
/// confirmation again. A refused daily check says why in the vault's words; anything else says what did not happen.
struct EndFailureNotice: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let failure: FailureKind
    let state: ApprovalDetailState
    let actions: DecisionActions
    let canRetry: Bool

    /// The failure's words: the vault's for a refused daily check, else what did not happen to [request]'s device.
    static func message(_ failure: FailureKind, _ request: PendingApproval?, timeScale: UInt64) -> String {
        failure == .ownerCheckRequired
            ? ApprovalTexts.failure(failure, retryUntil: nil, limit: nil, now: Date(), timeScale: timeScale)
            : ApprovalsStrings.endFailed(ApprovalTexts.deviceSentenceInline(request))
    }

    var body: some View {
        let message = Self.message(failure, state.endRequest, timeScale: timeScale)
        NoticeCard(.warning, title: ApprovalsStrings.endFailedTitle, message: message, announce: .assertive) {
            HStack(spacing: Spacing.m) {
                // Nothing to retry once the session has passed.
                if canRetry { NoticeAction(label: ApprovalsStrings.retry, identifier: "end_retry", action: actions.onAskEndAccess) }
                NoticeAction(label: ApprovalsStrings.ok, identifier: "end_failure_ok", action: actions.onDismissEndFailure)
            }
        }
        .accessibilityIdentifier("end_failure")
    }
}

extension View {
    /// "End access for <device>?" (0.78.0 §6.8 step 3), with the Devices page's words; closed while the vault is held.
    func endAccessConfirmation(_ state: ApprovalDetailState, _ actions: DecisionActions) -> some View {
        confirmDialog(
            isPresented: Binding(get: { state.confirmEnd }, set: { if !$0 { actions.onDismissEndAccess() } }),
            title: ApprovalsStrings.endAccessTitle(ApprovalTexts.deviceSentenceInline(state.endRequest)),
            message: ApprovalsStrings.endAccessBody,
            confirmLabel: ApprovalsStrings.endAccess,
            destructive: true,
            onConfirm: actions.onEndAccess
        )
    }
}
#endif
