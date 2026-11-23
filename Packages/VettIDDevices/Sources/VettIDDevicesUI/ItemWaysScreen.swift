#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

private typealias Txt = ItemWaysStrings

/// What the item's page can ask for. Mirrors vettid-android `ItemWaysActions`.
public struct ItemWaysActions {
    public var onBack: @MainActor () -> Void = {}
    public var onSave: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    public var onShowCurrent: @MainActor () -> Void = {}
    public var onRun: @MainActor (Bool) -> Void = { _ in }
    public var onProxy: @MainActor (Bool) -> Void = { _ in }
    public var onReveal: @MainActor (Bool) -> Void = { _ in }
    public var onEach: @MainActor (Bool) -> Void = { _ in }
    public var onConfirm: @MainActor () -> Void = {}
    public var onDismissConfirm: @MainActor () -> Void = {}
    public var onProgramInput: @MainActor (String) -> Void = { _ in }
    public var onAddProgram: @MainActor () -> Void = {}
    public var onOpenProgram: @MainActor (Int) -> Void = { _ in }
    public var onCloseProgram: @MainActor () -> Void = {}
    public var onEditInput: @MainActor (String) -> Void = { _ in }
    public var onApplyEdit: @MainActor () -> Void = {}
    public var onRemoveProgram: @MainActor (Int) -> Void = { _ in }
    public var onForgetPin: @MainActor (Int) -> Void = { _ in }
    public var onShowPin: @MainActor (String?) -> Void = { _ in }
    public var onVariableInput: @MainActor (String) -> Void = { _ in }
    public var onAddVariable: @MainActor () -> Void = {}
    public var onRemoveVariable: @MainActor (String) -> Void = { _ in }
    public var onHostInput: @MainActor (String) -> Void = { _ in }
    public var onAddHost: @MainActor () -> Void = {}
    public var onRemoveHost: @MainActor (String) -> Void = { _ in }
    public var onHeader: @MainActor (String) -> Void = { _ in }
    public var onPrefix: @MainActor (String) -> Void = { _ in }
    public var onPassword: @MainActor (String) -> Void = { _ in }
    public var onSubmitPassword: @MainActor () -> Void = {}
    public var onDismissPrompt: @MainActor () -> Void = {}
    public var onOpenAlarm: @MainActor () -> Void = {}
    public var onNoticeShown: @MainActor () -> Void = {}
    public var onCloseWindowNow: @MainActor () -> Void = {}

    public init() {}
}

/// How long the page stays after `not_found` to a save before it goes back.
private let notIncludedSeconds = 4.0

