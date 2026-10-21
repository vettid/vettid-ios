#if os(iOS)
import SwiftUI
import VettIDData
import VettIDHistory
import VettIDUI

/// History's filter chips (ANDROID-PLAN §4 History): the dates (presets, or "Choose dates…" for a range), a connection,
/// "All" and one group at a time, each group's chip in its colour; "✕ Clear" at the row's end while a filter is on.
/// Mirrors vettid-android `FilterRow`.
struct HistoryFilterRow: View {
    let state: HistoryState
    let actions: HistoryActions
    @State private var pickRange = false
    @State private var pickConnection = false

    var body: some View {
        FilterChipRow(filtering: !state.filter.isEmpty, onClear: actions.onClearFilters) {
            Menu {
                ForEach(DatePreset.allCases, id: \.self) { p in
                    Button(Self.presetLabel(p)) {
                        if p == .custom { pickRange = true } else { actions.onDates(p, nil, nil) }
                    }
                }
            } label: {
                MenuChip(label: Self.dateLabel(state), selected: state.datePreset != .any)
            }
            .accessibilityIdentifier("history_dates")
            Button { pickConnection = true } label: {
                MenuChip(
                    label: state.filter.connectionID.map(state.connectionLabel) ?? HistoryStrings.connectionAny,
                    selected: state.filter.connectionID != nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("history_connection")
            VettIDFilterChip(HistoryStrings.categoryAll, selected: state.filter.category == nil) { actions.onCategory(nil) }
                .accessibilityIdentifier("history_category_all")
            ForEach(AuditCategory.filters, id: \.self) { c in
                CategoryChip(category: c, selected: state.filter.category == c) { actions.onCategory(c) }
                    .accessibilityIdentifier("history_category_\(c.rawValue)")
            }
        }
        .padding(.vertical, Spacing.xs)
        .sheet(isPresented: $pickRange) {
            HistoryRangeSheet(onCancel: { pickRange = false }) { since, until in
                pickRange = false
                actions.onDates(.custom, since, until)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $pickConnection) {
            HistoryConnectionSheet(state: state, onCancel: { pickConnection = false }) { id in
                pickConnection = false
                actions.onConnection(id)
            }
            .presentationDetents([.medium, .large])
        }
    }

    static func presetLabel(_ p: DatePreset) -> String {
        switch p {
        case .any: HistoryStrings.dateAny
        case .today: HistoryStrings.dateDay
        case .week: HistoryStrings.dateWeek
        case .month: HistoryStrings.dateMonth
        case .custom: HistoryStrings.dateCustom
        }
    }

    /// The date chip: the preset, or a picked range's first and last day.
    static func dateLabel(_ state: HistoryState, now: Date = Date()) -> String {
        guard state.datePreset == .custom, let since = state.filter.since else { return presetLabel(state.datePreset) }
        return HistoryTimes.range(since: since, until: state.filter.until, now: now)
    }
}

/// A filter chip that opens a choice (the dates, the connection): its value and a chevron.
private struct MenuChip: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let selected: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(label).vettIDFont(.labelLarge).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
        }
        .fixedSize()
        .foregroundStyle(selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)
        .padding(.horizontal, Spacing.m + Spacing.xxs)
        .frame(minHeight: 32)
        .background(selected ? colors.secondaryContainer : ThemeColor(0, alpha: 0), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? ThemeColor(0, alpha: 0) : colors.outline, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A group's chip in its colour (owner request 2026-10-09): the icon always, the fill when chosen.
private struct CategoryChip: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.colorScheme) private var scheme
    let category: AuditCategory
    let selected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        let hue = HistoryVisuals.colors(category, scheme)
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                HistoryVisuals.symbol(category).image
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hue.onContainer)
                    .frame(width: 22, height: 22)
                    .background(hue.container, in: Circle())
                    .accessibilityHidden(true)
                Text(AuditKinds.categoryLabel(category)).vettIDFont(.labelLarge).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(selected ? hue.onContainer : colors.onSurfaceVariant)
            .padding(.leading, Spacing.xs)
            .padding(.trailing, Spacing.m)
            .frame(minHeight: 32)
            .background(selected ? hue.container : ThemeColor(0, alpha: 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? ThemeColor(0, alpha: 0) : colors.outline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// "Choose dates…": the first and the last day, whole local days (``HistoryFilters/days(_:_:calendar:)``): a calendar
/// for the first day and a date field for the last, in place of Android's range picker, which iOS does not have (chosen;
/// not in the spec).
struct HistoryRangeSheet: View {
    let onCancel: @MainActor () -> Void
    let onPick: @MainActor (Date, Date) -> Void
    @State private var first = Date()
    @State private var last = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(HistoryStrings.datePick, selection: $first, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("history_range_first")
                DatePicker(HistoryStrings.datePick, selection: $last, in: ...Date(), displayedComponents: .date)
                    .accessibilityIdentifier("history_range_last")
            }
            .navigationTitle(HistoryStrings.datePick)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(HistoryStrings.cancel, action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(HistoryStrings.ok) {
                        let r = HistoryFilters.days(first, last, calendar: .current)
                        onPick(r.since, r.until)
                    }
                    .accessibilityIdentifier("history_range_ok")
                }
            }
        }
        .onChange(of: first) { _, new in if last < new { last = new } }
    }
}

/// The connection filter: "All connections", then each connection by name.
struct HistoryConnectionSheet: View {
    let state: HistoryState
    let onCancel: @MainActor () -> Void
    let onPick: @MainActor (String?) -> Void

    var body: some View {
        NavigationStack {
            List {
                choice(HistoryStrings.connectionAny, selected: state.filter.connectionID == nil) { onPick(nil) }
                ForEach(state.connections) { c in
                    choice(c.name, selected: state.filter.connectionID == c.id) { onPick(c.id) }
                }
            }
            .navigationTitle(HistoryStrings.connectionPick)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(HistoryStrings.cancel, action: onCancel) } }
        }
        .accessibilityIdentifier("history_connection_sheet")
    }

    private func choice(_ label: String, selected: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack {
                (selected ? VettIDSymbol.radioChecked : VettIDSymbol.radioUnchecked).image.accessibilityHidden(true)
                Text(label).vettIDFont(.bodyLarge)
            }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
#endif
