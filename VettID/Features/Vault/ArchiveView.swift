import SwiftUI

/// View for browsing archived vault items
struct ArchiveView: View {
    @StateObject private var viewModel = ArchiveViewModel()
    @State private var searchText = ""
    @State private var selectedFilter: ArchiveFilter = .all
    @State private var isSelectionMode = false
    @State private var selectedItems: Set<String> = []
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading archive...")
            } else if viewModel.isEmpty {
                emptyView
            } else {
                archiveList
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search archive")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.isEmpty {
                    Button(isSelectionMode ? "Done" : "Select") {
                        isSelectionMode.toggle()
                        if !isSelectionMode {
                            selectedItems.removeAll()
                        }
                    }
                }
            }

            if isSelectionMode && !selectedItems.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete \(selectedItems.count)", systemImage: "trash")
                    }
                }
            }
        }
        .alert("Delete Items", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteItems(selectedItems)
                    selectedItems.removeAll()
                    isSelectionMode = false
                }
            }
        } message: {
            Text("Are you sure you want to permanently delete \(selectedItems.count) item(s)?")
        }
        .task {
            await viewModel.loadArchive()
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Archived Items")
                .font(.headline)

            Text("Items will appear here when they are archived based on your preferences.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Archive List

    private var archiveList: some View {
        List(selection: isSelectionMode ? $selectedItems : nil) {
            // Filter Pills
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ArchiveFilter.allCases, id: \.self) { filter in
                            ArchiveFilterChip(
                                title: filter.displayName,
                                isSelected: selectedFilter == filter
                            ) {
                                selectedFilter = filter
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // Grouped by Month
            ForEach(viewModel.groupedItems(filter: selectedFilter, search: searchText), id: \.month) { group in
                Section(header: Text(group.month)) {
                    ForEach(group.items) { item in
                        ArchiveItemRow(item: item, isSelectionMode: isSelectionMode)
                            .tag(item.id)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isSelectionMode ? .active : .inactive))
    }
}

// MARK: - Archive Filter

enum ArchiveFilter: CaseIterable {
    case all
    case messages
    case connections
    case files
    case credentials

    var displayName: String {
        switch self {
        case .all: return "All"
        case .messages: return "Messages"
        case .connections: return "Connections"
        case .files: return "Files"
        case .credentials: return "Credentials"
        }
    }
}

// MARK: - Archive Filter Chip

struct ArchiveFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundStyle(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Archive Item Row

struct ArchiveItemRow: View {
    let item: ArchivedItem
    let isSelectionMode: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: item.type.iconName)
                .font(.title3)
                .foregroundStyle(item.type.iconColor)
                .frame(width: 32, height: 32)
                .background(item.type.iconColor.opacity(0.15))
                .cornerRadius(8)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Date
            Text(item.archivedAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Archive Item Type

enum ArchivedItemType: String, Codable {
    case message
    case connection
    case file
    case credential

    var iconName: String {
        switch self {
        case .message: return "bubble.left.fill"
        case .connection: return "person.2.fill"
        case .file: return "doc.fill"
        case .credential: return "key.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .message: return .blue
        case .connection: return .green
        case .file: return .orange
        case .credential: return .purple
        }
    }
}

// MARK: - Archived Item Model

struct ArchivedItem: Identifiable {
    let id: String
    let type: ArchivedItemType
    let title: String
    let subtitle: String
    let archivedAt: Date
    let originalId: String
}

// MARK: - Grouped Archive Items

struct GroupedArchiveItems {
    let month: String
    let items: [ArchivedItem]
}

// MARK: - Archive View Model

@MainActor
class ArchiveViewModel: ObservableObject {
    @Published var items: [ArchivedItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var isEmpty: Bool { items.isEmpty }

    func loadArchive() async {
        isLoading = true

        // TODO: Load from NATS/vault via event handlers
        // For now, show empty state
        try? await Task.sleep(nanoseconds: 500_000_000)

        isLoading = false
    }

    func groupedItems(filter: ArchiveFilter, search: String) -> [GroupedArchiveItems] {
        var filtered = items

        // Apply filter
        if filter != .all {
            filtered = filtered.filter { item in
                switch filter {
                case .messages: return item.type == .message
                case .connections: return item.type == .connection
                case .files: return item.type == .file
                case .credentials: return item.type == .credential
                case .all: return true
                }
            }
        }

        // Apply search
        if !search.isEmpty {
            filtered = filtered.filter { item in
                item.title.localizedCaseInsensitiveContains(search) ||
                item.subtitle.localizedCaseInsensitiveContains(search)
            }
        }

        // Group by month
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        let grouped = Dictionary(grouping: filtered) { item in
            let components = calendar.dateComponents([.year, .month], from: item.archivedAt)
            return calendar.date(from: components) ?? item.archivedAt
        }

        return grouped.map { (date, items) in
            GroupedArchiveItems(month: formatter.string(from: date), items: items.sorted { $0.archivedAt > $1.archivedAt })
        }.sorted { first, second in
            guard let firstDate = formatter.date(from: first.month),
                  let secondDate = formatter.date(from: second.month) else {
                return false
            }
            return firstDate > secondDate
        }
    }

    func deleteItems(_ ids: Set<String>) async {
        // TODO: Delete via NATS/vault
        items.removeAll { ids.contains($0.id) }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ArchiveView()
    }
}
