import SwiftUI
import UIKit

// MARK: - Color Extension (Hex Support)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Filter Options

/// Connection sort options
enum ConnectionSortOption: String, CaseIterable {
    case recentActivity = "Recent Activity"
    case name = "Name"
    case dateConnected = "Date Connected"
    case trustLevel = "Trust Level"

    var icon: String {
        switch self {
        case .recentActivity: return "clock"
        case .name: return "textformat.abc"
        case .dateConnected: return "calendar"
        case .trustLevel: return "star"
        }
    }
}

/// Connection filter state
struct ConnectionFilterState: Equatable {
    var statusFilter: Set<ConnectionStatus> = Set(ConnectionStatus.allCases)
    var trustLevelFilter: Set<TrustLevel> = Set(TrustLevel.allCases)
    var showFavoritesOnly: Bool = false
    var selectedTags: Set<String> = []
    var sortBy: ConnectionSortOption = .recentActivity
    var sortAscending: Bool = false

    var isDefault: Bool {
        statusFilter == Set(ConnectionStatus.allCases) &&
        trustLevelFilter == Set(TrustLevel.allCases) &&
        !showFavoritesOnly &&
        selectedTags.isEmpty &&
        sortBy == .recentActivity &&
        !sortAscending
    }

    static let `default` = ConnectionFilterState()
}

// Add missing allCases to ConnectionStatus
extension ConnectionStatus: CaseIterable {
    static var allCases: [ConnectionStatus] {
        [.pending, .active, .revoked]
    }
}

// MARK: - Connections Filter Sheet

/// Filter sheet for connections list
struct ConnectionsFilterSheet: View {
    @Binding var filterState: ConnectionFilterState
    let availableTags: [String]
    let onApply: () -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                // Status filter
                Section("Status") {
                    ForEach(ConnectionStatus.allCases, id: \.self) { status in
                        FilterToggleRow(
                            title: status.rawValue.capitalized,
                            isSelected: filterState.statusFilter.contains(status),
                            color: statusColor(status)
                        ) {
                            if filterState.statusFilter.contains(status) {
                                filterState.statusFilter.remove(status)
                            } else {
                                filterState.statusFilter.insert(status)
                            }
                        }
                    }
                }

                // Trust level filter
                Section("Trust Level") {
                    ForEach(TrustLevel.allCases, id: \.self) { level in
                        FilterToggleRow(
                            title: level.displayName,
                            isSelected: filterState.trustLevelFilter.contains(level),
                            color: Color(hex: level.color)
                        ) {
                            if filterState.trustLevelFilter.contains(level) {
                                filterState.trustLevelFilter.remove(level)
                            } else {
                                filterState.trustLevelFilter.insert(level)
                            }
                        }
                    }
                }

                // Favorites toggle
                Section {
                    Toggle(isOn: $filterState.showFavoritesOnly) {
                        Label("Favorites Only", systemImage: "star.fill")
                    }
                    .tint(.yellow)
                }

                // Tags filter
                if !availableTags.isEmpty {
                    Section("Tags") {
                        ForEach(availableTags, id: \.self) { tag in
                            FilterToggleRow(
                                title: tag,
                                isSelected: filterState.selectedTags.contains(tag),
                                color: .blue
                            ) {
                                if filterState.selectedTags.contains(tag) {
                                    filterState.selectedTags.remove(tag)
                                } else {
                                    filterState.selectedTags.insert(tag)
                                }
                            }
                        }
                    }
                }

                // Sort options
                Section("Sort By") {
                    ForEach(ConnectionSortOption.allCases, id: \.self) { option in
                        Button {
                            if filterState.sortBy == option {
                                filterState.sortAscending.toggle()
                            } else {
                                filterState.sortBy = option
                                filterState.sortAscending = false
                            }
                        } label: {
                            HStack {
                                Label(option.rawValue, systemImage: option.icon)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if filterState.sortBy == option {
                                    Image(systemName: filterState.sortAscending ? "chevron.up" : "chevron.down")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Filter Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        filterState = .default
                        onReset()
                    }
                    .disabled(filterState.isDefault)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }

    private func statusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .active: return .green
        case .revoked: return .red
        }
    }
}

// MARK: - Filter Toggle Row

private struct FilterToggleRow: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

// MARK: - Active Filters Bar

/// Horizontal bar showing active filters
struct ActiveFiltersBar: View {
    let filterState: ConnectionFilterState
    let onClearAll: () -> Void
    let onRemoveFilter: (String) -> Void

    var body: some View {
        if !filterState.isDefault {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Show favorites chip
                    if filterState.showFavoritesOnly {
                        FilterChip(
                            label: "Favorites",
                            icon: "star.fill",
                            color: .yellow
                        ) {
                            onRemoveFilter("favorites")
                        }
                    }

                    // Status chips (if not all selected)
                    if filterState.statusFilter.count < ConnectionStatus.allCases.count {
                        ForEach(Array(filterState.statusFilter), id: \.self) { status in
                            FilterChip(
                                label: status.rawValue.capitalized,
                                icon: "circle.fill",
                                color: statusColor(status)
                            ) {
                                onRemoveFilter("status:\(status.rawValue)")
                            }
                        }
                    }

                    // Trust level chips (if not all selected)
                    if filterState.trustLevelFilter.count < TrustLevel.allCases.count {
                        ForEach(Array(filterState.trustLevelFilter), id: \.self) { level in
                            FilterChip(
                                label: level.displayName,
                                icon: "star",
                                color: Color(hex: level.color)
                            ) {
                                onRemoveFilter("trust:\(level.rawValue)")
                            }
                        }
                    }

                    // Tag chips
                    ForEach(Array(filterState.selectedTags), id: \.self) { tag in
                        FilterChip(
                            label: tag,
                            icon: "tag.fill",
                            color: .blue
                        ) {
                            onRemoveFilter("tag:\(tag)")
                        }
                    }

                    // Clear all button
                    Button(action: onClearAll) {
                        Text("Clear All")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(UIColor.systemGray6))
        }
    }

    private func statusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .active: return .green
        case .revoked: return .red
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let icon: String
    let color: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)

            Text(label)
                .font(.caption)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .cornerRadius(16)
    }
}

// MARK: - Preview

#if DEBUG
struct ConnectionsFilterSheet_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State private var filterState = ConnectionFilterState()

        var body: some View {
            VStack {
                ActiveFiltersBar(
                    filterState: filterState,
                    onClearAll: { filterState = .default },
                    onRemoveFilter: { _ in }
                )

                ConnectionsFilterSheet(
                    filterState: $filterState,
                    availableTags: ["Work", "Family", "Friends"],
                    onApply: {},
                    onReset: {}
                )
            }
        }
    }

    static var previews: some View {
        PreviewWrapper()
    }
}
#endif
