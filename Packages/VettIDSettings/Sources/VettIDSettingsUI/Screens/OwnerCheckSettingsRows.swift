#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

/// What the owner-check rows can ask for. Mirrors vettid-android `OwnerCheckSettingsActions`.
public struct OwnerCheckSettingsActions {
    public var setIntervalHours: @MainActor (Int) -> Void = { _ in }
    /// Off opens the check with the hold change (VAULT-MESSAGING §3.6.7); on is a plain setting.
    public var setHold: @MainActor (Bool) -> Void = { _ in }
    public var checkNow: @MainActor () -> Void = {}
    public var dismissOffer: @MainActor () -> Void = {}
    public var dismissError: @MainActor () -> Void = {}

    public init() {}
}

/// The owner-check rows of the Security group (VAULT-MESSAGING §3.6.2, §3.6.7): the interval with the next deadline, a
/// check now, the hold switch; nothing for a vault that has not reported its owner check. Mirrors vettid-android
/// `OwnerCheckSettingsRows`.
struct OwnerCheckSettingsRows: View {
    let state: OwnerCheckSettingsState
    let actions: OwnerCheckSettingsActions
    let now: Date
    @State private var picker: IntervalPicker?

    var body: some View {
        if let v = state.view {
            // One view for the modifiers, so that each is attached once and not to every row.
            VStack(spacing: 0) { rows(v) }
                .choiceSheet(item: $picker) { _ in
                    ChoiceSheet(
                        title: SettingsStrings.ownerCheck,
                        options: OwnerCheckSettingsViewModel.intervalHours.map { ChoiceOption(value: $0, label: Self.every($0)) },
                        selected: state.intervalHours,
                        onPick: { h in
                            picker = nil
                            actions.setIntervalHours(h)
                        },
                        onDismiss: { picker = nil }
                    )
                }
                .confirmDialog(
                    isPresented: Binding(get: { state.offerCheck }, set: { if !$0 { actions.dismissOffer() } }),
                    title: SettingsStrings.ownerCheckOfferTitle, message: SettingsStrings.ownerCheckOfferBody,
                    confirmLabel: SettingsStrings.ownerCheckNow, dismissLabel: SettingsStrings.cancel
                ) {
                    actions.dismissOffer()
                    actions.checkNow()
                }
                .alert(
                    SettingsStrings.ownerCheck,
                    isPresented: Binding(get: { state.error != nil }, set: { if !$0 { actions.dismissError() } })
                ) {
                    Button(SettingsStrings.done, action: actions.dismissError)
                } message: {
                    Text(state.error?.message ?? "")
                }
        }
    }

    @ViewBuilder private func rows(_ v: OwnerCheckView) -> some View {
        let next = v.deadline.map { SettingsStrings.ownerCheckNext(SettingsTimes.full($0)) }
        SettingsDivider()
        SettingsRow(
            SettingsStrings.ownerCheck, icon: .schedule,
            supporting: [Self.every(state.intervalHours), next].compactMap { $0 }.joined(separator: " · ")
        ) { picker = .interval }
        .accessibilityIdentifier("owner_check_interval")
        SettingsDivider()
        SettingsRow(
            SettingsStrings.ownerCheckNow, icon: .verifiedUser, supporting: SettingsStrings.ownerCheckNowBody, showChevron: false,
            action: actions.checkNow
        )
        .accessibilityIdentifier("owner_check_now")
        SettingsDivider()
        SettingsSwitchRow(
            SettingsStrings.ownerCheckHold,
            isOn: Binding(get: { !v.holdOff(now) }, set: { on in if !state.busy { actions.setHold(on) } }),
            icon: .pauseCircle,
            supporting: Self.holdText(v, now: now)
        )
        .accessibilityIdentifier("owner_check_hold")
    }

    /// "Every hour", "Every 4 hours" (the catalog's plural).
    static func every(_ hours: Int) -> String { SettingsStrings.ownerCheckEvery(hours) }

    static func holdText(_ v: OwnerCheckView, now: Date) -> String {
        if !v.holdOff(now) { return SettingsStrings.ownerCheckHoldOnBody }
        if let until = v.holdOffUntil { return SettingsStrings.ownerCheckHoldOffUntil(SettingsTimes.full(until)) }
        return SettingsStrings.ownerCheckHoldOffBody
    }
}

/// The interval's choice is open.
enum IntervalPicker: String, Identifiable {
    case interval

    var id: String { rawValue }
}
#endif
