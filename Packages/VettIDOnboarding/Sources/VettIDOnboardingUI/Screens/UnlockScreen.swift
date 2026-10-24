#if os(iOS)
import Combine
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The unlock screen, driven by an ``UnlockViewModel`` made when it first appears. [onOpenAccountSite]: "Recover your
/// vault". Mirrors vettid-android `UnlockRoute`.
public struct UnlockFlow: View {
    private let vault: any VaultRepository
    private let account: any AccountRepository
    private let ownerCheck: (any OwnerCheckRepository)?
    private let releaseNotes: (any ReleaseNotesRepository)?
    private let onOpenAccountSite: @MainActor () -> Void
    @State private var model: UnlockViewModel?
    @Environment(\.vettIDColors) private var colors

    public init(
        vault: any VaultRepository,
        account: any AccountRepository,
        ownerCheck: (any OwnerCheckRepository)? = nil,
        releaseNotes: (any ReleaseNotesRepository)? = nil,
        onOpenAccountSite: @escaping @MainActor () -> Void
    ) {
        self.vault = vault
        self.account = account
        self.ownerCheck = ownerCheck
        self.releaseNotes = releaseNotes
        self.onOpenAccountSite = onOpenAccountSite
    }

    public var body: some View {
        Group {
            if let model {
                UnlockScreen(state: model.state, actions: model, onOpenAccountSite: onOpenAccountSite)
            } else {
                colors.background.color.ignoresSafeArea()
            }
        }
        .onAppear {
            if model == nil {
                model = UnlockViewModel(vault: vault, account: account, ownerCheck: ownerCheck, releaseNotes: releaseNotes)
            }
        }
    }
}

/// The unlock screen for [state] (stateless). The PIN is typed on the in-app keypad (IOS-PLAN §6.5): its digits stay in
/// the keypad's buffer, handed to the model once, on "Unlock", and zeroed when the screen goes or the app leaves the
/// foreground. [onContactSupport]: "Contact support", which reports whether a mail app took it (else the address is shown
/// to copy). Mirrors vettid-android `UnlockContent`.
public struct UnlockScreen: View {
    let state: UnlockState
    let actions: any UnlockActions
    let onOpenAccountSite: @MainActor () -> Void
    let onContactSupport: (@MainActor (_ done: @escaping @MainActor (Bool) -> Void) -> Void)?
    @State private var pin = PinBuffer()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    public init(
        state: UnlockState,
        actions: any UnlockActions,
        onOpenAccountSite: @escaping @MainActor () -> Void = {},
        onContactSupport: (@MainActor (_ done: @escaping @MainActor (Bool) -> Void) -> Void)? = nil
    ) {
        self.state = state
        self.actions = actions
        self.onOpenAccountSite = onOpenAccountSite
        self.onContactSupport = onContactSupport
    }

    private var blocked: Bool { state.recoverOnly }

    private var primaryLabel: String? {
        if state.returnAsksPin, let m = state.moveUnconfirmed { return OnboardingStrings.releaseUpdateReturn(Int(m.from.number)) }
        if state.preflightError != nil && !blocked { return OnboardingStrings.unlockRetry }
        if blocked || state.recoveryPending { return nil }
        return OnboardingStrings.unlockSubmit
    }

    private var canSubmit: Bool {
        state.pinAllowed && pin.count >= UnlockState.minPinLength && (!state.checkDue || !state.password.isEmpty)
    }

