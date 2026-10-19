#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The owner-check screen for [mode], driven by an ``OwnerCheckViewModel`` made when it first appears. [onDone] after a
/// passed check; [onCancel] for a voluntary check and the hold-off only (a gated check is never dismissible, §3.6.5).
/// Mirrors vettid-android `OwnerCheckRoute`.
public struct OwnerCheckFlow: View {
    private let mode: OwnerCheckMode
    private let repo: any OwnerCheckRepository
    private let vault: any VaultRepository
    private let onDone: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    @State private var model: OwnerCheckViewModel?
    @Environment(\.vettIDColors) private var colors

    public init(
        mode: OwnerCheckMode,
        repo: any OwnerCheckRepository,
        vault: any VaultRepository,
        onDone: @escaping @MainActor () -> Void = {},
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        self.mode = mode
        self.repo = repo
        self.vault = vault
        self.onDone = onDone
        self.onCancel = onCancel
    }

    public var body: some View {
        Group {
            if let model {
                OwnerCheckScreen(state: model.state, actions: model, onCancel: {
                    model.cancel()
                    onCancel()
                })
                .onChange(of: model.state.passed) { _, passed in
                    guard passed else { return }
                    // Nothing of this check stays for the next one.
                    model.cancel()
                    onDone()
                }
            } else {
                colors.background.color.ignoresSafeArea()
            }
        }
        .onAppear {
            guard model == nil else { return }
            let m = OwnerCheckViewModel(repo: repo, vault: vault)
            m.start(mode)
            model = m
        }
    }
}

/// The owner-check screen for [state] (stateless): the PIN on the in-app keypad (IOS-PLAN §6.5) and the credential
/// password, sent together; which entry was wrong, the checks left, a running backoff; while gated, what waits in the
/// vault and the lock action (the held screen); for the hold-off, its warning and how long. Mirrors vettid-android
/// `OwnerCheckContent`.
public struct OwnerCheckScreen: View {
    let state: OwnerCheckScreenState
    let actions: any OwnerCheckActions
    let onCancel: @MainActor () -> Void
    let now: Date
    @State private var pin = PinBuffer()
    @Environment(\.scenePhase) private var scenePhase

    /// Fewer checks than this left are shown in the error colour.
    static let warnLeft = 3

    public init(
        state: OwnerCheckScreenState, actions: any OwnerCheckActions, onCancel: @escaping @MainActor () -> Void = {}, now: Date = Date()
    ) {
        self.state = state
        self.actions = actions
        self.onCancel = onCancel
        self.now = now
    }

    /// The interval at the vault's time scale (STAGING-TIME-SCALE §5.2): "24 hours", on staging "1 hour".
    private var interval: String { state.intervalText }

    private var title: String {
        switch state.mode {
        case .gated: OnboardingStrings.ownerCheckTitleGated
        case .voluntary: OnboardingStrings.ownerCheckTitleVoluntary
        case .holdOff: OnboardingStrings.ownerCheckTitleHoldOff
        }
    }

    private var body0: String {
        switch state.mode {
        case .gated: OnboardingStrings.ownerCheckBodyGated(interval)
        case .voluntary: OnboardingStrings.ownerCheckBodyVoluntary(interval)
        case .holdOff: OnboardingStrings.ownerCheckBodyHoldOff
        }
    }

    private var badPin: Bool {
        if case .badPin? = state.message { true } else { false }
    }

    private var badPassword: Bool {
        if case .badPassword? = state.message { true } else { false }
    }

    private var canSubmit: Bool {
        state.entriesAllowed && pin.count >= OwnerCheckScreenState.minPin && !state.password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        actions.setPin(pin.take())
        actions.submit()
    }

    public var body: some View {
        if state.passedUnrecorded {
            FormScaffold(title: title, primaryLabel: OnboardingStrings.continueLabel, onPrimary: { actions.acknowledgePresence() }) {
                PresenceNotice(scaledQuiet: state.scaledQuietText)
                SmallNote(state.stagingNote)
            }
            .accessibilityIdentifier("owner_check_passed_unrecorded")
        } else {
            form
        }
    }

