#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

/// What the pairing screens do. Mirrors vettid-android `PairActions`.
public struct PairActions {
    public var onBack: @MainActor () -> Void = {}
    public var onNewCode: @MainActor () -> Void = {}
    public var onCopied: @MainActor () -> Void = {}
    public var onCancel: @MainActor () -> Void = {}
    /// **The codes match**, for the comparison shown (its pairing id).
    public var onCodesMatch: @MainActor (String) -> Void = { _ in }
    public var onCloseSheet: @MainActor () -> Void = {}
    public var onChoose: @MainActor (SessionChoice) -> Void = { _ in }
    public var onPair: @MainActor () -> Void = {}
    /// **They don't match**, and Reject, for the comparison shown (its pairing id).
    public var onReject: @MainActor (String) -> Void = { _ in }
    public var onDone: @MainActor () -> Void = {}
    /// **Open its page**: the new agent's page, when its id is known.
    public var onOpenPage: @MainActor (String) -> Void = { _ in }
    /// The daily owner check (a refused pairing request says it is due).
    public var onOwnerCheck: @MainActor () -> Void = {}

    public init() {}
}

/// Pairing an agent (ANDROID-PLAN 0.1.53 AA2) or a desktop (owner decision 2026-11-05): the code (QR and text, Copy, Share, its
/// countdown), the comparison of the six digits with the device's, the choice of first access, and the end of it. The words of each step
/// are ``PairTexts``'. The code, its QR and the digits are kept out of captures for the whole flow (the code is a bearer secret for 10
/// minutes, decision 1). Mirrors vettid-android `PairScreen`.
public struct PairScreen: View {
    let state: PairState
    let actions: PairActions

    public init(state: PairState, actions: PairActions) {
        self.state = state
        self.actions = actions
    }

    private var desktop: Bool { state.pairing.role == .desktop }
    private var step: PairStep { PairTexts.step(state) }

    /// The code is on the screen (or on its way): anything else ends its use.
    private var codeInUse: Bool {
        switch state.stage {
        case .code, .creating: true
        default: false
        }
    }

    public var body: some View {
        content
            // The code is worthless once a pairing is over, however it ended, and once the screen is left, however it is left: the
            // pasteboard is cleared as soon as that is so.
            .onChange(of: codeInUse, initial: true) { _, inUse in if !inUse { PairingClipboard.ended() } }
            .onDisappear { PairingClipboard.ended() }
    }

    @ViewBuilder private var content: some View {
        switch state.stage {
        case .code(let code):
            CodeStep(code: code, step: step, state: state, actions: actions)
        case .codeExpired:
            Plain(step: step, primary: actions.onNewCode, secondary: actions.onCancel, actions: actions, id: "pair_expired")
        case .compare(let pending):
            CompareStep(pending: pending, step: step, state: state, actions: actions, desktop: desktop)
        case .rejected:
            Plain(step: step, primary: actions.onDone, actions: actions, id: "pair_rejected")
        case .paired(_, let deviceID):
            Plain(
                step: step, primary: actions.onDone, secondary: { if let deviceID { actions.onOpenPage(deviceID) } }, actions: actions,
                back: actions.onDone, id: "pair_paired"
            )
        case .ended:
            Plain(step: step, primary: actions.onDone, actions: actions, id: "pair_ended")
        case .idle where state.interrupted:
            Plain(step: step, primary: actions.onNewCode, secondary: actions.onCancel, actions: actions, id: "pair_interrupted")
        case .idle where state.pairing.error != nil:
            Plain(step: step, primary: actions.onNewCode, secondary: actions.onBack, actions: actions, id: "pair_create_failed") {
                if let kind = state.pairing.error, kind == .ownerCheckRequired {
                    OwnerCheckNotice(kind: kind, title: step.title, onCheck: actions.onOwnerCheck)
                } else {
                    NoticeCard(.warning, title: step.title, message: step.body ?? "")
                }
            }
        case .idle where state.held:
            Plain(step: step, primary: actions.onDone, actions: actions, id: "pair_lost")
        case .idle, .creating:
            Plain(step: step, actions: actions, id: "pair_creating") {
                ProgressView().frame(maxWidth: .infinity).accessibilityLabel(DeviceStrings.pairCreating)
            }
        }
    }
}

/// A step with a title, its body line (unless [content] says it), and a primary and secondary button when the step has them.
private struct Plain<Content: View>: View {
    let step: PairStep
    let primary: (@MainActor () -> Void)?
    let secondary: (@MainActor () -> Void)?
    let actions: PairActions
    let back: (@MainActor () -> Void)?
    let id: String
    let content: Content

    init(
        step: PairStep, primary: (@MainActor () -> Void)? = nil, secondary: (@MainActor () -> Void)? = nil, actions: PairActions,
        back: (@MainActor () -> Void)? = nil, id: String, @ViewBuilder content: () -> Content
    ) {
        self.step = step
        self.primary = primary
        self.secondary = secondary
        self.actions = actions
        self.back = back
        self.id = id
        self.content = content()
    }

