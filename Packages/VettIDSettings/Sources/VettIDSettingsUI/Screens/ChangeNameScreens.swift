#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboardingUI
import VettIDSettings
import VettIDUI

/// What the name change can ask for. Mirrors vettid-android `ChangeNameActions`; the PIN is the keypad's, handed over
/// once with ``onSubmit`` (IOS-PLAN §6.5).
public struct ChangeNameActions {
    public var onFirst: @MainActor (String) -> Void = { _ in }
    public var onLast: @MainActor (String) -> Void = { _ in }
    public var onNext: @MainActor () -> Void = {}
    public var onPassword: @MainActor (String) -> Void = { _ in }
    /// The PIN from the keypad, then the request.
    public var onSubmit: @MainActor (_ pin: String) -> Void = { _ in }
    public var onBackToNames: @MainActor () -> Void = {}
    /// The app leaves the foreground or the iPhone locks: typed secrets are dropped.
    public var onForgetSecrets: @MainActor () -> Void = {}
    /// Leaves the flow.
    public var onClose: @MainActor () -> Void = {}

    public init() {}
}

/// What to say about the account's names (VAULT-MESSAGING §10.8 "What the app shows"): a pending request, a refusal (with
/// its reason), or that the next change must wait (the snapshot's `name_change.allowed_after`); nil when there is nothing
/// to say. The avatar sheet shows it under the names. Mirrors vettid-android `nameStatusText`.
public enum NameStatus {
    public static func text(_ account: AccountInfo?, now: Date = Date()) -> String? {
        let r = account?.nameRequest
        if let r, r.state == .pending { return NameStrings.statusPending(AccountNames.isolate("\(r.firstName) \(r.lastName)")) }
        if let r, r.state == .refused { return refusal(r, allowedAfter: account?.nameAllowedAfter) }
        if let after = account?.nameAllowedAfter, after > now { return NameStrings.tooSoon(SettingsTimes.day(after)) }
        return nil
    }

    static func refusal(_ r: NameRequestView, allowedAfter: Date?) -> String {
        switch r.reason {
        case NameRequestView.reasonInvalid: NameStrings.refusedInvalid
        case NameRequestView.reasonAccount: NameStrings.refusedAccount
        // too_soon, or a reason this app does not know: the 30-day rule is the usual one.
        default: tooSoon(allowedAfter)
        }
    }

    static func tooSoon(_ allowedAfter: Date?) -> String {
        allowedAfter.map { NameStrings.tooSoon(SettingsTimes.day($0)) } ?? NameStrings.tooSoonUndated
    }
}

/// The name change for [state] (stateless): the names, then the PIN and the password, then the request's state. Mirrors
/// vettid-android `ChangeNameContent`.
public struct ChangeNameContent: View {
    let state: ChangeNameState
    let actions: ChangeNameActions
    let now: Date

    public init(state: ChangeNameState, actions: ChangeNameActions = ChangeNameActions(), now: Date = Date()) {
        self.state = state
        self.actions = actions
        self.now = now
    }

    public var body: some View {
        switch state.step {
        case .names: ChangeNameNamesStep(state: state, actions: actions, now: now)
        case .confirm: ChangeNameConfirmStep(state: state, actions: actions)
        case .sent: ChangeNameSentStep(state: state, actions: actions)
        }
    }
}

/// The hero glyph above a ``FormScaffold`` title, as on the owner-check screen.
struct HeaderGlyph: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: VettIDSymbol

    var body: some View {
        symbol.image.font(.system(size: 36)).foregroundStyle(colors.primary).padding(.top, Spacing.l).accessibilityHidden(true)
    }
}

/// The two names, checked with the registration rule before the PIN and the password are asked for.
struct ChangeNameNamesStep: View {
    @Environment(\.vettIDColors) private var colors
    let state: ChangeNameState
    let actions: ChangeNameActions
    let now: Date

    static func error(_ check: AccountNames.Check) -> String? {
        switch check {
        case .ok: nil
        case .empty: NameStrings.empty
        case .tooLong: NameStrings.tooLong
        case .invalid: NameStrings.invalid
        }
    }

    var body: some View {
        // too_soon from the vault, or the snapshot's allowed_after still ahead (§10.8): no change can be applied yet.
        let tooSoon = state.tooSoon || state.account?.nameChangeTooSoon(now: now) == true
        let allowedAfter = state.allowedAfter ?? state.account?.nameAllowedAfter.flatMap { $0 > now ? $0 : nil }
        FormScaffold(
            title: NameStrings.title, message: NameStrings.body, primaryLabel: NameStrings.continueLabel, primaryEnabled: !tooSoon,
            onPrimary: actions.onNext, onBack: actions.onClose, header: { HeaderGlyph(symbol: .edit) }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if tooSoon {
                    NoticeCard(.info, title: NameStrings.title, message: NameStatus.tooSoon(allowedAfter))
                        .accessibilityIdentifier("name_too_soon")
                }
                if let r = state.account?.nameRequest, r.state == .pending {
                    Text(NameStrings.statusPending(AccountNames.isolate("\(r.firstName) \(r.lastName)")))
                        .vettIDFont(.bodyMedium)
                        .accessibilityIdentifier("name_pending")
                }
                NameField(
                    label: NameStrings.first, text: state.first, error: state.checked ? Self.error(state.firstCheck) : nil,
                    identifier: "name_first", onChange: actions.onFirst
                )
                NameField(
                    label: NameStrings.last, text: state.last, error: state.checked ? Self.error(state.lastCheck) : nil,
                    identifier: "name_last", onChange: actions.onLast, onSubmit: actions.onNext
                )
                if let problem = problem {
                    Text(problem).vettIDFont(.bodyMedium).foregroundStyle(colors.error).accessibilityIdentifier("name_problem")
                }
            }
        }
        .accessibilityIdentifier("change_name_names")
    }

    private var problem: String? {
        if state.message == .invalid { return NameStrings.refusedInvalid }
        if state.checked && state.same { return NameStrings.same }
        return nil
    }
}

