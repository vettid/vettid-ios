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
        // §6.7.1: nothing to send from a phone that can never unlock.
        if blocked || state.recoveryPending || state.noUserGuid { return nil }
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
                ForEach(UnlockBlock.blocks(for: state), id: \.self) { block in
                    switch block {
                    case .notices:
                        UnlockNotices(state: state, actions: actions, pinTyped: pin.count) {
                            Self.cancelRecovery(state, pin, actions)
                        }
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
                    case .wayForward:
                        // Without the PIN block (a phone with no usable user_guid), a failed erase's message shows here.
                        if Self.messageAboveWayForward(state) { UnlockMessageNotice(state: state) }
                        UnlockWayForward(
                            state: state, actions: actions, pinReady: pin.count >= UnlockState.minPinLength,
                            onRecover: onOpenAccountSite, contactSupport: contactSupport,
                            onEarlierSecret: {
                                actions.setPin(pin.take())
                                actions.submitEarlierSecret()
                            }
                        )
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
            NoticeCard(.success, title: OnboardingStrings.unlockNewPinTitle, message: OnboardingStrings.unlockNewPinBody, announce: .polite)
                .accessibilityIdentifier("unlock_new_pin")
        }
        PinEntry(
            label: OnboardingStrings.unlockPinLabel,
            buffer: pin,
            error: state.message == .badPin && pin.count == 0 ? OnboardingStrings.unlockBadPin : nil,
            failure: state.message == .badPin ? OnboardingStrings.unlockBadPin : nil,
            identifier: "unlock_pin"
        )
        .disabled(!state.pinAllowed)
        .padding(.top, Spacing.s)
        UnlockWaitLine(state: state)
        // While a recovery is pending its notice has the password field (the cancel's), not this one.
        if state.checkDue && !state.recoveryPending {
            SecretField(
                OnboardingStrings.unlockPasswordLabel,
                text: Binding(get: { state.password }, set: { actions.setPassword($0) }),
                onSubmit: submit
            )
            .disabled(!state.pinAllowed)
            .accessibilityIdentifier("unlock_password")
        }
    }

    /// "Cancel the recovery and unlock": when the cancel needs a PIN typed (``UnlockState/cancelPinNeeded``), the keypad's
    /// goes with it; otherwise the PIN kept from the `recovery_pending` answer does, and the keypad's is not taken.
    static func cancelRecovery(_ state: UnlockState, _ pin: PinBuffer, _ actions: any UnlockActions) {
        if state.cancelPinNeeded { actions.setPin(pin.take()) }
        actions.cancelRecoveryAndUnlock()
    }

    /// The way forward under the unlock's results, one at most.
    enum WayForward: Equatable {
        /// [recoverBesideMove]: the move card of a "Finish the move" refused `no_user_guid` says the words; after a failed
        /// check, "Recover your vault" comes beside it (no erase).
        case recoverOnly, notRecognised, stuckWords, recoverBesideMove, stuck, none

        /// "Recover your vault" is offered (on a phone with no usable `user_guid`, also after a failed check: owner decision
        /// a, 2026-11-19). The erase only where ``UnlockState/eraseOffered``.
        var offersRecover: Bool { self != .notRecognised && self != .none }
    }

    /// The unlock's message (a failed erase's, ``UnlockViewModel/confirmErase()``) is shown above the way forward wherever
    /// there is no PIN block to show it under (a phone with no usable `user_guid`, a recovery pending, a failed check).
    static func messageAboveWayForward(_ state: UnlockState) -> Bool { !state.showsPin }

    /// An ended release or a rollback wins: no erase there, whatever else the last answers said. On a phone with no usable
    /// `user_guid` whose release check failed, the stuck words alone (§6.7.1, as vettid-android #412).
    static func wayForward(_ state: UnlockState) -> WayForward {
        if state.recoverOnly { return .recoverOnly }
        // Its erase only where it is offered (a phone with no usable user_guid: after a check that answered).
        if state.notRecognised, state.eraseOffered { return .notRecognised }
        if state.stuckWordsOnly { return .stuckWords }
        if state.noUserGuid, state.moveNoUserGuid, !state.loading, !state.eraseOffered { return .recoverBesideMove }
        if state.stuckNoticeShown { return .stuck }
        return .none
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

/// The unlock screen's blocks in the order they are shown, and read by VoiceOver: the PIN keypad first, the results of the
/// unlock under it, the release offer (RELEASE-UPDATES §2 step 2) last, a compact notice. "Unlock" is the pinned button
/// under all of them.
enum UnlockBlock: Hashable {
    case notices, pin, offer, signerRefused, returnCancel, wayForward

    static func blocks(for state: UnlockState) -> [UnlockBlock] {
        var out: [UnlockBlock] = [.notices]
        if state.showsPin { out.append(.pin) }
        if state.signerRefused { out.append(.signerRefused) }
        if state.returnAsksPin { out.append(.returnCancel) }
        out.append(.wayForward)
        // Last: after the PIN and every result of the unlock, as the Android app does.
        // Not on a phone that can never unlock (§6.7.1): no approval can go with an unlock.
        if let p = state.preflight, p.offer != nil, !p.rollback, !state.noUserGuid { out.append(.offer) }
        return out
    }
}

/// The notices above the PIN: the release check, the lock, the refusals, the owner check, a move, a rollback, a recovery.
struct UnlockNotices: View {
    let state: UnlockState
    let actions: any UnlockActions
    /// The digits typed on the keypad, and the cancel of a pending recovery (which hands them over when it needs them).
    var pinTyped = 0
    var cancelRecovery: (@MainActor () -> Void)?

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
        } else if state.checkDue && !state.noUserGuid {
            NoticeCard(.info, title: OnboardingStrings.unlockOwnerCheckTitle, message: OnboardingStrings.unlockOwnerCheckBody)
                .accessibilityIdentifier("unlock_owner_check")
        }
        if let card = UnlockMoveCard(state) {
            NoticeCard(card.kind, title: card.title, message: card.message, announce: .polite) {
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
        if state.recoveryPending {
            RecoveryPendingNotice(state: state, actions: actions, pinTyped: pinTyped, cancel: cancelRecovery)
        }
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
    var pinTyped = 0
    var cancel: (@MainActor () -> Void)?
    @Environment(\.vettIDColors) private var colors

    /// Only when the button would be enabled: the return key of the password field too.
    private func cancelNow() {
        guard state.cancelAllowed(pinTyped: pinTyped) else { return }
        if let cancel { cancel() } else { actions.cancelRecoveryAndUnlock() }
    }

    var body: some View {
        NoticeCard(.urgent, title: OnboardingStrings.unlockRecoveryTitle, message: OnboardingStrings.unlockRecoveryBody) {
            Button { cancelNow() } label: {
                Text(OnboardingStrings.unlockRecoveryCancel).vettIDFont(.labelLarge).foregroundStyle(colors.error)
                    .textButtonTarget()
            }
            .buttonStyle(.plain)
            .disabled(!state.cancelAllowed(pinTyped: pinTyped))
            .accessibilityIdentifier("recovery_cancel")
        }
        .accessibilityIdentifier("recovery_pending")
        if state.cancelPasswordNeeded {
            SecretField(
                OnboardingStrings.unlockPasswordLabel,
                text: Binding(get: { state.password }, set: { actions.setPassword($0) }),
                onSubmit: { cancelNow() }
            )
            .disabled(state.busy)
            .accessibilityIdentifier("unlock_cancel_password")
        }
    }
}

/// The card of the last "Finish the move" that did not open the vault (release R, §11.14.10), with its Continue; nil when
/// none is shown. It locked the vault and its unlock failed, or, with no usable user_guid on this phone, it locked nothing
/// and sent nothing: then the recover-or-erase notice's words, with no erase of its own, never "does not support this
/// yet". That card is not shown beside the recover-or-erase notice, which says the same (on such a phone, from the
/// screen's opening), nor beside the recover-only notice of an ended release or a rollback, which offers no erase and is
/// the way forward there. Mirrors vettid-android #408.
struct UnlockMoveCard: Equatable {
    let kind: NoticeKind
    let title: String
    let message: String

    init?(_ state: UnlockState) {
        guard let f = state.moveFailure, !(state.moveNoUserGuid && (state.stuckNoticeShown || state.recoverOnly)) else {
            return nil
        }
        if f.noUserGuid {
            (kind, title, message) = (.urgent, OnboardingStrings.unlockStuckTitle, OnboardingStrings.unlockStuckBody)
        } else {
            (kind, title, message) = (.warning, OnboardingStrings.finishMoveTitle, f.kind.message(timeScale: state.timeScale))
        }
    }
}

/// The failure of the last unlock under the PIN.
struct UnlockMessageNotice: View {
    let state: UnlockState

    /// A `no_user_guid` refusal's own card (the recover-or-erase words, no actions) is shown only where neither the
    /// recover-or-erase notice nor the not-recognised one (both offer the erase) is, nor the recover-only notice, nor the
    /// move card of the same failure.
    static func noUserGuidShown(_ state: UnlockState) -> Bool {
        !state.eraseOffered && !state.recoverOnly && !state.moveNoUserGuid
    }

    /// The card of a failed unlock; nil where another notice says it.
    static func failedCard(_ state: UnlockState) -> NoticeContent? {
        guard case .failed(let kind, let code) = state.message else { return nil }
        // No usable user_guid (§6.7.1): the recover-or-erase notice says it; where it is not shown, its words alone, with no
        // actions (owner decision a, 2026-11-18). Never "does not support this yet".
        if UnlockAttempt.isNoUserGuid(kind, code) {
            guard noUserGuidShown(state) else { return nil }
            return NoticeContent(
                kind: .urgent, title: OnboardingStrings.unlockStuckTitle, message: OnboardingStrings.unlockStuckBody,
                identifier: "unlock_no_user_guid"
            )
        }
        // An unreadable result is the "not recognised" notice, with its erase action.
        if code == UnlockState.codeUnreadable && state.notRecognised { return nil }
        let text = switch code {
        case UnlockState.codeUnreadable: OnboardingStrings.unlockUnreadable
        // IOS-PLAN §4.3 point 6: still routed to the release the move left, never the rollback's text.
        case VaultManager.codeReleaseNotRouted:
            OnboardingStrings.releaseUpdateRoutePending(Int(state.moveUnconfirmed?.to.number ?? state.preflight?.lastNumber ?? 0))
        default: kind.message(timeScale: state.timeScale)
        }
        // The service paused for maintenance or not there yet: temporary, not alarming.
        let temporary = kind == .servicePaused || kind == .vaultUnavailable
        return NoticeContent(
            kind: temporary ? .warning : .urgent, title: OnboardingStrings.unlockTitle, message: text, identifier: "unlock_failed"
        )
    }

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
        case .failed:
            if let c = Self.failedCard(state) {
                NoticeCard(c.kind, title: c.title, message: c.message, announce: .assertive).accessibilityIdentifier(c.identifier)
            }
        case .badPin where !state.showsPin:
            // A wrong PIN with no PIN block to say it (cancelling a recovery and unlocking): its card, above the way forward.
            NoticeCard(.urgent, title: OnboardingStrings.unlockTitle, message: OnboardingStrings.unlockBadPin, announce: .assertive)
                .accessibilityIdentifier("unlock_bad_pin")
        default:
            EmptyView()
        }
    }
}
#endif

/// The PIN block's backoff countdown (a wrong PIN, on the unlock or on the cancel of a recovery); nothing without a wait.
struct UnlockWaitLine: View {
    let state: UnlockState

    var body: some View {
        if state.waitSeconds > 0 {
            Text(OnboardingStrings.unlockWait(formatWait(state.waitSeconds)))
                .vettIDFont(.bodySmall)
                .frame(maxWidth: .infinity)
                // Said once when the wait starts, never at each tick.
                .accessibilityLabel(OnboardingStrings.unlockWait(spokenDuration(state.waitSeconds)))
                .announcedOnce(OnboardingStrings.unlockWait(spokenDuration(state.waitSeconds)))
                .accessibilityIdentifier("unlock_wait")
        }
    }
}