    private var form: some View {
        FormScaffold(
            title: title,
            message: body0,
            primaryLabel: state.mode == .holdOff ? OnboardingStrings.ownerCheckSubmitHoldOff : OnboardingStrings.ownerCheckSubmit,
            primaryEnabled: canSubmit,
            busy: state.busy || state.locking,
            secondaryLabel: state.mode == .gated ? OnboardingStrings.ownerCheckLock : OnboardingStrings.ownerCheckCancel,
            onPrimary: submit,
            onSecondary: {
                pin.clear()
                if state.mode == .gated { actions.lockVault() } else { onCancel() }
            },
            header: {
                VettIDSymbol.verifiedUser.image.font(.system(size: 36)).padding(.top, Spacing.l).accessibilityHidden(true)
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SmallNote(state.stagingNote)
                if state.presenceUnrecorded { PresenceNotice(scaledQuiet: state.scaledQuietText) }
                if let card = WaitingCardModel.of(state.mode, state.view, now: now) { WaitingCard(model: card) }
                if state.mode == .holdOff {
                    NoticeCard(
                        .warning,
                        title: OnboardingStrings.ownerCheckHoldOffWarningTitle,
                        message: OnboardingStrings.ownerCheckHoldOffWarning
                    )
                    .accessibilityIdentifier("hold_off_warning")
                    HoldOffChoices(selected: state.holdOff) { actions.setHoldOff($0) }
                }
                entries
                OwnerCheckMessageView(state: state, title: title)
            }
        }
        .onDisappear { forgetSecrets() }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
            if now == .background { forgetSecrets() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            forgetSecrets()
        }
        .accessibilityIdentifier("owner_check")
    }

    /// The keypad and the password (§3.6.5: one screen for both).
    @ViewBuilder private var entries: some View {
        PinEntry(
            label: OnboardingStrings.ownerCheckPinLabel,
            buffer: pin,
            error: badPin && pin.count == 0 ? OnboardingStrings.ownerCheckBadPin : nil,
            identifier: "owner_check_pin"
        )
        .disabled(!state.entriesAllowed)
        .padding(.top, Spacing.s)
        SecretField(
            OnboardingStrings.ownerCheckPasswordLabel,
            text: Binding(get: { state.password }, set: { actions.setPassword($0) }),
            error: badPassword ? OnboardingStrings.ownerCheckBadPassword : nil,
            onSubmit: submit
        )
        .disabled(!state.entriesAllowed)
        .accessibilityIdentifier("owner_check_password")
    }

    private func forgetSecrets() {
        pin.clear()
        actions.forgetSecrets()
    }
}

/// The checks left, a running backoff, or a failure.
struct OwnerCheckMessageView: View {
    let state: OwnerCheckScreenState
    let title: String
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        if let left = state.checksLeft {
            Text(OnboardingStrings.ownerCheckChecksLeft(left))
                .vettIDFont(.bodyMedium)
                .foregroundStyle(left <= OwnerCheckScreen.warnLeft ? colors.error : colors.onSurfaceVariant)
                .accessibilityIdentifier("owner_check_left")
        }
        if state.waitSeconds > 0 {
            Text(OnboardingStrings.ownerCheckBackoffWait(formatWait(state.waitSeconds)))
                .vettIDFont(.bodyMedium)
                .accessibilityIdentifier("owner_check_wait")
        } else if state.message == .backoff {
            Text(OnboardingStrings.ownerCheckBackoff).vettIDFont(.bodyMedium)
        } else if case .failed(let kind, _)? = state.message {
            NoticeCard(.urgent, title: title, message: kind.message(timeScale: state.timeScale))
                .accessibilityIdentifier("owner_check_failed")
        }
    }
}

/// ANDROID-PLAN "Owner check and status" (release R): the vault could not record that the member was here.
struct PresenceNotice: View {
    /// The recovery quiet period on a scaled vault ("3 hours" on staging); nil in real time, where the text says the
    /// approved "three days".
    let scaledQuiet: String?

    static func body(_ scaledQuiet: String?) -> String {
        scaledQuiet.map(OnboardingStrings.ownerCheckPresenceBodyScaled) ?? OnboardingStrings.ownerCheckPresenceBody
    }

    var body: some View {
        NoticeCard(.warning, title: OnboardingStrings.ownerCheckPresenceTitle, message: Self.body(scaledQuiet))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("owner_check_presence")
    }
}