/// How an agent may use an item (ANDROID-PLAN 0.1.137 AA7): the four ways, the run settings with each program's page, the API
/// settings, and **Save**. A read-only page (settings this version can't show) offers only to turn a whole way off. The screen is
/// kept out of screenshots (it holds the member's settings and the password prompt). Mirrors vettid-android `ItemWaysScreen`.
public struct ItemWaysScreen: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.vettIDCovered) private var covered
    let state: ItemWaysState
    let actions: ItemWaysActions

    public init(state: ItemWaysState, actions: ItemWaysActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        SecureContainer(isSecure: true) {
            DetailScaffold(onBack: back) {
                content
            } actions: {
                if !state.readOnly && state.draft != nil {
                    TopBarTextAction(Txt.waysSave, enabled: state.canSave, busy: state.saving, action: actions.onSave)
                        .accessibilityIdentifier("ways_save")
                }
            }
            .accessibilityIdentifier("item_ways_screen")
        }
        // The swipe back from a program's page would drop the whole page and its draft: only the bar's Back closes the program.
        .blocksBackGesture(state.openProgram != nil)
        .holdsInput(state.holdsInput)
        .deviceToast(noticeText, bottom: Spacing.l, onShown: actions.onNoticeShown)
        // After a save's not_found the page says so, then goes back; an event's says so and stays.
        .task(id: state.leaving) {
            guard state.leaving else { return }
            try? await Task.sleep(for: .seconds(notIncludedSeconds))
            if !Task.isCancelled { actions.onBack() }
        }
        .modifier(WaysDialogs(state: state, actions: actions))
        .sheet(isPresented: Binding(get: { state.prompt != nil && !covered }, set: { if !$0 && !covered { actions.onDismissPrompt() } })) {
            WaysPasswordSheet(state: state, actions: actions).vettIDGrowingSheet()
                .interactiveDismissDisabled(state.prompt?.sending == true)
        }
    }

    /// Back from a program's page goes to the settings; from the settings, away.
    private var back: @MainActor () -> Void {
        let a = actions
        let onProgram = state.openProgram != nil
        return { if onProgram { a.onCloseProgram() } else { a.onBack() } }
    }

    private var noticeText: String? {
        switch state.notice {
        case .saved: Txt.waysSaved
        case .lockedAgain: Txt.waysLockedAgain
        case .conflict: Txt.waysConflict
        case .readOnlyLocked: Txt.waysReadOnlyLocked
        case .failed(let kind): kind.message(timeScale: timeScale)
        case nil: nil
        }
    }

    @ViewBuilder private var content: some View {
        if state.read == nil, let e = state.loadError {
            VStack {
                NoticeCard(.warning, title: Txt.waysLoadFailed, message: e.message(timeScale: timeScale), announce: .polite) {
                    DeviceTextAction(label: Txt.waysRetry, identifier: "ways_retry", action: actions.onRetry)
                }
                .accessibilityIdentifier("ways_load_failed")
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.read == nil && !state.notIncluded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text(Txt.waysTitle(state.agentName, state.shownItemName))
                        .vettIDFont(.headlineSmall)
                        .padding(.horizontal, Spacing.gutter)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("ways_title")
                    // A re-read that failed while settings are shown: they may be out of date (a conflict's reload, an event's).
                    if let e = state.loadError {
                        NoticeCard(.warning, title: Txt.waysLoadFailed, message: e.message(timeScale: timeScale), announce: .polite) {
                            DeviceTextAction(label: Txt.waysRetry, identifier: "ways_retry", action: actions.onRetry)
                        }
                        .padding(.horizontal, Spacing.s)
                        .accessibilityIdentifier("ways_reload_failed")
                    }
                    WaysNotices(state: state, actions: actions)
                    if state.notIncluded {
                        EmptyView()
                    } else if let i = state.openProgram, let p = state.draft?.run?.programs[safe: i] {
                        ProgramPage(state: state, program: p, index: i, actions: actions)
                    } else {
                        WaysMainPage(state: state, actions: actions)
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
        }
    }
}

/// The cards above the settings: the refusal, "no longer included", "changed elsewhere", the read-only line, the open window.
private struct WaysNotices: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: ItemWaysState
    let actions: ItemWaysActions

    var body: some View {
        VStack(spacing: Spacing.m) {
            if let message = state.refused { RefusedCard(message: message) }
            if state.notIncluded {
                NoticeCard(.warning, title: Txt.waysNotIncluded(state.agentName), announce: .polite)
                    .padding(.horizontal, Spacing.s)
                    .accessibilityIdentifier("ways_not_included")
            }
            if state.changedElsewhere {
                NoticeCard(.info, title: Txt.waysChangedElsewhere, announce: .polite) {
                    DeviceTextAction(label: Txt.waysShowCurrent, identifier: "ways_show_current", action: actions.onShowCurrent)
                }
                .padding(.horizontal, Spacing.s)
                .accessibilityIdentifier("ways_changed_elsewhere")
            }
            if state.readOnly {
                NoticeCard(.info, title: Txt.waysReadOnly)
                    .padding(.horizontal, Spacing.s)
                    .accessibilityIdentifier("ways_read_only")
            }
            if let w = state.windowNotClosed {
                let minutes = w.ttlSeconds.map { ($0 + 59) / 60 }
                NoticeCard(
                    .warning, title: Txt.waysWindowTitle,
                    message: minutes.map { Txt.waysWindowOpen($0) } ?? Txt.waysWindowPlain, announce: .polite
                ) {
                    DeviceTextAction(label: Txt.waysWindowClose, identifier: "ways_window_close", action: actions.onCloseWindowNow)
                }
                .padding(.horizontal, Spacing.s)
                .accessibilityIdentifier("ways_window_open")
            }
        }
    }
}

/// A save refused with `bad_request` (AA7 "Saving", 0.1.138): the vault's message as it is, in a monospace box, inside the approved
/// sentence; or, when [message] is "" (none, or not one ``VaultReason`` shows), the fallback text.
private struct RefusedCard: View {
    @Environment(\.vettIDColors) private var colors
    let message: String

    /// Stands for the vault's message while the approved sentence is split around it; never shown.
    private static let marker = "\u{0}"

    var body: some View {
        Text(text)
            .vettIDFont(.bodyMedium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.l)
            .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(colors.error))
            .padding(.horizontal, Spacing.s)
            .accessibilityElement(children: .combine)
            .announced(spoken, .polite)
            .accessibilityIdentifier("ways_refused")
    }

    private var spoken: String { message.isEmpty ? Txt.waysBadRequestFallback : Txt.waysBadRequest(message) }

    private var text: AttributedString {
        if message.isEmpty { return AttributedString(Txt.waysBadRequestFallback) }
        let parts = Txt.waysBadRequest(Self.marker).components(separatedBy: Self.marker)
        var out = AttributedString(parts.first ?? "")
        var m = AttributedString(message)
        m.font = .system(.body, design: .monospaced)
        m.backgroundColor = colors.surfaceVariant.color
        out.append(m)
        out.append(AttributedString(parts.dropFirst().joined()))
        return out
    }
}

/// The confirmations of the page (alerts, the destructive or confirming button styled as such) and the full fingerprint.
private struct WaysDialogs: ViewModifier {
    @Environment(\.vettIDCovered) private var covered
    let state: ItemWaysState
    let actions: ItemWaysActions