/// A name, with its label above and the rule (or its error) below. Not a secret: the system keyboard, words capitalised.
struct NameField: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let text: String
    let error: String?
    let identifier: String
    let onChange: @MainActor (String) -> Void
    var onSubmit: @MainActor () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label).vettIDFont(.labelMedium).foregroundStyle(error == nil ? colors.onSurfaceVariant : colors.error)
            TextField("", text: Binding(get: { text }, set: { onChange($0) }))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { onSubmit() }
                .vettIDFont(.bodyLarge)
                .frame(minHeight: Spacing.touchTarget)
                .padding(.horizontal, Spacing.l)
                .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(error == nil ? colors.outline : colors.error))
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            Text(error ?? NameStrings.rule).vettIDFont(.bodySmall).foregroundStyle(error == nil ? colors.onSurfaceVariant : colors.error)
        }
    }
}

/// The PIN on the in-app keypad (IOS-PLAN §6.5) and the credential password, on one screen as for the owner check.
struct ChangeNameConfirmStep: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.vettIDColors) private var colors
    @Environment(\.scenePhase) private var scenePhase
    let state: ChangeNameState
    let actions: ChangeNameActions
    @State private var pin = PinBuffer()

    /// Fewer checks than this left are shown in the error colour.
    static let warnLeft = 3

    private var canSubmit: Bool { state.entriesAllowed && pin.count >= ChangeNameState.minPin && !state.password.isEmpty }

    private func submit() {
        guard canSubmit else { return }
        actions.onSubmit(pin.take())
    }

    var body: some View {
        FormScaffold(
            title: NameStrings.confirmTitle, message: NameStrings.confirmBody(AccountNames.isolate(state.requestedName)),
            primaryLabel: NameStrings.submit, primaryEnabled: canSubmit, busy: state.busy, secondaryLabel: NameStrings.back,
            onPrimary: submit, onSecondary: actions.onBackToNames, onBack: actions.onBackToNames,
            header: { HeaderGlyph(symbol: .verifiedUser) }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PinEntry(
                    label: NameStrings.pin, buffer: pin, error: badPin && pin.count == 0 ? NameStrings.badPin : nil, identifier: "name_pin"
                )
                .disabled(!state.entriesAllowed)
                SecretField(
                    NameStrings.password, text: Binding(get: { state.password }, set: { actions.onPassword($0) }),
                    error: badPassword ? NameStrings.badPassword : nil, onSubmit: submit
                )
                .disabled(!state.entriesAllowed)
                .accessibilityIdentifier("name_password")
                message
            }
        }
        .accessibilityIdentifier("change_name_confirm")
        .onDisappear { forget() }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
            if now == .background { forget() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            forget()
        }
    }

    private var badPin: Bool { if case .badPin? = state.message { true } else { false } }
    private var badPassword: Bool { if case .badPassword? = state.message { true } else { false } }

    @ViewBuilder private var message: some View {
        let left: Int? = switch state.message {
        case .badPin(let n)?, .badPassword(let n)?: n
        default: nil
        }
        if let left {
            Text(NameStrings.checksLeft(left))
                .vettIDFont(.bodyMedium)
                .foregroundStyle(left <= Self.warnLeft ? colors.error : colors.onSurfaceVariant)
                .accessibilityIdentifier("name_checks_left")
        }
        if state.waitSeconds > 0 {
            Text(NameStrings.wait(SettingsTimes.wait(state.waitSeconds))).vettIDFont(.bodyMedium).accessibilityIdentifier("name_wait")
        } else if state.message == .backoff {
            Text(NameStrings.backoff).vettIDFont(.bodyMedium)
        } else if case .failed(let kind)? = state.message {
            NoticeCard(.urgent, title: kind.title(or: NameStrings.title), message: kind.message(timeScale: timeScale))
                .accessibilityIdentifier("name_failed")
        }
    }

    private func forget() {
        pin.clear()
        actions.onForgetSecrets()
    }
}

/// The request as the account reports it: pending, applied or refused.
struct ChangeNameSentStep: View {
    let state: ChangeNameState
    let actions: ChangeNameActions

    /// What the step says for the request's state.
    struct Says {
        let title: String
        let body: String
        let symbol: VettIDSymbol
        let tag: String
    }

    static func says(_ state: ChangeNameState) -> Says {
        let r = state.request
        let name = AccountNames.isolate(r.map { "\($0.firstName) \($0.lastName)" } ?? state.requestedName)
        if let r, r.state == .applied {
            return Says(title: NameStrings.appliedTitle, body: NameStrings.appliedBody(name), symbol: .checkCircle, tag: "applied")
        }
        if let r, r.state == .refused {
            let why = NameStatus.refusal(r, allowedAfter: state.account?.nameAllowedAfter)
            return Says(title: NameStrings.refusedTitle, body: why, symbol: .errorOutline, tag: "refused")
        }
        return Says(title: NameStrings.requestedTitle, body: NameStrings.requestedBody(name), symbol: .schedule, tag: "pending")
    }

    var body: some View {
        let s = Self.says(state)
        FormScaffold(
            title: s.title, message: s.body, primaryLabel: NameStrings.done, onPrimary: actions.onClose,
            header: { HeaderGlyph(symbol: s.symbol) }
        ) {
            EmptyView()
        }
        .accessibilityIdentifier("change_name_sent_\(s.tag)")
    }
}
#endif
