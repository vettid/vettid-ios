#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDSettings
import VettIDUI

/// What the Credential screen can ask for. Mirrors vettid-android `CredentialActions`.
public struct CredentialActions {
    public var back: @MainActor () -> Void = {}
    public var retry: @MainActor () -> Void = {}
    public var showWindowDialog: @MainActor (Bool) -> Void = { _ in }
    public var setWindowPassword: @MainActor (String) -> Void = { _ in }
    public var openWindow: @MainActor () -> Void = {}
    public var closeWindow: @MainActor () -> Void = {}
    public var setTtl: @MainActor (Int) -> Void = { _ in }
    public var setBackup: @MainActor (Bool) -> Void = { _ in }
    public var dismissNotice: @MainActor () -> Void = {}
    public var changePassword: @MainActor () -> Void = {}
    public var rotate: @MainActor () -> Void = {}
    public var reviewAlarm: @MainActor () -> Void = {}
    /// A new credential (`credential.reset`): the old one and every critical item are destroyed.
    public var newCredential: @MainActor () -> Void = {}

    public init() {}
}

/// Which of the Credential screen's sheets is open.
enum CredentialSheet: String, Identifiable {
    case ttl, backupOff

    var id: String { rawValue }
}

/// Settings → Security → Credential (ANDROID-PLAN §4; VAULT-MESSAGING §3.5): the Protean Credential's status, the unlock
/// window (§3.5.3) and its length, the password, the rotation (§3.5.5), the sealed backup (§3.5.6, turned off only after a
/// warning and an acknowledgement), a new credential (§3.5.5; ``CredentialState/offersNewCredential``), and the clone
/// alarm's card with its "Review" (§3.5.9). Pushed over Settings with a back arrow and a large title, where vettid-android
/// keeps the top bar of a drawer screen (chosen; not in the spec). Mirrors vettid-android `CredentialContent`.
public struct CredentialContent: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDCovered) private var covered
    let state: CredentialState
    let actions: CredentialActions
    let now: Date
    @State private var sheet: CredentialSheet?

    public init(state: CredentialState, actions: CredentialActions = CredentialActions(), now: Date = Date()) {
        self.state = state
        self.actions = actions
        self.now = now
    }

    public var body: some View {
        DetailScaffold(background: colors.groupedBackground, onBack: actions.back) {
            content
        }
        .accessibilityIdentifier("credential")
        .choiceSheet(item: $sheet) { s in
            switch s {
            case .ttl:
                ChoiceSheet(
                    title: CredentialStrings.ttlTitle,
                    options: CredentialViewModel.ttlOptions.map { ChoiceOption(value: $0, label: Self.ttlLabel($0)) },
                    selected: state.status?.unlockTtlSeconds ?? 300,
                    onPick: { t in
                        sheet = nil
                        actions.setTtl(t)
                    },
                    onDismiss: { sheet = nil }
                )
            case .backupOff:
                BackupOffSheet(onConfirm: {
                    sheet = nil
                    actions.setBackup(false)
                }, onDismiss: { sheet = nil })
            }
        }
        // IOS-PLAN §4.4 (1): a cover ("This phone can't use your vault") closes the password sheet, which a failed
        // `credential.unlock` leaves open.
        .sheet(isPresented: Binding(get: { state.windowDialog && !covered }, set: { if !$0 { actions.showWindowDialog(false) } })) {
            WindowPasswordSheet(state: state, actions: actions)
                .presentationDetents([.medium, .large])
                .presentationBackground(colors.surfaceContainerLow.color)
                .environment(\.vettIDColors, colors)
        }
        .closesWhenCovered { if state.windowDialog { actions.showWindowDialog(false) } }
    }

    @ViewBuilder private var content: some View {
        if state.loading {
            FullScreenProgress(CredentialStrings.loading)
        } else if let st = state.status, st.exists {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle(CredentialStrings.title)
                    notices(st)
                    CredentialRows(state: state, status: st, actions: actions, now: now, sheet: $sheet)
                    Spacer().frame(height: Spacing.xxl)
                }
            }
        } else if state.status == nil, let error = state.error {
            VStack(spacing: Spacing.l) {
                LargeTitle(CredentialStrings.title)
                NoticeCard(
                    .warning, title: error.title(or: CredentialStrings.title), message: error.message(timeScale: timeScale),
                    announce: .polite
                )
                SecondaryButton(CredentialStrings.retry, action: actions.retry)
                Spacer()
            }
            .padding(.horizontal, Spacing.gutter)
        } else {
            EmptyState(icon: .shield, title: CredentialStrings.emptyTitle, message: CredentialStrings.emptyBody)
        }
    }

    @ViewBuilder private func notices(_ st: CredentialStatus) -> some View {
        VStack(spacing: Spacing.s) {
            if let a = state.alarm {
                NoticeCard(
                    .urgent, title: CredentialStrings.alarmCardTitle,
                    message: a.rotationRequired ? CredentialStrings.alarmCardRotate : CredentialStrings.alarmCardFrozen
                ) {
                    NoticeAction(label: CredentialStrings.alarmReview, identifier: "credential_alarm_review", action: actions.reviewAlarm)
                }
                .accessibilityIdentifier("credential_alarm")
            }
            if state.error != nil || state.notice != nil {
                NoticeCard(noticeKind, title: CredentialStrings.title, message: noticeText) {
                    NoticeAction(label: CredentialStrings.done, identifier: "credential_notice_done", action: actions.dismissNotice)
                }
            }
            if !st.backup {
                // §3.5.6: the warning repeated while the backup is off.
                NoticeCard(.warning, title: CredentialStrings.backup, message: CredentialStrings.backupOffNotice)
                    .accessibilityIdentifier("backup_off_notice")
            }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.top, Spacing.s)
    }

    private var noticeKind: NoticeKind { state.error != nil ? .urgent : .success }

    private var noticeText: String {
        if let e = state.error { return e.message(timeScale: timeScale) }
        switch state.notice {
        case .backupOn?: return CredentialStrings.backupOnDone
        case .backupOff?: return CredentialStrings.backupOffDone
        case nil: return ""
        }
    }

    static func ttlLabel(_ seconds: Int) -> String {
        switch seconds {
        case 30: CredentialStrings.ttlThirtySeconds
        case 60: CredentialStrings.ttlOneMinute
        case 300: CredentialStrings.ttlFiveMinutes
        case 900: CredentialStrings.ttlFifteenMinutes
        case 3_600: CredentialStrings.ttlOneHour
        default: CredentialStrings.ttlSeconds(seconds)
        }
    }

    /// An RFC 3339 instant of the vault as a medium date and time; nil when unreadable.
    static func date(_ s: String?) -> String? { OwnerCheckManager.instant(s).map(SettingsTimes.full) }
}