    private func submit() {
        guard canSubmit else { return }
        actions.setPin(pin.take())
        actions.submit()
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.unlockTitle,
            message: state.email.map(OnboardingStrings.unlockBodyAccount) ?? OnboardingStrings.unlockBody,
            primaryLabel: primaryLabel,
            primaryEnabled: state.preflightError != nil && !state.returnAsksPin ? state.retryAllowed : canSubmit,
            busy: state.busy || state.loading || state.erasing,
            onPrimary: { state.preflightError != nil && !state.returnAsksPin ? actions.retryPreflight() : submit() },
            header: {
                VettIDSymbol.lock.image.font(.system(size: 36)).padding(.top, Spacing.l).accessibilityHidden(true)
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                UnlockNotices(state: state, actions: actions)
                if state.showsPin {
                    pinEntry
                    UnlockMessageNotice(state: state)
                }
                if state.signerRefused {
                    SignerRefusedNotice(
                        help: state.signerHelp, recovery: state.recoveryText, stagingNote: state.stagingNote, actions: actions
                    )
                }
                if state.returnAsksPin {
                    TextLink(OnboardingStrings.releaseUpdateNotNow, identifier: "unlock_return_cancel") { actions.cancelReturn() }
                }
                wayForward
            }
        }
        .confirmDialog(
            isPresented: Binding(get: { state.eraseConfirm && state.eraseOffered }, set: { if !$0 { actions.dismissErase() } }),
            title: OnboardingStrings.unlockEraseConfirmTitle,
            // A phone without its vault's keys: the root screen's text, which says what a recovery then needs.
            message: state.keysGone && !state.notRecognised
                ? UnreachableScreen.erasePhoneBody(timeScale: state.timeScale) : OnboardingStrings.unlockEraseConfirmBody,
            confirmLabel: OnboardingStrings.unlockEraseConfirm,
            destructive: true,
            onConfirm: { actions.confirmErase() }
        )
        .confirmDialog(
            isPresented: Binding(get: { state.returnConfirm && state.returnOffered }, set: { if !$0 { actions.dismissReturn() } }),
            title: OnboardingStrings.releaseUpdateReturnConfirmTitle(returnFrom),
            message: OnboardingStrings.releaseUpdateReturnConfirmBody(returnFrom, returnTo),
            confirmLabel: OnboardingStrings.releaseUpdateReturn(returnFrom)
        ) {
            // IOS-PLAN §4.3 point 3: the unlock screen's PIN, or the keypad asks for it first.
            if pin.count >= UnlockState.minPinLength { actions.setPin(pin.take()) }
            actions.confirmReturn()
        }
        .onDisappear { pin.clear() }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
            if now == .background { forgetSecrets() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            forgetSecrets()
        }
        .accessibilityIdentifier("unlock")
    }

    private var returnFrom: Int { Int(state.moveUnconfirmed?.from.number ?? 0) }
    private var returnTo: Int { Int(state.moveUnconfirmed?.to.number ?? 0) }

    /// The keypad, the countdown and, with a check due, the password (§3.6.5: one screen for both).
    @ViewBuilder private var pinEntry: some View {
        // VAULT-MESSAGING §11.14.9 "A lost answer" step 5: the previous PIN first, the new one after `device_secret`.
        switch state.pinStep {
        case .pin: EmptyView()
        case .previous:
            NoticeCard(.info, title: OnboardingStrings.unlockPreviousPinTitle, message: OnboardingStrings.unlockPreviousPinBody)
                .accessibilityIdentifier("unlock_previous_pin")
        case .new:
            NoticeCard(.success, title: OnboardingStrings.unlockNewPinTitle, message: OnboardingStrings.unlockNewPinBody)
                .accessibilityIdentifier("unlock_new_pin")
        }
        PinEntry(
            label: OnboardingStrings.unlockPinLabel,
            buffer: pin,
            error: state.message == .badPin && pin.count == 0 ? OnboardingStrings.unlockBadPin : nil,
            identifier: "unlock_pin"
        )
        .disabled(!state.pinAllowed)
        .padding(.top, Spacing.s)
        if state.waitSeconds > 0 {
            Text(OnboardingStrings.unlockWait(formatWait(state.waitSeconds)))
                .vettIDFont(.bodySmall)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("unlock_wait")
        }
        if state.checkDue {
            SecretField(
                OnboardingStrings.unlockPasswordLabel,
                text: Binding(get: { state.password }, set: { actions.setPassword($0) }),
                onSubmit: submit
            )
            .disabled(!state.pinAllowed)
            .accessibilityIdentifier("unlock_password")
        }
    }

    /// An ended release or a rollback wins: no erase there, whatever else the last answers said.
    @ViewBuilder private var wayForward: some View {
        if state.recoverOnly {
            RecoverOnlyNotice(onRecover: onOpenAccountSite, contactSupport: contactSupport)
        } else if state.notRecognised {
            NotRecognisedNotice(erasing: state.erasing, onErase: { actions.askErase() })
        } else if state.keysGone {
            StuckNotice(
                erasing: state.erasing, earlierSecret: state.earlierSecret, pinReady: pin.count >= UnlockState.minPinLength,
                onErase: { actions.askErase() }, onRecover: onOpenAccountSite,
                onEarlierSecret: {
                    actions.setPin(pin.take())
                    actions.submitEarlierSecret()
                }
            )
        }
    }

    private func forgetSecrets() {
        pin.clear()
        actions.forgetSecrets()
    }

    private func contactSupport(_ done: @escaping @MainActor (Bool) -> Void) {
        if let onContactSupport { return onContactSupport(done) }
        openURL(SupportMail.url) { accepted in done(accepted) }
    }
}

