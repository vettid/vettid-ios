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
    /// (Release L) `idle_lock.after_seconds`, one of ``IdleLockSetting/choices``.
    public var setIdleLock: @MainActor (Int64) -> Void = { _ in }
    public var dismissIdleNote: @MainActor () -> Void = {}

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
    @State private var idlePicker: IdlePicker?
    @Environment(\.vettIDCovered) private var covered

    var body: some View {
        if let v = state.view {
            // One view for the modifiers, so that each is attached once and not to every row.
            VStack(spacing: 0) { rows(v) }
                .choiceSheet(item: $picker) { _ in
                    ChoiceSheet(
                        title: SettingsStrings.ownerCheck,
                        options: OwnerCheckSettingsViewModel.intervalHours.map { ChoiceOption(value: $0, label: everyText($0)) },
                        selected: state.intervalHours,
                        onPick: { h in
                            picker = nil
                            actions.setIntervalHours(h)
                        },
                        onDismiss: { picker = nil }
                    )
                }
                .choiceSheet(item: $idlePicker) { _ in
                    ChoiceSheet(
                        title: SettingsStrings.idleLock,
                        options: IdleLockSetting.choices.map { ChoiceOption(value: $0, label: idleText($0)) },
                        selected: state.idleLock?.seconds ?? IdleLockSetting.defaultSeconds,
                        onPick: { seconds in
                            idlePicker = nil
                            actions.setIdleLock(seconds)
                        },
                        onDismiss: { idlePicker = nil }
                    )
                }
                // A longer value was chosen: it takes effect after the next check (said once).
                .alert(
                    SettingsStrings.idleLock,
                    isPresented: Binding(get: { state.idleLongerNote }, set: { if !$0 { actions.dismissIdleNote() } })
                ) {
                    Button(SettingsStrings.done, action: actions.dismissIdleNote)
                } message: {
                    Text(SettingsStrings.idleLockNextCheck)
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
                    isPresented: Binding(get: { state.error != nil && !covered }, set: { if !$0 { actions.dismissError() } })
                ) {
                    Button(SettingsStrings.done, action: actions.dismissError)
                } message: {
                    Text(state.error?.message(timeScale: state.timeScale) ?? "")
                }
        }
    }

    @ViewBuilder private func rows(_ v: OwnerCheckView) -> some View {
        let next = v.deadline.map { SettingsStrings.ownerCheckNext(SettingsTimes.full($0)) }
        SettingsDivider()
        SettingsRow(
            SettingsStrings.ownerCheck, icon: .schedule,
            supporting: [everyText(state.intervalHours), next].compactMap { $0 }.joined(separator: " · ")
        ) { picker = .interval }
        .accessibilityIdentifier("owner_check_interval")
        if let note = state.stagingNote {
            SmallNote(note).padding(.horizontal, Spacing.l).padding(.bottom, Spacing.s)
        }
        // (Release L) Beside the interval: the idle lock, for a vault that has it.
        if let idle = state.idleLock { idleRow(idle) }
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

    /// (Release L, VAULT-MESSAGING §3.6.8; ANDROID-PLAN §4 "Locking the vault" part 2) "Lock my vault by itself after", beside
    /// the check's interval: 1 hour to 30 days, no "never"; in real units, and as it runs on a staging vault.
    @ViewBuilder private func idleRow(_ idle: IdleLockSetting) -> some View {
        let lines = [
            idleText(idle.seconds),
            idle.afterNextCheck ? SettingsStrings.idleLockNextCheck : nil,
            SettingsStrings.idleLockBody,
        ].compactMap { $0 }
        SettingsDivider()
        SettingsRow(
            SettingsStrings.idleLock, icon: .lockClock, supporting: lines.joined(separator: "\n")
        ) { idlePicker = .idleLock }
        .accessibilityIdentifier("idle_lock")
    }

    /// A choice in its real units: "1 hour", "1 day", "7 days" (ANDROID-PLAN's names; the setting is whole hours or days),
    /// with the scaled value on a staging vault.
    private func idleText(_ seconds: Int64) -> String {
        state.idleLockText(Self.idleLockUnits(seconds), seconds: seconds)
    }

    static func idleLockUnits(_ seconds: Int64) -> String {
        seconds % IdleLockText.secondsPerDay == 0
            ? SettingsStrings.idleLockDays(Int(seconds / IdleLockText.secondsPerDay))
            : SettingsStrings.idleLockHours(Int(seconds / OwnerCheckSettingsViewModel.secondsPerHour))
    }

    /// "Every hour", "Every 4 hours" (the catalog's plural); on a staging vault with its scaled value ("Every 24 hours
    /// (staging: 1 hour)").
    static func every(_ hours: Int) -> String { SettingsStrings.ownerCheckEvery(hours) }

    private func everyText(_ hours: Int) -> String { state.interval(Self.every(hours), hours: hours) }

    static func holdText(_ v: OwnerCheckView, now: Date) -> String {
        if !v.holdOff(now) { return SettingsStrings.ownerCheckHoldOnBody }
        if let until = v.holdOffUntil { return SettingsStrings.ownerCheckHoldOffUntil(SettingsTimes.full(until)) }
        return SettingsStrings.ownerCheckHoldOffBody
    }
}

/// The idle lock's choice is open.
enum IdlePicker: String, Identifiable {
    case idleLock

    var id: String { rawValue }
}

/// The interval's choice is open.
enum IntervalPicker: String, Identifiable {
    case interval

    var id: String { rawValue }
}
#endif