/// The status, the unlock window and the protection groups.
struct CredentialRows: View {
    @Environment(\.vettIDColors) private var colors
    let state: CredentialState
    let status: CredentialStatus
    let actions: CredentialActions
    let now: Date
    @Binding var sheet: CredentialSheet?

    var body: some View {
        let st = status
        SettingsSectionHeader(CredentialStrings.sectionStatus)
        SettingsGroup {
            SettingsInfoRow(CredentialStrings.version, value: st.version.map { String($0) } ?? CredentialStrings.unknown, icon: .shield)
            SettingsDivider()
            SettingsInfoRow(
                CredentialStrings.key, value: st.keyFingerprint ?? CredentialStrings.unknown, icon: .key, code: st.keyFingerprint != nil
            )
            SettingsDivider()
            SettingsInfoRow(
                CredentialStrings.updated, value: CredentialContent.date(st.updatedAt) ?? CredentialStrings.unknown, icon: .sync
            )
            SettingsDivider()
            SettingsInfoRow(
                CredentialStrings.criticalItems, value: st.criticalItems.map { String($0) } ?? CredentialStrings.unknown, icon: .password
            )
        }
        windowGroup
        SettingsSectionHeader(CredentialStrings.sectionProtect)
        SettingsGroup {
            SettingsRow(CredentialStrings.changePassword, icon: .password, action: actions.changePassword)
                .accessibilityIdentifier("change_password")
            SettingsDivider()
            SettingsRow(CredentialStrings.rotate, icon: .sync, supporting: CredentialStrings.rotateSupporting, action: actions.rotate)
                .accessibilityIdentifier("rotate_row")
            SettingsDivider()
            SettingsSwitchRow(
                CredentialStrings.backup,
                isOn: Binding(get: { st.backup }, set: { on in if on { actions.setBackup(true) } else { sheet = .backupOff } }),
                icon: .backup,
                supporting: st.backup ? CredentialStrings.backupSupportingOn : CredentialStrings.backupSupportingOff
            )
            .accessibilityIdentifier("backup_switch")
            if CredentialState.offersNewCredential {
                SettingsDivider()
                SettingsRow(
                    CredentialStrings.newTitle, icon: .restartAlt, iconTint: colors.error, supporting: CredentialStrings.newSupporting,
                    action: actions.newCredential
                )
                .accessibilityIdentifier("new_credential_row")
            }
        }
    }

