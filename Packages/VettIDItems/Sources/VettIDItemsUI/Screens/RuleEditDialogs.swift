#if os(iOS)
import SwiftUI
import VettIDData
import VettIDItems
import VettIDUI

/// The rule editor's dialogs: "Discard changes to this rule?", the rule's deletion and the custom end's date and time
/// (one sheet that goes from the date to the time). Each closes when the app is covered. Mirrors vettid-android
/// `RuleEditDialogs`.
struct RuleEditDialogs: ViewModifier {
    @Environment(\.vettIDCovered) private var covered
    @Environment(\.vettIDColors) private var colors
    let state: RuleEditState
    let name: String
    let actions: RuleEditActions

    private var pickerShown: Binding<Bool> {
        Binding(get: { state.endPicker != nil }, set: { if !$0 { actions.onCancelEnd() } })
    }

    func body(content: Content) -> some View {
        content
            .confirmDialog(
                isPresented: Binding(get: { state.confirmDiscard }, set: { if !$0 { actions.onKeepEditing() } }),
                title: ItemsStrings.ruleDiscardTitle, message: ItemsStrings.discardBody, confirmLabel: ItemsStrings.discard,
                destructive: true, dismissLabel: ItemsStrings.keepEditing, onConfirm: actions.onDiscard
            )
            .confirmDialog(
                isPresented: Binding(get: { state.confirmDelete }, set: { if !$0 { actions.onAskDelete(false) } }),
                title: ItemsStrings.ruleDeleteTitle, message: ItemsStrings.ruleDeleteBody(name), confirmLabel: ItemsStrings.ruleDelete,
                destructive: true, onConfirm: actions.onDelete
            )
            // A cover (the app switcher's, or "This phone can't use your vault") ends the pick: it does not come back with it.
            .closesWhenCovered { if state.endPicker != nil { actions.onCancelEnd() } }
            .sheet(isPresented: uncovered(pickerShown, covered: covered)) {
                if let picker = state.endPicker {
                    EndPickerSheet(picker: picker, current: state.draft.expiresAt, actions: actions)
                        .presentationDetents([.medium, .large])
                        .presentationBackground(colors.surfaceContainerLow.color)
                        .environment(\.vettIDColors, colors)
                }
            }
    }
}

/// The custom end: the day (a calendar from today up to 3,650 days ahead, §10.12) and then the time on it, in the member's
/// zone. The time starts at the end of the day. Mirrors vettid-android `EndDateDialog` and `EndTimeDialog`.
struct EndPickerSheet: View {
    /// The time a custom end starts at: the end of the picked day.
    static let defaultHour = 23
    static let defaultMinute = 59

    let picker: EndPicker
    let current: Date?
    let actions: RuleEditActions
    let zone: TimeZone
    let now: Date
    @State private var day: Date
    @State private var time: Date

    init(picker: EndPicker, current: Date?, actions: RuleEditActions, zone: TimeZone = .current, now: Date = Date()) {
        self.picker = picker
        self.current = current
        self.actions = actions
        self.zone = zone
        self.now = now
        _day = State(initialValue: current.flatMap { $0 > now ? $0 : nil } ?? now)
        let hm = Self.hourAndMinute(of: current, zone: zone)
        _time = State(initialValue: Self.date(hour: hm.hour, minute: hm.minute, zone: zone, now: now))
    }

    static func hourAndMinute(of d: Date?, zone: TimeZone) -> (hour: Int, minute: Int) {
        guard let d else { return (defaultHour, defaultMinute) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? defaultHour, c.minute ?? defaultMinute)
    }

    private static func date(hour: Int, minute: Int, zone: TimeZone, now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    /// Today to the last day 3,650 days ahead.
    private var days: ClosedRange<Date> {
        calendar.startOfDay(for: now)...now.addingTimeInterval(TimeInterval(RuleDraft.maxExpiryDays) * 86_400)
    }

    private var pickedDay: RuleEnds.Day { RuleEnds.Day(day, zone: zone) }

    var body: some View {
        switch picker {
        case .date:
            DialogSheet(
                title: ItemsStrings.ruleExpiry, confirm: ItemsStrings.ruleEndNext,
                enabled: RuleEnds.selectable(pickedDay, now: now, zone: zone), confirmID: "rule_end_date_ok",
                onCancel: actions.onCancelEnd, onConfirm: { actions.onEndDate(pickedDay) }
            ) {
                DatePicker("", selection: $day, in: days, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.timeZone, zone)
                    .accessibilityIdentifier("rule_end_date")
            }
            .accessibilityIdentifier("rule_end_date_sheet")
        case .time:
            DialogSheet(
                title: ItemsStrings.ruleEndTime, confirm: ItemsStrings.ok, enabled: true, confirmID: "rule_end_time_ok",
                onCancel: actions.onCancelEnd,
                onConfirm: {
                    let c = calendar.dateComponents([.hour, .minute], from: time)
                    actions.onEndTime(c.hour ?? Self.defaultHour, c.minute ?? Self.defaultMinute)
                }
            ) {
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .environment(\.timeZone, zone)
                    .accessibilityIdentifier("rule_end_time")
            }
            .accessibilityIdentifier("rule_end_time_sheet")
        }
    }
}
#endif
