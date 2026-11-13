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
    /// With a check due, the PIN on the keypad first, then the password (``PinThenPassword``).
    @State private var steps = PinThenPassword()
    /// The screen's height, for whether the keypad stays fixed above "Unlock" (``PinThenPassword/keypadFixed(height:typeSize:)``).
    @State private var height: CGFloat = .infinity
    @Environment(\.dynamicTypeSize) private var typeSize
    /// VoiceOver's cursor: to the password on "Next", back to the keypad on "Edit PIN".
    @AccessibilityFocusState private var focus: PinThenPassword.Focus?
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

    /// Opened with [pin] typed and at [steps] (tests: the password step).
    init(state: UnlockState, actions: any UnlockActions, pin: PinBuffer, steps: PinThenPassword) {
        self.init(state: state, actions: actions)
        _pin = State(initialValue: pin)
        _steps = State(initialValue: steps)
    }

    private var blocked: Bool { state.recoverOnly }

    /// The check is due and the keypad shows: "Next" takes the PIN on to the password, in place of "Unlock".
    private var asksNext: Bool {
        state.checkDue && plainUnlock && !state.busy
            && steps.asksNext(asksPin: true, digits: pin.count, minPin: UnlockState.minPinLength)
    }

    /// The password step of a due check (the keypad has given way to it).
    private var passwordStep: Bool {
        state.checkDue && steps.passwordShown(asksPin: true, digits: pin.count, minPin: UnlockState.minPinLength)
    }

    /// The primary button is the plain "Unlock" (not a retry, a return or nothing).
    private var plainUnlock: Bool { basePrimaryLabel == OnboardingStrings.unlockSubmit }

    private var primaryLabel: String? { asksNext ? OnboardingStrings.pinStepNext : basePrimaryLabel }

    private var basePrimaryLabel: String? {
        if state.returnAsksPin, let m = state.moveUnconfirmed { return OnboardingStrings.releaseUpdateReturn(Int(m.from.number)) }
        if state.preflightError != nil && !blocked { return OnboardingStrings.unlockRetry }
        if blocked || state.recoveryPending { return nil }
        return OnboardingStrings.unlockSubmit
    }

    private var canSubmit: Bool { Self.canSubmit(state, digits: pin.count) }

    /// The PIN typed whole, and the password with a check due; a return to the previous release takes the PIN only (its
    /// keypad shows no password, even with a check due).
    /// The way back's notice says the check comes first instead of offering "Return to release N" (the vault refuses it
    /// while the check gates it).
    static func returnWaitsForCheck(_ state: UnlockState) -> Bool { state.returnOffered && state.returnGated }

    static func canSubmit(_ state: UnlockState, digits: Int) -> Bool {
        state.pinAllowed && digits >= UnlockState.minPinLength
            && (!state.checkDue || state.returnAsksPin || !state.password.isEmpty)
    }

    private func moveFocus(to target: PinThenPassword.Focus) {
        PinThenPassword.moveFocus({ focus = $0 }, to: target)
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
            primaryEnabled: asksNext ? state.pinAllowed && pin.count >= UnlockState.minPinLength
                : state.preflightError != nil && !state.returnAsksPin ? state.retryAllowed : canSubmit,
            busy: state.busy || state.loading || state.erasing,
            onPrimary: {
                if asksNext {
                    steps.pinDone = true
                    moveFocus(to: .password)
                } else if state.preflightError != nil && !state.returnAsksPin {
                    actions.retryPreflight()
                } else {
                    submit()
                }
            },
            header: {
                VettIDSymbol.lock.image.font(.system(size: 36)).padding(.top, Spacing.l).accessibilityHidden(true)
            },
            bottom: { if keypadFixed { keypad } }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(UnlockBlock.blocks(for: state), id: \.self) { block in
                    switch block {
                    case .notices: UnlockNotices(state: state, actions: actions)
                    case .pin:
                        pinEntry
                        UnlockMessageNotice(state: state)
                    case .offer:
                        if let p = state.preflight, let offer = p.offer {
                            ReleaseOfferNotice(preflight: p, offer: offer, state: state, actions: actions)
                        }
                    case .signerRefused:
                        SignerRefusedNotice(
                            help: state.signerHelp, recovery: state.recoveryText, stagingNote: state.stagingNote, actions: actions
                        )
                    case .returnCancel:
                        TextLink(OnboardingStrings.releaseUpdateNotNow, identifier: "unlock_return_cancel") { actions.cancelReturn() }
                    case .wayForward: wayForward
                    }
                }
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onDisappear { forgetSecrets() }
        // Digits taken by "Unlock" or dropped: the keypad again.
        .onChange(of: pin.count) { _, digits in steps.digitsChanged(to: digits) }
        // The way back's keypad closed ("Not now", or the check came due): its digits do not stay for the unlock.
        .onChange(of: state.returnAsksPin) { _, asks in if !asks { pin.clear() } }
        // The password typed goes with its step (back to the keypad, the PIN taken or dropped).
        .onChange(of: passwordStep) { _, shown in if !shown, !state.password.isEmpty { actions.setPassword("") } }
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

    /// The keypad stays above "Unlock", out of the scroll, so that no notice above it pushes its keys past the screen's
    /// edge; on a short screen or at an accessibility text size it scrolls with the rest instead (fixed, it would leave
    /// the notices no room).
    private var keypadFixed: Bool { PinThenPassword.keypadFixed(height: height, typeSize: typeSize) }

    /// The keypad; gone in the password step, wherever the screen asks for no PIN, and while the unlock is sent (its
    /// dimmed keys would crowd out the wait's text and be read by VoiceOver; it comes back with the answer).
    @ViewBuilder private var keypad: some View {
        if Self.keypadShown(state, passwordStep: passwordStep) {
            PinEntry(
                label: OnboardingStrings.unlockPinLabel,
                buffer: pin,
                error: state.message == .badPin && pin.count == 0 ? OnboardingStrings.unlockBadPin : nil,
                failure: state.message == .badPin ? OnboardingStrings.unlockBadPin : nil,
                identifier: "unlock_pin"
            )
            .disabled(!state.pinAllowed)
            .padding(.top, Spacing.s)
            .accessibilityFocused($focus, equals: .keypad)
        }
    }

    static func keypadShown(_ state: UnlockState, passwordStep: Bool) -> Bool {
        UnlockBlock.blocks(for: state).contains(.pin) && !passwordStep && !state.busy
    }

    /// The PIN's notices, the countdown and, with a check due, the password step (§3.6.5: one screen for both): the keypad
    /// first (``keypad``: above "Unlock", or here when ``keypadFixed`` is false), then in its place the PIN as dots and the
    /// password (``PinThenPassword``).
    @ViewBuilder private var pinEntry: some View {
        // VAULT-MESSAGING §11.14.9 "A lost answer" step 5: the previous PIN first, the new one after `device_secret`.
        switch state.pinStep {
        case .pin: EmptyView()
        case .previous:
            NoticeCard(.info, title: OnboardingStrings.unlockPreviousPinTitle, message: OnboardingStrings.unlockPreviousPinBody)
                .accessibilityIdentifier("unlock_previous_pin")
        case .new:
            NoticeCard(.success, title: OnboardingStrings.unlockNewPinTitle, message: OnboardingStrings.unlockNewPinBody, announce: .polite)
                .accessibilityIdentifier("unlock_new_pin")
        }
        if passwordStep {
            EnteredPin(label: OnboardingStrings.unlockPinLabel, digits: pin.count, identifier: "unlock_pin") {
                steps.pinDone = false
                moveFocus(to: .keypad)
            }
                .disabled(!state.pinAllowed)
                .padding(.top, Spacing.s)
        }
        if !keypadFixed { keypad }
        if state.waitSeconds > 0 {
            Text(OnboardingStrings.unlockWait(formatWait(state.waitSeconds)))
                .vettIDFont(.bodySmall)
                .frame(maxWidth: .infinity)
                // Said once when the wait starts, never at each tick.
                .accessibilityLabel(OnboardingStrings.unlockWait(spokenDuration(state.waitSeconds)))
                .announcedOnce(OnboardingStrings.unlockWait(spokenDuration(state.waitSeconds)))
                .accessibilityIdentifier("unlock_wait")
        }
        if passwordStep {
            SecretField(
                OnboardingStrings.unlockPasswordLabel,
                text: Binding(get: { state.password }, set: { actions.setPassword($0) }),
                focus: true,
                onSubmit: submit
            )
            .disabled(!state.pinAllowed)
            .accessibilityFocused($focus, equals: .password)
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

/// The unlock screen's blocks in the order they are shown, and read by VoiceOver: the PIN first, the results of the unlock
/// under it, the release offer (RELEASE-UPDATES §2 step 2) last, a compact notice. "Unlock" is the pinned button under all
/// of them. On a tall enough screen the keypad itself stays above "Unlock" (read after the blocks, the PIN's own notices
/// keeping their place); on a short one or at an accessibility text size it is in the PIN's place.
enum UnlockBlock: Hashable {
    case notices, pin, offer, signerRefused, returnCancel, wayForward

    static func blocks(for state: UnlockState) -> [UnlockBlock] {
        var out: [UnlockBlock] = [.notices]
        if state.showsPin { out.append(.pin) }
        if state.signerRefused { out.append(.signerRefused) }
        if state.returnAsksPin { out.append(.returnCancel) }
        out.append(.wayForward)
        // Last: after the PIN and every result of the unlock, as the Android app does.
        if let p = state.preflight, p.offer != nil, !p.rollback { out.append(.offer) }
        return out
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
        if state.busy, state.slowUnlock {
            // The unlock waits long for the vault: it may be starting (Android's text for the same wait of a recovery's
            // registration). The member may stop waiting.
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.m) {
                    ProgressView()
                    Text(RecoveryScreenStrings.recoverRegisteringStarting).vettIDFont(.bodyMedium)
                }
                .accessibilityElement(children: .combine)
                Button(MoveStrings.transferInCancel) { actions.cancelUnlock() }
                    .accessibilityIdentifier("unlock_cancel_wait")
            }
            .keepsScreenOn()
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
            NoticeCard(level, title: title, message: error.message(timeScale: state.timeScale), announce: .polite)
                .accessibilityIdentifier("unlock_preflight_error")
        }
        if state.serviceWaitSeconds > 0 {
            Text(OnboardingStrings.unlockServiceWait(formatWait(state.serviceWaitSeconds)))
                .vettIDFont(.bodyMedium)
                .accessibilityLabel(OnboardingStrings.unlockServiceWait(spokenDuration(state.serviceWaitSeconds)))
                .announcedOnce(OnboardingStrings.unlockServiceWait(spokenDuration(state.serviceWaitSeconds)))
                .accessibilityIdentifier("unlock_service_wait")
        }
        if let p = state.preflight {
            PreflightNotices(preflight: p, state: state, actions: actions)
        }
        LockNoticeView(lock: state.lock, actions: actions)
        if state.refused && !state.notRecognised {
            NoticeCard(
                .warning, title: OnboardingStrings.unlockRefusedTitle, message: OnboardingStrings.unlockRefusedBody,
                announce: .assertive
            )
                .accessibilityIdentifier("unlock_refused")
        }
        if state.lockedByOwnerCheck {
            NoticeCard(.urgent, title: OnboardingStrings.unlockOwnerCheckLockedTitle, message: OnboardingStrings.unlockOwnerCheckLockedBody)
                .accessibilityIdentifier("unlock_owner_check_locked")
        } else if let idle = state.idleLocked {
            // (Release L, §3.6.8; ANDROID-PLAN §4 "Locking the vault" part 2) It locked itself: why, then the unlock and the
            // check on this screen. The staging note where a scaled wait is shown.
            NoticeCard(
                .warning, title: OnboardingStrings.unlockIdleLockedTitle,
                message: OnboardingStrings.unlockIdleLocked(idle.afterSeconds) + (state.stagingNote.map { "\n\n" + $0 } ?? "")
            )
            .accessibilityIdentifier("unlock_idle_locked")
        } else if state.checkDue {
            NoticeCard(.info, title: OnboardingStrings.unlockOwnerCheckTitle, message: OnboardingStrings.unlockOwnerCheckBody)
                .accessibilityIdentifier("unlock_owner_check")
        }
        if let f = state.moveFailure {
            NoticeCard(
                .warning, title: OnboardingStrings.finishMoveTitle, message: f.message(timeScale: state.timeScale), announce: .polite
            ) {
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
                if UnlockScreen.returnWaitsForCheck(state) {
                    // The vault refuses the way back while the check gates it (as the update screen says): no PIN-only return.
                    Text(OnboardingStrings.releaseUpdateCheckFirstBody)
                        .vettIDFont(.bodyMedium)
                        .accessibilityIdentifier("unlock_return_check_first")
                } else {
                    TextLink(OnboardingStrings.releaseUpdateReturn(from)) { actions.askReturn() }
                }
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
/// announced to VoiceOver when it does (as vettid-android: the failures interrupt).
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
                .announced(OnboardingStrings.unlockLockLocking)
                .accessibilityIdentifier("unlock_lock_locking")
        case .unconfirmed:
            NoticeCard(
                .urgent, title: OnboardingStrings.unlockLockUnconfirmedTitle, message: OnboardingStrings.unlockLockUnconfirmedBody,
                announce: .assertive
            ) {
                TextLink(OnboardingStrings.unlockLockTryAgain) { actions.retryLock() }
            }
            .accessibilityIdentifier("unlock_lock_unconfirmed")
        case .confirmedLate:
            NoticeCard(.success, title: OnboardingStrings.unlockLockConfirmed, message: "", announce: .polite) {
                TextLink(OnboardingStrings.unlockLockOk) { actions.dismissLockNotice() }
            }
            .accessibilityIdentifier("unlock_lock_confirmed")
        // (Release L) The vault was opened again after this lock: not locked, and said so. This phone stays locked.
        case .openedAgain:
            NoticeCard(
                .warning, title: OnboardingStrings.unlockLockOpenedAgainTitle, message: OnboardingStrings.unlockLockOpenedAgainBody,
                announce: .assertive
            ) {
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
                    .textButtonTarget()
            }
            .buttonStyle(.plain)
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
            NoticeCard(.urgent, title: OnboardingStrings.moveDidntFinish, message: OnboardingStrings.moveBackFailed, announce: .assertive)
                .accessibilityIdentifier("move_back_failed")
        case .updateRefused(let code):
            NoticeCard(
                .warning, title: OnboardingStrings.unlockTitle, message: OnboardingStrings.unlockUpdateRefused(code),
                announce: .assertive
            )
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
            NoticeCard(temporary ? .warning : .urgent, title: OnboardingStrings.unlockTitle, message: text, announce: .assertive)
                .accessibilityIdentifier("unlock_failed")
        default:
            EmptyView()
        }
    }
}
#endif
