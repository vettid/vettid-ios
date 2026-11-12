#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

/// Settings → Security → **Advanced security** (ANDROID-PLAN 0.1.124 §4 "Advanced security", IOS-PLAN §4.17): a pushed
/// screen of the Settings stack, with the back arrow and the system back gesture. In the plan's order, each row as it was
/// on Security or App (texts, behavior and confirmations unchanged): the owner check's interval, the hold switch and the
/// idle lock, the app lock timeout (while the app lock is on), Attestation, New phone secret (when it applies) and Allow
/// screenshots (turning it on still asks first). [askScreenshots]: that confirmation shows from the start (the debug screen
/// catalog). Mirrors vettid-android `AdvancedSecurityContent`.
public struct AdvancedSecurityContent: View {
    @Environment(\.vettIDColors) private var colors
    let state: SettingsState
    let ownerCheck: OwnerCheckSettingsState
    let actions: SettingsActions
    let ownerCheckActions: OwnerCheckSettingsActions
    let now: Date
    @State private var confirmScreenshots: Bool
    @State private var picker: SettingsPicker?

    public init(
        state: SettingsState,
        ownerCheck: OwnerCheckSettingsState = OwnerCheckSettingsState(),
        actions: SettingsActions = SettingsActions(),
        ownerCheckActions: OwnerCheckSettingsActions = OwnerCheckSettingsActions(),
        now: Date = Date(),
        askScreenshots: Bool = false
    ) {
        self.state = state
        self.ownerCheck = ownerCheck
        self.actions = actions
        self.ownerCheckActions = ownerCheckActions
        self.now = now
        _confirmScreenshots = State(initialValue: askScreenshots)
    }

    public var body: some View {
        DetailScaffold(background: colors.groupedBackground, onBack: actions.back) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle(SettingsStrings.securityAdvanced)
                    SettingsGroup {
                        let rows = AdvancedSecurityRow.rows(state: state, ownerCheck: ownerCheck)
                        ForEach(Array(rows.enumerated()), id: \.element) { i, row in
                            if i > 0 { SettingsDivider() }
                            self.row(row)
                        }
                    }
                    Spacer().frame(height: Spacing.xxl)
                }
            }
            .accessibilityIdentifier("advanced_security_screen")
        }
        .confirmDialog(
            isPresented: $confirmScreenshots, title: SecurityStrings.screenshotsConfirmTitle,
            message: SecurityStrings.screenshotsConfirmBody, confirmLabel: SecurityStrings.screenshotsConfirm,
            dismissLabel: SettingsStrings.cancel, onConfirm: { actions.setScreenshotsAllowed(true) }
        )
        .choiceSheet(item: $picker) { p in
            SettingsPickerSheet(picker: p, state: state, actions: actions) { picker = nil }
        }
    }

    @ViewBuilder private func row(_ row: AdvancedSecurityRow) -> some View {
        switch row {
        case .ownerCheck:
            OwnerCheckSettingsRows(state: ownerCheck, actions: ownerCheckActions, now: now)
        case .appLockTimeout:
            SettingsRow(
                SettingsStrings.securityLockTimeout, icon: .timer, supporting: AppLockRows.timeoutLabel(state.appLockTimeout)
            ) { picker = .timeout }
            .accessibilityIdentifier("app_lock_timeout")
        case .attestation:
            SettingsRow(SettingsStrings.securityAttestation, icon: .verifiedUser, action: actions.attestation)
                .accessibilityIdentifier("attestation")
        case .newPhoneSecret:
            SettingsRow(
                SecurityStrings.newSecret, icon: .key, supporting: SecurityStrings.newSecretRowBody, action: actions.newPhoneSecret
            )
            .accessibilityIdentifier("new_phone_secret_row")
        case .screenshots:
            AllowScreenshotsRow(state: state, actions: actions, confirm: $confirmScreenshots)
        }
    }
}

/// The rows of Advanced security in the plan's order (ANDROID-PLAN 0.1.124 §4 "Advanced security"); each only where it
/// applies: the owner check's rows (the interval, the hold, the idle lock) for a vault that has reported its owner check,
/// the timeout while the app lock is on, New phone secret with a phone secret, and Allow screenshots once a screen holds
/// the secure layer it turns off (``SettingsContent/screenshotsRowShown``).
enum AdvancedSecurityRow: Hashable {
    case ownerCheck, appLockTimeout, attestation, newPhoneSecret, screenshots

    static func rows(
        state: SettingsState, ownerCheck: OwnerCheckSettingsState, screenshotsShown: Bool = SettingsContent.screenshotsRowShown
    ) -> [AdvancedSecurityRow] {
        var out: [AdvancedSecurityRow] = []
        if ownerCheck.view != nil { out.append(.ownerCheck) }
        if state.appLockOn { out.append(.appLockTimeout) }
        out.append(.attestation)
        if state.phoneSecret { out.append(.newPhoneSecret) }
        if screenshotsShown { out.append(.screenshots) }
        return out
    }
}
#endif