/// The notices above the PIN: the release check, the lock, the refusals, the owner check, a move, a rollback, a recovery.
struct UnlockNotices: View {
    let state: UnlockState
    let actions: any UnlockActions

    var body: some View {
        if state.loading {
            HStack(spacing: Spacing.m) {
                ProgressView()
                Text(OnboardingStrings.unlockChecking).vettIDFont(.bodyMedium)
            }
            .accessibilityElement(children: .combine)
        }
        if state.keptTransfer {
            // Release R (§11.14.10): the old phone after a transfer's approval.
            NoticeCard(
                .info, title: OnboardingStrings.moveDidntFinish,
                message: OnboardingStrings.keptTransfer(state.keptTransferText) + "\n\n" + OnboardingStrings.moveDidntFinishBody
            )
            .accessibilityIdentifier("kept_transfer")
            SmallNote(state.stagingNote)
        }
        if let error = state.preflightError {
            let title = switch error {
            case .releaseUnknown: OnboardingStrings.unlockReleaseUnknownTitle
            case .enclave: OnboardingStrings.unlockEnclaveTitle
            default: OnboardingStrings.unlockTitle
            }
            // The vault's software did not verify: alarming, unlike a list that could not be loaded.
            let level: NoticeKind = state.recoverOnly || error == .enclave ? .urgent : .warning
            NoticeCard(level, title: title, message: error.message(timeScale: state.timeScale))
                .accessibilityIdentifier("unlock_preflight_error")
        }
        if state.serviceWaitSeconds > 0 {
            Text(OnboardingStrings.unlockServiceWait(formatWait(state.serviceWaitSeconds)))
                .vettIDFont(.bodyMedium)
                .accessibilityIdentifier("unlock_service_wait")
        }
        if let p = state.preflight {
            PreflightNotices(preflight: p, state: state, actions: actions)
        }
        LockNoticeView(lock: state.lock, actions: actions)
        if state.refused && !state.notRecognised {
            NoticeCard(.warning, title: OnboardingStrings.unlockRefusedTitle, message: OnboardingStrings.unlockRefusedBody)
                .accessibilityIdentifier("unlock_refused")
        }
        if state.lockedByOwnerCheck {
            NoticeCard(.urgent, title: OnboardingStrings.unlockOwnerCheckLockedTitle, message: OnboardingStrings.unlockOwnerCheckLockedBody)
                .accessibilityIdentifier("unlock_owner_check_locked")
        } else if state.checkDue {
            NoticeCard(.info, title: OnboardingStrings.unlockOwnerCheckTitle, message: OnboardingStrings.unlockOwnerCheckBody)
                .accessibilityIdentifier("unlock_owner_check")
        }
        if let f = state.moveFailure {
            NoticeCard(.warning, title: OnboardingStrings.finishMoveTitle, message: f.message(timeScale: state.timeScale)) {
                TextLink(OnboardingStrings.continueLabel) { actions.dismissMoveFailure() }
            }
            .accessibilityIdentifier("unlock_move_failure")
        }
        if state.returnOffered, let m = state.moveUnconfirmed {
            // IOS-PLAN §4.3 point 3: above the keypad, at every start, until the marker is cleared.
            let (from, to) = (Int(m.from.number), Int(m.to.number))
            NoticeCard(
                .warning, title: OnboardingStrings.releaseUpdateNewFailedTitle(to),
                message: OnboardingStrings.unlockMoveUnconfirmed(to, from)
            ) {
                TextLink(OnboardingStrings.releaseUpdateReturn(from)) { actions.askReturn() }
            }
            .accessibilityIdentifier("unlock_move_unconfirmed")
        }
        if state.stateRollback {
            NoticeCard(.urgent, title: OnboardingStrings.unlockRollbackStateTitle, message: OnboardingStrings.unlockRollbackStateBody)
        }
        if state.recoveryPending { RecoveryPendingNotice(state: state, actions: actions) }
    }
}