    var body: some View {
        FormScaffold(
            title: step.title, primaryLabel: step.primary, secondaryLabel: step.secondary, onPrimary: primary ?? {},
            onSecondary: secondary ?? {}, onBack: back ?? actions.onBack
        ) {
            content
        }
        .accessibilityIdentifier(id)
    }
}

extension Plain where Content == BodyLine {
    /// The step's body as one line of text.
    init(
        step: PairStep, primary: (@MainActor () -> Void)? = nil, secondary: (@MainActor () -> Void)? = nil, actions: PairActions,
        back: (@MainActor () -> Void)? = nil, id: String
    ) {
        self.init(step: step, primary: primary, secondary: secondary, actions: actions, back: back, id: id) { BodyLine(text: step.body) }
    }
}

private struct BodyLine: View {
    let text: String?

    var body: some View { if let text { Text(text).vettIDFont(.bodyLarge) } }
}

/// Kept out of screenshots and screen recordings unless the member allowed screenshots (Settings → App): the code, its QR and the
/// digits to compare. vettid-android keeps the whole window out of captures (`FLAG_SECURE`); on the iPhone these are what a capture
/// must not carry, on top of the app-switcher cover and capture hiding that are always on (chosen; not in the spec).
private struct CaptureProtected<Content: View>: View {
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    @ViewBuilder let content: () -> Content

    var body: some View { SecureContainer(isSecure: !(allowance?.allowed ?? false)) { content() } }
}

// MARK: Step 1: the code

private struct CodeStep: View {
    @Environment(\.vettIDColors) private var colors
    let code: PairingCode
    let step: PairStep
    let state: PairState
    let actions: PairActions

    var body: some View {
        FormScaffold(
            title: step.title, message: step.body, primaryLabel: nil, secondaryLabel: step.secondary, onPrimary: {},
            onSecondary: actions.onCancel, onBack: actions.onCancel
        ) {
            CaptureProtected { QrCode(code.link, accessibilityLabel: DeviceStrings.pairQrCd) }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("pair_qr")
            Countdown(exp: code.exp).padding(.top, Spacing.m)
            CaptureProtected {
                Text(verbatim: code.link)
                    // Deliberately not selectable (vettid-android's is): every copy of the code goes through ``PairingClipboard``
                    // and so ``SecurePasteboard`` (local to this iPhone, expiring), never the system's own Copy.
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.m)
                    .background(colors.surfaceContainer, in: VettIDShape.card)
            }
            .padding(.top, Spacing.l)
            .accessibilityIdentifier("pair_link")
            buttons.padding(.top, Spacing.s)
        }
        .accessibilityIdentifier("pair_code")
    }

    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            Button {
                // Local to this iPhone (never on Universal Clipboard), gone at the code's end or when the pairing ends (IOS-PLAN §6.5).
                PairingClipboard.copy(code.link, exp: code.exp)
                actions.onCopied()
            } label: {
                OutlinedLabel(symbol: .contentCopy, text: state.copied ? DeviceStrings.pairCopied : DeviceStrings.pairCopy)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pair_copy")
            // The code only, nothing around it; the sheet's title is the line "Send it only to yourself.". Sharing the code is allowed
            // (ANDROID-PLAN 0.1.53 AA2 decision 1(b)); the share sheet's own Copy action bypasses ``SecurePasteboard``, which is the
            // member's choice of where to send it.
            ShareLink(item: code.link, preview: SharePreview(DeviceStrings.pairShareTitle)) {
                OutlinedLabel(symbol: .share, text: DeviceStrings.pairShare)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pair_share")
        }
    }
}

/// "Expires in 9:41", counting down to the code's end, and the minutes left in words, said to VoiceOver once a minute (the
/// second-by-second tick announces nothing).
struct Countdown: View {
    @Environment(\.vettIDColors) private var colors
    let exp: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, exp.timeIntervalSince(context.date))
            let minutes = Self.minutes(left)
            VStack(spacing: 2) {
                Text(DeviceStrings.pairExpiresIn(Self.clock(left)))
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("pair_countdown")
                Text(DeviceStrings.pairMinutesLeft(minutes))
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("pair_minutes_left")
                    .announcedOnChange(DeviceStrings.pairMinutesLeft(minutes), .polite)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }

    /// "9:41".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The whole minutes left, rounded up (never below 0).
    static func minutes(_ seconds: TimeInterval) -> Int { Int((max(0, seconds) / 60).rounded(.up)) }
}

/// An outlined pill button's label with its icon. Mirrors vettid-android's `OutlinedButton` rows of the pairing screen.
private struct OutlinedLabel: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: VettIDSymbol
    let text: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            symbol.image.scaledIcon(size: 16)
            Text(text).vettIDFont(.labelLarge)
        }
        .foregroundStyle(colors.onSurface)
        .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget)
        .overlay(VettIDShape.pill.stroke(colors.outline))
        .contentShape(VettIDShape.pill)
    }
}

// MARK: The daily check