/// `vault.held`'s counts (§3.6.5: "3 new messages waiting"): no names, no content; or that they are not known yet.
struct WaitingCard: View {
    let model: WaitingCardModel

    static func text(_ m: WaitingCardModel) -> String {
        let counts: String
        if let w = m.counts {
            var lines: [String] = []
            if w.messages > 0 { lines.append(OnboardingStrings.ownerCheckWaitingMessages(w.messages)) }
            if w.requests > 0 { lines.append(OnboardingStrings.ownerCheckWaitingRequests(w.requests)) }
            if w.calls > 0 { lines.append(OnboardingStrings.ownerCheckWaitingCalls(w.calls)) }
            if w.other > 0 { lines.append(OnboardingStrings.ownerCheckWaitingOther(w.other)) }
            counts = lines.isEmpty ? OnboardingStrings.ownerCheckWaitingNone : lines.joined(separator: "\n")
        } else {
            counts = OnboardingStrings.ownerCheckWaitingUnknown
        }
        guard let held = m.held else { return counts }
        return counts + "\n\n" + (held ? OnboardingStrings.ownerCheckHeldNote : OnboardingStrings.ownerCheckDueNote)
    }

    var body: some View {
        NoticeCard(.info, title: OnboardingStrings.ownerCheckWaitingTitle, message: Self.text(model))
            .accessibilityIdentifier("owner_check_waiting")
    }
}

/// How long the hold stays off: one choice of five.
struct HoldOffChoices: View {
    let selected: HoldOffChoice
    let onPick: @MainActor (HoldOffChoice) -> Void
    @Environment(\.vettIDColors) private var colors

    static func label(_ c: HoldOffChoice) -> String {
        switch c {
        case .untilTurnedOn: OnboardingStrings.ownerCheckHoldOffNever
        case .oneDay: OnboardingStrings.ownerCheckHoldOff1d
        case .threeDays: OnboardingStrings.ownerCheckHoldOff3d
        case .oneWeek: OnboardingStrings.ownerCheckHoldOff1w
        case .thirtyDays: OnboardingStrings.ownerCheckHoldOff30d
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(OnboardingStrings.ownerCheckHoldOffUntil).vettIDFont(.titleSmall).accessibilityAddTraits(.isHeader)
            ForEach(HoldOffChoice.allCases, id: \.self) { c in
                Button { onPick(c) } label: {
                    HStack(spacing: Spacing.m) {
                        (c == selected ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                            .foregroundStyle(c == selected ? colors.primary : colors.onSurfaceVariant)
                        Text(Self.label(c)).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurface)
                        Spacer()
                    }
                    .frame(minHeight: Spacing.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(c == selected ? [.isSelected] : [])
                .accessibilityIdentifier("hold_off_\(c)")
            }
        }
    }
}

/// The app lock's screen (ANDROID-PLAN D6): shown instead of the app while it is locked. "Unlock" asks iOS for Face ID,
/// Touch ID or the passcode ([passcodeOnly]: the passcode); [lockedOut]: Face ID or Touch ID is locked after too many
/// attempts, and the member unlocks the iPhone with its passcode first. Mirrors vettid-android `AppLockScreen`.
public struct AppLockScreen: View {
    let passcodeOnly: Bool
    let lockedOut: Bool
    let onUnlock: @MainActor () -> Void

    public init(passcodeOnly: Bool, lockedOut: Bool = false, onUnlock: @escaping @MainActor () -> Void) {
        self.passcodeOnly = passcodeOnly
        self.lockedOut = lockedOut
        self.onUnlock = onUnlock
    }

    public var body: some View {
        FormScaffold(
            title: OnboardingStrings.appLockTitle,
            message: passcodeOnly ? OnboardingStrings.appLockBodyPasscode : OnboardingStrings.appLockBody,
            primaryLabel: OnboardingStrings.appLockUnlock,
            onPrimary: onUnlock,
            header: { VettIDSymbol.lock.image.font(.system(size: 36)).padding(.top, Spacing.l).accessibilityHidden(true) }
        ) {
            if lockedOut {
                NoticeCard(.warning, title: OnboardingStrings.appLockTitle, message: OnboardingStrings.appLockLockedOut)
                    .accessibilityIdentifier("app_lock_locked_out")
            }
        }
        .accessibilityIdentifier("app_lock_screen")
    }
}
#endif