    func body(content: Content) -> some View {
        let item = state.shownItemName
        let agent = state.agentName
        content
            .confirmDialog(
                isPresented: confirming(.runOff), title: Txt.waysRunOffTitle(item),
                message: state.read?.answerHasFolders == true ? Txt.waysRunOffBodyFolders : Txt.waysRunOffBody,
                confirmLabel: Txt.waysTurnOff, destructive: true, dismissLabel: Txt.waysCancel, onConfirm: actions.onConfirm
            )
            .confirmDialog(
                isPresented: confirming(.proxyOff), title: Txt.waysProxyOffTitle(item), message: Txt.waysProxyOffBody,
                confirmLabel: Txt.waysTurnOff, destructive: true, dismissLabel: Txt.waysCancel, onConfirm: actions.onConfirm
            )
            .confirmDialog(
                isPresented: confirming(.revealOn), title: Txt.waysRevealOnTitle(agent, item),
                message: Txt.waysRevealOnBody, confirmLabel: Txt.waysTurnOn,
                dismissLabel: Txt.waysCancel, onConfirm: actions.onConfirm
            )
            .confirmDialog(
                isPresented: confirming(.eachOff), title: Txt.waysEachOffTitle, message: Txt.waysEachOffBody(agent),
                confirmLabel: Txt.waysTurnOff, destructive: true, dismissLabel: Txt.waysCancel, onConfirm: actions.onConfirm
            )
            .confirmDialog(
                isPresented: removingLast, title: Txt.waysRemoveLastTitle, message: Txt.waysRemoveLastBody(agent),
                confirmLabel: Txt.waysRemove, destructive: true, dismissLabel: Txt.waysCancel, onConfirm: actions.onConfirm
            )
            .confirmDialog(
                isPresented: forgetting, title: Txt.waysPinForgetTitle, message: Txt.waysPinForgetBody(forgetProgram),
                confirmLabel: Txt.waysPinForgetConfirm, dismissLabel: Txt.waysCancel, onConfirm: actions.onConfirm
            )
            .alert(
                "", isPresented: uncovered(pinShown, covered: covered)
            ) {
                Button(Txt.waysPinClose, role: .cancel) {}
            } message: {
                Text(state.fullPin.map { Fingerprints.full($0) } ?? "").monospaced()
            }
    }

    private var pinShown: Binding<Bool> {
        Binding(get: { state.fullPin != nil }, set: { if !$0 { actions.onShowPin(nil) } })
    }

    private func confirming(_ c: WaysConfirm) -> Binding<Bool> {
        Binding(get: { state.confirm == c }, set: { if !$0 { actions.onDismissConfirm() } })
    }

    private var removingLast: Binding<Bool> {
        Binding(get: { if case .removeLastProgram = state.confirm { true } else { false } }, set: { if !$0 { actions.onDismissConfirm() } })
    }

    private var forgetting: Binding<Bool> {
        Binding(get: { if case .forgetPin = state.confirm { true } else { false } }, set: { if !$0 { actions.onDismissConfirm() } })
    }

    /// The program the fingerprint is forgotten for, by the string rule, inside the sentence.
    private var forgetProgram: String {
        guard case .forgetPin(let i) = state.confirm, let p = state.draft?.run?.programs[safe: i]?.program else { return "" }
        return ShownString.inline(ItemWaysRules.lastElement(p), empty: Txt.waysStringEmpty)
    }
}

/// The unlock window prompt of a widening save (AA7 "Saving"): its own body text, the credential password on the secret field of
/// IOS-PLAN §6.5 (no AutoFill, no "Save Password?"); the alarm with a link to it.
private struct WaysPasswordSheet: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: ItemWaysState
    let actions: ItemWaysActions

    var body: some View {
        let p = state.prompt ?? WaysPrompt()
        SecureContainer(isSecure: true) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(Txt.waysPasswordTitle).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
                Text(Txt.waysPasswordBody(state.agentName, state.shownItemName)).vettIDFont(.bodyMedium)
                SecretField(
                    Txt.waysPasswordLabel, text: Binding(get: { p.password }, set: { actions.onPassword($0) }),
                    error: p.error.map { p.alarm ? Txt.waysAlarm : $0.message(timeScale: timeScale) },
                    errorPriority: .assertive, focus: true, onSubmit: actions.onSubmitPassword
                )
                .accessibilityIdentifier("ways_password")
                if p.alarm {
                    DeviceTextAction(label: Txt.waysAlarmOpen, identifier: "ways_alarm", action: actions.onOpenAlarm)
                }
                PrimaryButton(Txt.waysPasswordConfirm, busy: p.sending, action: actions.onSubmitPassword)
                    .disabled(p.password.isEmpty || p.sending || p.alarm)
                    .accessibilityIdentifier("ways_password_confirm")
                SecondaryButton(Txt.waysCancel, action: actions.onDismissPrompt)
                    .disabled(p.sending)
            }
            .padding(Spacing.gutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ways_password_sheet")
        }
    }
}
#endif