/// The daily check is due: the vault's own words, and the way to the check.
private struct OwnerCheckNotice: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let kind: FailureKind
    let title: String
    let onCheck: @MainActor () -> Void

    var body: some View {
        NoticeCard(.warning, title: title, message: kind.message(timeScale: timeScale), announce: .polite) {
            DeviceTextAction(label: DeviceStrings.pairCheckNow, identifier: "pair_check_now", action: onCheck)
        }
        .accessibilityIdentifier("pair_owner_check")
    }
}

// MARK: Step 2: compare

private struct CompareStep: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDCovered) private var covered
    let pending: PendingPairing
    let step: PairStep
    let state: PairState
    let actions: PairActions
    let desktop: Bool

    /// The sheet is open only over a comparison that can be compared, and closing it tells the model.
    private var sheetShown: Binding<Bool> {
        Binding(get: { state.sheet && pending.comparable }, set: { if !$0 { actions.onCloseSheet() } })
    }

    var body: some View {
        FormScaffold(
            title: step.title, primaryLabel: step.primary, busy: state.pairing.busy, destructive: step.destructive,
            secondaryLabel: step.secondary,
            onPrimary: { pending.comparable ? actions.onCodesMatch(pending.pairingID) : actions.onReject(pending.pairingID) },
            onSecondary: { actions.onReject(pending.pairingID) },
            // Leaving without an answer rejects (the view model): nothing is approved by leaving.
            onBack: actions.onBack
        ) {
            if let sas = pending.sas {
                SasSentence(sas: sas, desktop: desktop)
            } else {
                Text(DeviceStrings.pairCannotCompare).vettIDFont(.bodyLarge).accessibilityIdentifier("pair_cannot_compare")
            }
            // The name is the device's word about itself: cleaned, isolated, and never what proves the device.
            Text(PairTexts.callsItself(pending.name, desktop: desktop))
                .vettIDFont(.bodyLarge)
                .padding(.top, Spacing.l)
                .accessibilityIdentifier("pair_name")
            Text(PairTexts.callsItselfNote(desktop: desktop))
                .vettIDFont(.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
                .padding(.top, Spacing.xs)
        }
        .accessibilityIdentifier("pair_compare")
        .sheet(isPresented: uncovered(sheetShown, covered: covered)) {
            AllowSheet(state: state, actions: actions, desktop: desktop)
                .presentationBackground(colors.surfaceContainerLow.color)
                .environment(\.vettIDColors, colors)
        }
        .closesWhenCovered { actions.onCloseSheet() }
    }
}

/// "Does the agent (or desktop) show **123 456**?": the digits in two groups of three, large; read digit by digit by VoiceOver.
struct SasSentence: View {
    @Environment(\.vettIDColors) private var colors
    let sas: String
    let desktop: Bool

    /// "123 456".
    var grouped: String { "\(sas.prefix(3)) \(sas.dropFirst(3))" }

    var text: String { PairTexts.compareBody(sas: sas, desktop: desktop) }

    /// What VoiceOver says: each digit alone.
    var spoken: String { text.replacingOccurrences(of: grouped, with: sas.map(String.init).joined(separator: " ")) }

    var body: some View {
        CaptureProtected {
            sentence
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
        .accessibilityIdentifier("pair_sas")
    }

    /// The sentence with the digits bold, monospaced and large, in the primary colour.
    private var sentence: Text {
        let t = text
        guard let r = t.range(of: grouped) else { return Text(t).font(.body) }
        let digits = Text(grouped)
            .font(.system(size: 28, weight: .bold, design: .monospaced))
            .foregroundColor(colors.primary.color)
        return Text(String(t[..<r.lowerBound])) + digits + Text(String(t[r.upperBound...]))
    }
}

// MARK: Step 3: allow access

/// "Allow access now?": **Pair** sends the approval with no grants.
private struct AllowSheet: View {
    @Environment(\.vettIDColors) private var colors
    let state: PairState
    let actions: PairActions
    let desktop: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(DeviceStrings.pairAllowTitle).vettIDFont(.titleLarge).accessibilityAddTraits(.isHeader)
            Text(PairTexts.allowBody(desktop: desktop)).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
            ForEach(SessionChoice.allCases, id: \.self) { c in row(c) }
            if let kind = state.pairing.error, kind == .ownerCheckRequired {
                OwnerCheckNotice(
                    kind: kind, title: desktop ? DeviceStrings.pairTitleDesktop : DeviceStrings.pairTitle, onCheck: actions.onOwnerCheck
                )
            }
            PrimaryButton(DeviceStrings.pairConfirm, busy: state.pairing.busy, action: actions.onPair)
                .disabled(state.pairing.busy)
                .accessibilityIdentifier("pair_confirm")
                .padding(.top, Spacing.s)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vettIDGrowingSheet()
        .accessibilityIdentifier("pair_sheet")
    }

    private func row(_ c: SessionChoice) -> some View {
        let selected = c == state.session
        return Button { actions.onChoose(c) } label: {
            HStack(spacing: Spacing.m) {
                (selected ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image
                    .scaledIcon(size: 22)
                    .foregroundStyle(selected ? colors.primary : colors.onSurfaceVariant)
                Text(PairTexts.label(c)).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.pairing.busy)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("pair_session_\(String(describing: c))")
    }
}
#endif
