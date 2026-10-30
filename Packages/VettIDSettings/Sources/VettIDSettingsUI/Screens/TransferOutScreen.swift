#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboardingUI
import VettIDSettings
import VettIDUI

/// Settings → Security → Move to a new phone, the old phone's side (VAULT-MESSAGING §6.7.1): the code (QR and link) the
/// new phone scans, the safety code to compare, the change of signer if there is one, the PIN on the in-app keypad and the
/// credential password to approve, and the result. [onOpenRecovery]: "Recovery" under the first step (Recovery comes with
/// its own row of IOS-PLAN §8; nil hides the link). [onBack] leaves Settings' sub-screen. Mirrors vettid-android
/// `TransferOutContent`.
public struct TransferOutContent: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.scenePhase) private var scenePhase
    let state: TransferOutState
    let actions: any TransferOutActions
    let onOpenRecovery: (@MainActor () -> Void)?
    let onBack: @MainActor () -> Void
    @State private var pin = PinBuffer()
    @State private var copied = false

    public init(
        state: TransferOutState,
        actions: any TransferOutActions = NoTransferOutActions(),
        onOpenRecovery: (@MainActor () -> Void)? = nil,
        onBack: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.actions = actions
        self.onOpenRecovery = onOpenRecovery
        self.onBack = onBack
    }

    /// Leaving cancels the transfer if it is open, then goes back.
    private var leave: @MainActor () -> Void {
        let actions = actions
        let onBack = onBack
        return {
            actions.leave()
            onBack()
        }
    }

    /// The PIN and the password can be sent: a PIN typed, a password, no wait, not running.
    private var canApprove: Bool {
        pin.count >= TransferOutState.minPin && !state.password.isEmpty && state.waitSeconds == 0 && !state.busy
    }

    /// The PIN from the keypad goes to the model once, with the confirmation's question.
    private func askApprove() {
        guard canApprove else { return }
        actions.setPin(pin.take())
        actions.askApprove(true)
    }

    public var body: some View {
        // No identifier of its own: on `screen` it would land on the step's element and replace the step's identifier (UI
        // tests find each step by its own).
        screen
            .announcesStepChanges(of: state.step)
            .confirmDialog(
                isPresented: Binding(get: { state.confirmReject }, set: { if !$0 { actions.askReject(false) } }),
                title: TransferStrings.transferRejectTitle,
                message: TransferStrings.transferRejectBody,
                confirmLabel: TransferStrings.transferReject
            ) { actions.reject() }
            .confirmDialog(
                isPresented: Binding(get: { state.confirmApprove }, set: { if !$0 { actions.askApprove(false) } }),
                title: TransferStrings.transferApproveConfirmTitle(pendingName),
                message: TransferStrings.transferApproveConfirmBody,
                confirmLabel: TransferStrings.transferApproveConfirm,
                destructive: true
            ) { actions.approve() }
            .forgetsSecrets(scenePhase: scenePhase) {
                // IOS-PLAN §6.3: typed secrets are dropped when the screen goes, the app leaves the foreground, the iPhone locks.
                pin.clear()
                if state.step == .approve, !state.busy {
                    // The question over the keypad goes too, so that "Move" is not left asking about a PIN that is gone.
                    actions.askApprove(false)
                    actions.setPin("")
                    actions.setPassword("")
                }
            }
            // A new step starts with an empty keypad; the copied mark belongs to the code shown.
            .onChange(of: state.step) { _, _ in
                pin.clear()
                copied = false
            }
            .onChange(of: state.offer?.transferID) { _, _ in copied = false }
            // The approval's question was dismissed without "Move": the PIN handed over for it goes (not while the approval
            // runs, which has taken it already).
            .onChange(of: state.confirmApprove) { was, now in
                if was, !now, !state.busy, state.step == .approve { actions.setPin("") }
            }
    }

    @ViewBuilder private var screen: some View {
        switch state.step {
        case .intro: intro
        case .showing: showCode
        case .compare: compare
        case .signer: signer
        case .approve: approve
        case .expired:
            FormScaffold(
                title: TransferStrings.transferExpiredTitle, message: TransferStrings.transferExpiredBody,
                primaryLabel: TransferStrings.transferAgain, busy: state.busy, onPrimary: actions.create, onBack: leave
            ) { TransferError(state: state) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transfer_expired")
        case .rejected:
            FormScaffold(
                title: TransferStrings.transferRejectedTitle, message: TransferStrings.transferRejectedBody,
                primaryLabel: SettingsStrings.done, onPrimary: leave, onBack: leave
            ) { EmptyView() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transfer_rejected")
        case .moved: moved
        }
    }

    private var intro: some View {
        FormScaffold(
            title: TransferStrings.transferTitle, message: TransferStrings.transferBody, primaryLabel: TransferStrings.transferStart,
            busy: state.busy, secondaryLabel: onOpenRecovery == nil ? nil : TransferStrings.securityRecovery,
            onPrimary: actions.create, onSecondary: { onOpenRecovery?() }, onBack: leave
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                NoticeCard(.info, title: TransferStrings.transferStepsTitle, message: TransferStrings.transferStepsBody)
                OnSurfaceVariantText(TransferStrings.transferLost)
                TransferError(state: state)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_intro")
    }

    private var compare: some View {
        FormScaffold(
            title: TransferStrings.transferCompareTitle,
            message: TransferStrings.transferCompareBody(pendingName),
            primaryLabel: TransferStrings.transferMatch, busy: state.busy, secondaryLabel: TransferStrings.transferReject,
            onPrimary: actions.codesMatch, onSecondary: { actions.askReject(true) }, onBack: leave
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let pending = state.pending { SasBox(sas: pending.sas) }
                Window(secondsLeft: state.secondsLeft)
                TransferError(state: state)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_compare")
    }

    /// §6.7.1 step 2 (0.27.0), ANDROID-PLAN §7: the change of signer, named, before the PIN. Cancel rejects the transfer
    /// (after its own confirmation, as everywhere).
    private var signer: some View {
        FormScaffold(
            title: TransferStrings.transferSignerTitle, message: state.signerBody ?? "",
            primaryLabel: TransferStrings.transferSignerContinue, busy: state.busy, secondaryLabel: TransferStrings.transferSignerCancel,
            onPrimary: actions.confirmSigner, onSecondary: { actions.askReject(true) }, onBack: leave
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if state.signerUnconfirmed {
                    NoticeCard(.warning, title: TransferStrings.transferTitle, message: TransferStrings.transferSignerUnconfirmed)
                        .accessibilityIdentifier("transfer_signer_unconfirmed")
                }
                Window(secondsLeft: state.secondsLeft)
                TransferError(state: state)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_signer")
    }

    private var approve: some View {
        FormScaffold(
            title: TransferStrings.transferApproveTitle,
            message: TransferStrings.transferApproveBody(pendingName),
            primaryLabel: TransferStrings.transferApprove, primaryEnabled: canApprove, busy: state.busy, destructive: true,
            secondaryLabel: TransferStrings.transferReject, onPrimary: askApprove, onSecondary: { actions.askReject(true) },
            onBack: leave
        ) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                // The vault PIN on the in-app keypad (IOS-PLAN §6.5), handed over once, with the confirmation's question.
                PinEntry(
                    label: TransferStrings.transferPin, buffer: pin,
                    error: state.error == .badPin ? TransferStrings.transferBadPin : nil, identifier: "transfer_pin"
                )
                .disabled(state.waitSeconds > 0 || state.busy)
                if state.waitSeconds > 0 {
                    Text(TransferStrings.transferWait(Self.mmss(state.waitSeconds)))
                        .vettIDFont(.bodySmall)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .announcedOnce(TransferStrings.transferWait(Self.mmss(state.waitSeconds)))
                        .accessibilityIdentifier("transfer_wait")
                }
                SecretField(
                    TransferStrings.transferPassword, text: Binding(get: { state.password }, set: { actions.setPassword($0) }),
                    error: state.error == .badPassword ? TransferStrings.transferBadPassword : nil, errorPriority: .assertive,
                    onSubmit: askApprove
                )
                .disabled(state.waitSeconds > 0 || state.busy)
                .accessibilityIdentifier("transfer_password")
                Window(secondsLeft: state.secondsLeft)
                if state.error != .badPin, state.error != .badPassword { TransferError(state: state) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_approve")
    }

    private var moved: some View {
        FormScaffold(
            title: TransferStrings.transferMovedTitle,
            message: state.keptKeys
                ? TransferStrings.transferMovedKeptBody
                : TransferStrings.transferMovedBody(pendingName),
            primaryLabel: SettingsStrings.done, onPrimary: leave, onBack: leave
        ) {
            if state.keptKeys { SmallNote(state.stagingNote) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_moved")
    }

    private var showCode: some View {
        FormScaffold(
            title: TransferStrings.transferShowTitle, message: TransferStrings.transferShowBody, primaryLabel: nil,
            secondaryLabel: TransferStrings.transferCancel, onPrimary: {}, onSecondary: leave, onBack: leave
        ) {
            if let offer = state.offer {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    CaptureProtected { QrCode(offer.qrPayload, accessibilityLabel: TransferStrings.transferQrCd) }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("transfer_qr")
                    Text(TransferStrings.transferExpires(Self.mmss(state.secondsLeft)))
                        .vettIDFont(.bodyMedium)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("transfer_expires")
                    WaitingRow(text: TransferStrings.transferWaiting, identifier: "waiting_new_phone")
                    Text(TransferStrings.transferLinkLabel).vettIDFont(.labelLarge).padding(.top, Spacing.s)
                    CaptureProtected {
                        Text(verbatim: offer.link)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(Self.linkLines)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.m)
                            .background(colors.surfaceContainer, in: VettIDShape.card)
                    }
                    .accessibilityIdentifier("transfer_link")
                    copyButton(offer.link)
                    TransferError(state: state)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer_showing")
    }

    private func copyButton(_ link: String) -> some View {
        Button {
            // Local to this iPhone (never on Universal Clipboard), and gone when the code expires, at most after 5 minutes
            // (IOS-PLAN §6.5; chosen; not in the spec).
            SecurePasteboard.copy(link, lifetime: Self.clipboardLifetime(secondsLeft: state.secondsLeft))
            copied = true
        } label: {
            CopyLabel(text: copied ? TransferStrings.transferCopied : TransferStrings.transferCopy)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transfer_copy")
    }
}

extension TransferOutContent {
    /// The new phone's name as it sits in a sentence, cleaned and bidi-isolated (VAULT-MESSAGING §10.8; mirrors
    /// vettid-android #220); "The other phone" when nothing is left of it.
    static func pendingName(_ name: String?) -> String { AccountNames.isolateOrNull(name) ?? TransferStrings.transferUnnamedDevice }

    var pendingName: String { Self.pendingName(state.pending?.name) }

    /// The lines the pasted link shows (vettid-android `LINK_LINES`).
    static let linkLines = 3

    /// `m:ss`.
    static func mmss(_ seconds: Int64) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    /// How long a copied code stays on the pasteboard: until it expires, 5 minutes at most.
    static func clipboardLifetime(secondsLeft: Int64) -> TimeInterval { TimeInterval(max(0, min(secondsLeft, 300))) }
}

/// "5:00 left to approve".
private struct Window: View {
    let secondsLeft: Int64

    var body: some View {
        Text(TransferStrings.transferWindow(TransferOutContent.mmss(secondsLeft)))
            .vettIDFont(.bodyMedium)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("transfer_window")
    }
}

private struct OnSurfaceVariantText: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
    }
}

private struct CopyLabel: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            VettIDSymbol.contentCopy.image.font(.system(size: 16))
            Text(text).vettIDFont(.labelLarge)
        }
        .foregroundStyle(colors.onSurface)
        .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget)
        .overlay(VettIDShape.pill.stroke(colors.outline))
    }
}

/// The failure of the last action: the open-clone alarm and "another transfer is open" have their own words.
struct TransferError: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: TransferOutState

    var body: some View {
        if let kind = state.error {
            NoticeCard(
                .urgent, title: kind.title(or: TransferStrings.transferTitle), message: Self.text(kind, state.errorCode, timeScale),
                announce: .assertive
            )
                .padding(.top, Spacing.l)
                .accessibilityIdentifier("transfer_error")
        }
    }

    static func text(_ kind: FailureKind, _ code: String?, _ timeScale: UInt64) -> String {
        if code == "exists" { return TransferStrings.transferExists }
        if kind == .credentialFrozen || kind == .rotationRequired { return TransferStrings.transferAlarm }
        return kind.message(timeScale: timeScale)
    }
}

/// Settings → Security → Move to a new phone with its view model, made when it first appears. The model is owned here and
/// the transfer is left (a code still open is cancelled at the vault) when the screen goes, whatever took it away: back, the
/// system gesture, a wipe after the approval. Mirrors vettid-android's `TransferOutRoute` destination.
public struct TransferOutRoute: View {
    private let move: any MoveRepository
    private let vault: any VaultRepository
    private let onOpenRecovery: (@MainActor () -> Void)?
    private let onBack: @MainActor () -> Void
    @State private var model: TransferOutViewModel?

    public init(
        move: any MoveRepository, vault: any VaultRepository, onOpenRecovery: (@MainActor () -> Void)? = nil,
        onBack: @escaping @MainActor () -> Void
    ) {
        self.init(move: move, vault: vault, onOpenRecovery: onOpenRecovery, onBack: onBack, model: nil)
    }

    /// TEST ONLY: [model] is the route's own from the start (a transfer already open).
    init(
        move: any MoveRepository, vault: any VaultRepository, onOpenRecovery: (@MainActor () -> Void)?,
        onBack: @escaping @MainActor () -> Void, model: TransferOutViewModel?
    ) {
        self.move = move
        self.vault = vault
        self.onOpenRecovery = onOpenRecovery
        self.onBack = onBack
        _model = State(initialValue: model)
    }

    public var body: some View {
        TransferOutContent(
            state: model?.state ?? TransferOutState(), actions: model ?? NoTransferOutActions(), onOpenRecovery: onOpenRecovery,
            onBack: onBack
        )
        .onAppear { if model == nil { model = TransferOutViewModel(move: move, vault: vault) } }
        .onDisappear { if let model, Self.leaves(model.state) { model.leave() } }
    }

    /// Whether the screen going away leaves the transfer (cancels the open code). Not while the approval is in flight: it is
    /// on its way to the vault, and a reject sent after it would race it (vettid-android leaves only from its back actions;
    /// chosen; not in the spec).
    static func leaves(_ state: TransferOutState) -> Bool { !(state.step == .approve && state.busy) }
}
#endif