/// The lock the member asked for, until the vault has confirmed it. These appear and change by themselves, so each is
/// announced to VoiceOver when it does.
struct LockNoticeView: View {
    let lock: LockNotice
    let actions: any UnlockActions
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        switch lock {
        // Nothing has failed yet: no warning, only that the lock is on its way.
        case .unconfirmed where !lock.inDoubt:
            Text(OnboardingStrings.unlockLockLocking)
                .vettIDFont(.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("unlock_lock_locking")
        case .unconfirmed:
            NoticeCard(.urgent, title: OnboardingStrings.unlockLockUnconfirmedTitle, message: OnboardingStrings.unlockLockUnconfirmedBody) {
                TextLink(OnboardingStrings.unlockLockTryAgain) { actions.retryLock() }
            }
            .accessibilityIdentifier("unlock_lock_unconfirmed")
        case .confirmedLate:
            NoticeCard(.success, title: OnboardingStrings.unlockLockConfirmed, message: "") {
                TextLink(OnboardingStrings.unlockLockOk) { actions.dismissLockNotice() }
            }
            .accessibilityIdentifier("unlock_lock_confirmed")
        // (Release L) The vault was opened again after this lock: not locked, and said so. This phone stays locked.
        case .openedAgain:
            NoticeCard(.urgent, title: OnboardingStrings.unlockLockOpenedAgainTitle, message: OnboardingStrings.unlockLockOpenedAgainBody) {
                // (Owner decision 2026-10-24) A fresh lock of the vault as it is now.
                TextLink(OnboardingStrings.unlockLockAgain) { actions.lockAgain() }
                    .accessibilityIdentifier("unlock_lock_again")
                TextLink(OnboardingStrings.unlockLockOk) { actions.dismissLockNotice() }
            }
            .accessibilityIdentifier("unlock_lock_opened_again")
        case .none:
            EmptyView()
        }
    }
}

/// A recovery is in progress (§11.11.4): cancel it and unlock; with a phone secret the password goes with it, for the
/// owner check that follows at once (release R).
struct RecoveryPendingNotice: View {
    let state: UnlockState
    let actions: any UnlockActions
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        NoticeCard(.urgent, title: OnboardingStrings.unlockRecoveryTitle, message: OnboardingStrings.unlockRecoveryBody) {
            Button { actions.cancelRecoveryAndUnlock() } label: {
                Text(OnboardingStrings.unlockRecoveryCancel).vettIDFont(.labelLarge).foregroundStyle(colors.error)
            }
            .buttonStyle(.plain)
            .frame(minHeight: Spacing.touchTarget)
            .disabled(!state.cancelAllowed)
            .accessibilityIdentifier("recovery_cancel")
        }
        .accessibilityIdentifier("recovery_pending")
        if state.phoneSecret {
            SecretField(
                OnboardingStrings.unlockPasswordLabel,
                text: Binding(get: { state.password }, set: { actions.setPassword($0) }),
                onSubmit: { actions.cancelRecoveryAndUnlock() }
            )
            .disabled(state.busy)
            .accessibilityIdentifier("unlock_cancel_password")
        }
    }
}

/// The failure of the last unlock under the PIN.
struct UnlockMessageNotice: View {
    let state: UnlockState

    var body: some View {
        switch state.message {
        case .moveBackFailed:
            NoticeCard(.urgent, title: OnboardingStrings.moveDidntFinish, message: OnboardingStrings.moveBackFailed)
                .accessibilityIdentifier("move_back_failed")
        case .updateRefused(let code):
            NoticeCard(.warning, title: OnboardingStrings.unlockTitle, message: OnboardingStrings.unlockUpdateRefused(code))
        // An unreadable result is the "not recognised" notice, with its erase action.
        case .failed(let kind, let code) where code != UnlockState.codeUnreadable || !state.notRecognised:
            let text = switch code {
            case UnlockState.codeUnreadable: OnboardingStrings.unlockUnreadable
            case UnlockAttempt.codeNoUserGuid: OnboardingStrings.unlockNoUserGuid
            // IOS-PLAN §4.3 point 6: still routed to the release the move left, never the rollback's text.
            case VaultManager.codeReleaseNotRouted:
                OnboardingStrings.releaseUpdateRoutePending(Int(state.moveUnconfirmed?.to.number ?? state.preflight?.lastNumber ?? 0))
            default: kind.message(timeScale: state.timeScale)
            }
            // The service paused for maintenance or not there yet: temporary, not alarming.
            let temporary = kind == .servicePaused || kind == .vaultUnavailable
            NoticeCard(temporary ? .warning : .urgent, title: OnboardingStrings.unlockTitle, message: text)
                .accessibilityIdentifier("unlock_failed")
        default:
            EmptyView()
        }
    }
}
#endif