    @ViewBuilder private var windowGroup: some View {
        let until = state.windowUntil.flatMap { $0 > now ? $0 : nil }
        SettingsSectionHeader(CredentialStrings.sectionWindow)
        SettingsGroup {
            SettingsInfoRow(
                CredentialStrings.windowState,
                value: until.map { CredentialStrings.windowOpenUntil(SettingsTimes.time($0)) } ?? CredentialStrings.windowClosed,
                icon: until != nil ? .lockOpen : .lockClock
            )
            SettingsDivider()
            if until == nil {
                SettingsRow(
                    CredentialStrings.windowOpen, icon: .lockOpen, supporting: CredentialStrings.windowOpenBody, showChevron: false
                ) { actions.showWindowDialog(true) }
                .accessibilityIdentifier("open_window")
            } else {
                SettingsRow(CredentialStrings.windowClose, icon: .lockClock, showChevron: false, action: actions.closeWindow)
                    .accessibilityIdentifier("close_window")
            }
            SettingsDivider()
            SettingsRow(
                CredentialStrings.windowLength, icon: .timer, supporting: CredentialContent.ttlLabel(status.unlockTtlSeconds)
            ) { sheet = .ttl }
            .accessibilityIdentifier("window_length")
        }
    }
}

/// The credential password for the unlock window (vettid-android `PasswordDialog`): a sheet with the secret field.
struct WindowPasswordSheet: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(\.vettIDColors) private var colors
    @Environment(\.scenePhase) private var scenePhase
    let state: CredentialState
    let actions: CredentialActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(CredentialStrings.windowDialogTitle).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
            Text(CredentialStrings.windowDialogBody).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
            SecretField(
                CredentialStrings.passwordLabel, text: Binding(get: { state.windowPassword }, set: { actions.setWindowPassword($0) }),
                error: state.windowError?.message(timeScale: timeScale), errorPriority: .assertive, onSubmit: actions.openWindow
            )
            .disabled(state.busy)
            .accessibilityIdentifier("dialog_password")
            HStack(spacing: Spacing.l) {
                Spacer()
                SheetButton(CredentialStrings.cancel, tint: colors.onSurface) { actions.showWindowDialog(false) }
                    .disabled(state.busy)
                SheetButton(CredentialStrings.open, tint: colors.primary, action: actions.openWindow)
                    .disabled(state.busy || state.windowPassword.isEmpty)
                    .accessibilityIdentifier("dialog_open")
            }
            Spacer()
        }
        .padding(Spacing.xl)
        .interactiveDismissDisabled(state.busy)
        // IOS-PLAN §6.3: the typed password is dropped when the app leaves the foreground, and when the iPhone locks.
        .onChange(of: scenePhase) { _, now in if now == .background { actions.setWindowPassword("") } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            actions.setWindowPassword("")
        }
    }
}

/// §3.5.6: the warning before the backup goes off, with its emphasis, and the acknowledgement it needs. Mirrors
/// vettid-android `BackupOffDialog`.
struct BackupOffSheet: View {
    @Environment(\.vettIDColors) private var colors
    let onConfirm: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void
    @State private var ack = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(CredentialStrings.backupOffTitle).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
                Text(Emphasis.attributed(CredentialStrings.backupOffBody)).vettIDFont(.bodyMedium)
                Button { ack.toggle() } label: {
                    HStack(alignment: .top, spacing: Spacing.s) {
                        (ack ? VettIDSymbol.checkBox : VettIDSymbol.checkBoxOutline).image
                            .foregroundStyle(ack ? colors.primary : colors.onSurfaceVariant)
                            .accessibilityHidden(true)
                        Text(CredentialStrings.backupOffAck).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: Spacing.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(ack ? [.isSelected] : [])
                .accessibilityIdentifier("backup_off_ack")
                HStack(spacing: Spacing.l) {
                    Spacer()
                    SheetButton(CredentialStrings.cancel, tint: colors.onSurface, action: onDismiss)
                    SheetButton(CredentialStrings.backupOffConfirm, tint: colors.error, action: onConfirm)
                        .disabled(!ack)
                        .accessibilityIdentifier("backup_off_confirm")
                }
            }
            .padding(Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(colors.surfaceContainerLow)
    }
}

/// A text button of a sheet: the touch target's height, semibold.
struct SheetButton: View {
    let label: String
    let tint: ThemeColor
    let action: @MainActor () -> Void

    init(_ label: String, tint: ThemeColor, action: @escaping @MainActor () -> Void) {
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(tint).frame(minHeight: Spacing.touchTarget)
        }
        .buttonStyle(.plain)
    }
}

/// vettid-android's `<b>` emphasis in a text (`AnnotatedString.fromHtml`), as bold runs.
enum Emphasis {
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var rest = Substring(text)
        while !rest.isEmpty {
            let tag = bold ? "</b>" : "<b>"
            let part: Substring
            if let r = rest.range(of: tag) {
                part = rest[..<r.lowerBound]
                rest = rest[r.upperBound...]
            } else {
                part = rest
                rest = ""
            }
            var a = AttributedString(String(part))
            if bold { a.inlinePresentationIntent = .stronglyEmphasized }
            out += a
            bold.toggle()
        }
        return out
    }
}
#endif
