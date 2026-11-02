#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDUI
import VettIDVotes

/// The cast sheet: the confirm step (screen 3), then, when the unlock window is closed, the credential password prompt
/// (ANDROID-PLAN §4 "unlock window"), in place. While the request is on its way the sheet stays, busy.
struct CastSheet: View {
    let state: VoteScreenState
    let actions: VoteActions

    var body: some View {
        // The step follows how the request was sent, not whether the typed password is still held (it is dropped when the app
        // leaves the foreground, and the sheet must not flip to the confirm step with the request under way).
        let sendingWithPassword = state.cast == .sending && state.castWithPassword
        SecureContainer(isSecure: true) {
            if state.cast == .password || sendingWithPassword {
                PasswordStep(state: state, actions: actions)
            } else {
                ConfirmStep(state: state, actions: actions)
            }
        }
    }
}

/// "Vote “<label>”?", the fixed disclosure sentence (read first: VoiceOver lands on it, never on **Cast vote**), "Your vote
/// can't be changed after you cast it.", **Cast vote** and **Back**.
private struct ConfirmStep: View {
    @Environment(\.vettIDColors) private var colors
    let state: VoteScreenState
    let actions: VoteActions
    @AccessibilityFocusState private var onDisclosure: Bool

    var body: some View {
        let label = state.detail?.choices.first { $0.id == state.selected }?.label
        let service = AccountNames.isolateOrNull(state.serviceName) ?? VoteStrings.voteServiceFallback
        let sending = state.cast == .sending
        VStack(alignment: .leading, spacing: Spacing.m) {
            // The app's own sentence, never the proposal's, in its own element and read first.
            Text(VoteStrings.voteDisclosure(service))
                .vettIDFont(.bodyLarge)
                .accessibilityFocused($onDisclosure)
                .accessibilityIdentifier("vote_disclosure")
            Text(verbatim: VoteStrings.voteConfirmTitle(AccountNames.isolateOrNull(label) ?? ""))
                .vettIDFont(.titleMedium)
                .accessibilityAddTraits(.isHeader)
            Text(VoteStrings.voteFinal).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
            PrimaryButton(VoteStrings.voteConfirmYes, busy: sending, action: actions.onConfirmCast)
                .disabled(sending)
                .accessibilityIdentifier("vote_confirm_yes")
            SecondaryButton(VoteStrings.voteConfirmBack, action: actions.onDismissCast)
                .disabled(sending)
                .accessibilityIdentifier("vote_confirm_back")
        }
        .padding(Spacing.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vote_confirm_sheet")
        .onAppear { onDisclosure = true }
    }
}

/// The unlock window prompt, before `vote.cast` when the window is closed: the credential password on the secret field of
/// IOS-PLAN §6.5, with the wait after a wrong one counted down.
private struct PasswordStep: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: VoteScreenState
    let actions: VoteActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let waiting = state.retryUntil.map { $0 > context.date } == true
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(VoteStrings.votePasswordTitle).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
                Text(VoteStrings.votePasswordBody).vettIDFont(.bodyMedium)
                SecretField(
                    VoteStrings.votePasswordLabel, text: Binding(get: { state.password }, set: { actions.onPassword($0) }),
                    error: state.passwordError.map { $0.kind.message(timeScale: timeScale) }, errorPriority: .assertive,
                    focus: true, onSubmit: actions.onSubmitPassword
                )
                .accessibilityIdentifier("vote_password")
                PrimaryButton(VoteStrings.votePasswordConfirm, busy: state.cast == .sending, action: actions.onSubmitPassword)
                    .disabled(state.password.isEmpty || waiting || state.cast == .sending)
                    .accessibilityIdentifier("vote_password_confirm")
                SecondaryButton(VoteStrings.voteCancel, action: actions.onDismissCast)
                    .disabled(state.cast == .sending)
            }
            .padding(Spacing.gutter)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vote_password_sheet")
    }
}

/// "Is this your vote?" (screen 7): the service, the recorded choice and the title. Answered by one of two buttons; it is
/// not put away without an answer.
struct RestoreSheet: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: VoteScreenState
    let actions: VoteActions

    var body: some View {
        let service = AccountNames.isolateOrNull(state.serviceName) ?? VoteStrings.voteServiceFallback
        let choice = AccountNames.isolateOrNull(state.restoreLabel) ?? ""
        let title = AccountNames.isolateOrNull(state.summary?.title) ?? ""
        SecureContainer(isSecure: true) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(VoteStrings.voteRestoreTitle).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
                Text(verbatim: VoteStrings.voteRestoreBody(service, choice, title)).vettIDFont(.bodyMedium)
                if let p = state.restoreProblem {
                    Text(p.kind.message(timeScale: timeScale)).vettIDFont(.bodyMedium).foregroundStyle(colors.error)
                        .announced(p.kind.message(timeScale: timeScale), .assertive)
                }
                PrimaryButton(VoteStrings.voteRestoreYes, busy: state.restoreBusy) { actions.onAnswerRestore(true) }
                    .disabled(state.restoreBusy)
                    .accessibilityIdentifier("restore_yes")
                SecondaryButton(VoteStrings.voteRestoreNo) { actions.onAnswerRestore(false) }
                    .disabled(state.restoreBusy)
                    .accessibilityIdentifier("restore_no")
            }
            .padding(Spacing.gutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("vote_restore_sheet")
        }
    }
}

/// Release (screen 6): the vault PIN on the in-app keypad (IOS-PLAN §6.5), as History's export asks it; nothing is sent
/// anywhere by the app. The digits are dropped when the app leaves the foreground or the iPhone locks, and handed over once.
struct ReleaseSheet: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: VoteScreenState
    let actions: VoteActions
    @State private var pin = PinBuffer()

    var body: some View {
        let service = AccountNames.isolateOrNull(state.serviceName) ?? VoteStrings.voteServiceFallback
        SecureContainer(isSecure: true) {
            VStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(VoteStrings.voteReleaseTitle).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
                    Text(VoteStrings.voteReleaseBody(service)).vettIDFont(.bodyMedium)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(VoteStrings.voteReleasePin).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant)
                PinKeypad(buffer: pin)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(VoteStrings.voteReleasePin)
                    .accessibilityIdentifier("vote_release_pin")
                    .disabled(state.releaseBusy)
                if let p = state.releaseProblem {
                    let text = p.code == "evidence_not_exported" ? VoteStrings.voteReleaseNotSaved : p.kind.message(timeScale: timeScale)
                    Text(text).vettIDFont(.bodySmall).foregroundStyle(colors.error).multilineTextAlignment(.center)
                        .announced(text, .assertive)
                        .accessibilityIdentifier("vote_release_error")
                }
                PrimaryButton(VoteStrings.voteRelease, busy: state.releaseBusy) { actions.onConfirmRelease(pin.take()) }
                    .disabled(pin.count < PinPolicy.minLength || state.releaseBusy)
                    .accessibilityIdentifier("vote_release_confirm")
                SecondaryButton(VoteStrings.voteCancel, action: actions.onDismissRelease)
            }
            .padding(Spacing.gutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("vote_release_sheet")
        }
        .onDisappear { pin.clear() }
        .onChange(of: scenePhase) { _, now in if now == .background { pin.clear() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            pin.clear()
        }
    }
}
#endif
