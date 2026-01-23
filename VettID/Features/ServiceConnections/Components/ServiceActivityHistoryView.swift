import SwiftUI

/// View displaying activity history for a service connection
struct ServiceActivityHistoryView: View {
    let connectionId: String
    @StateObject private var viewModel: ServiceActivityHistoryViewModel

    init(connectionId: String) {
        self.connectionId = connectionId
        self._viewModel = StateObject(wrappedValue: ServiceActivityHistoryViewModel(connectionId: connectionId))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.activities.isEmpty {
                loadingView
            } else if viewModel.activities.isEmpty {
                emptyView
            } else {
                activityList
            }
        }
        .navigationTitle("Activity History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                filterMenu
            }
        }
        .task {
            await viewModel.loadActivities()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading activity...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Activity Yet")
                .font(.headline)

            Text("Activity with this service will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Activity List

    private var activityList: some View {
        List {
            // Summary card
            Section {
                activitySummaryCard
            }

            // Grouped by date
            ForEach(viewModel.groupedActivities, id: \.date) { group in
                Section {
                    ForEach(group.activities) { activity in
                        ActivityRow(activity: activity)
                    }
                } header: {
                    Text(formatSectionDate(group.date))
                }
            }

            // Load more
            if viewModel.hasMore {
                Section {
                    Button(action: {
                        Task {
                            await viewModel.loadMore()
                        }
                    }) {
                        HStack {
                            Spacer()
                            if viewModel.isLoadingMore {
                                ProgressView()
                            } else {
                                Text("Load More")
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Summary Card

    private var activitySummaryCard: some View {
        VStack(spacing: 16) {
            // Stats row
            HStack(spacing: 0) {
                statItem(
                    value: "\(viewModel.summary?.totalDataRequests ?? 0)",
                    label: "Data Requests",
                    icon: "doc.text.fill",
                    color: .blue
                )

                Divider()
                    .frame(height: 40)

                statItem(
                    value: "\(viewModel.summary?.totalAuthRequests ?? 0)",
                    label: "Auth Requests",
                    icon: "person.badge.key.fill",
                    color: .green
                )

                Divider()
                    .frame(height: 40)

                statItem(
                    value: "\(viewModel.summary?.totalPayments ?? 0)",
                    label: "Payments",
                    icon: "creditcard.fill",
                    color: .orange
                )
            }

            // Last activity
            if let lastActivity = viewModel.summary?.lastActivityAt {
                HStack {
                    Text("Last activity:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(lastActivity.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func statItem(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(value)
                    .fontWeight(.bold)
            }
            .font(.subheadline)

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Filter Menu

    private var filterMenu: some View {
        Menu {
            Section("Filter by Type") {
                Button {
                    viewModel.selectedFilter = nil
                } label: {
                    Label("All Activity", systemImage: viewModel.selectedFilter == nil ? "checkmark" : "")
                }

                ForEach(ServiceActivityType.allCases, id: \.self) { type in
                    Button {
                        viewModel.selectedFilter = type
                    } label: {
                        Label(type.displayName, systemImage: viewModel.selectedFilter == type ? "checkmark" : "")
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - Helpers

    private func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

// MARK: - Activity Row

struct ActivityRow: View {
    let activity: ServiceActivity

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(activity.type.color.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: activity.type.icon)
                    .foregroundColor(activity.type.color)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.type.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(activity.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Fields or amount
                if let fields = activity.fields, !fields.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(fields.prefix(3), id: \.self) { field in
                            Text(ServiceFieldType(rawValue: field)?.displayLabel ?? field)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .cornerRadius(4)
                        }

                        if fields.count > 3 {
                            Text("+\(fields.count - 3)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let amount = activity.amount {
                    Text(amount.formatted)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            // Timestamp
            VStack(alignment: .trailing, spacing: 4) {
                Text(activity.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)

                // Status badge
                statusBadge(activity.status)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(_ status: String) -> some View {
        let color: Color = switch status.lowercased() {
        case "approved", "success": .green
        case "denied", "failed": .red
        case "pending": .orange
        default: .secondary
        }

        return Text(status.capitalized)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }
}

// MARK: - Activity Type Extension

extension ServiceActivityType: CaseIterable {
    static var allCases: [ServiceActivityType] {
        [.dataRequested, .dataStored, .auth, .payment, .messageReceived, .contractUpdate]
    }

    var color: Color {
        switch self {
        case .dataRequested: return .blue
        case .dataStored: return .purple
        case .auth: return .green
        case .payment: return .orange
        case .messageReceived: return .blue
        case .contractUpdate: return .purple
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ServiceActivityHistoryViewModel: ObservableObject {
    @Published private(set) var activities: [ServiceActivity] = []
    @Published private(set) var summary: ServiceActivitySummary?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    @Published var selectedFilter: ServiceActivityType?

    private let connectionId: String
    private var currentPage = 1

    init(connectionId: String) {
        self.connectionId = connectionId
    }

    struct ActivityGroup {
        let date: Date
        let activities: [ServiceActivity]
    }

    var groupedActivities: [ActivityGroup] {
        let calendar = Calendar.current
        var groups: [Date: [ServiceActivity]] = [:]

        for activity in filteredActivities {
            let dayStart = calendar.startOfDay(for: activity.timestamp)
            groups[dayStart, default: []].append(activity)
        }

        return groups
            .map { ActivityGroup(date: $0.key, activities: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.date > $1.date }
    }

    var filteredActivities: [ServiceActivity] {
        guard let filter = selectedFilter else {
            return activities
        }
        return activities.filter { $0.type == filter }
    }

    func loadActivities() async {
        guard !isLoading else { return }
        isLoading = true

        #if DEBUG
        try? await Task.sleep(nanoseconds: 500_000_000)
        activities = mockActivities
        summary = mockSummary
        hasMore = false
        #endif

        isLoading = false
    }

    func refresh() async {
        currentPage = 1
        await loadActivities()
    }

    func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true

        // In production, fetch next page
        hasMore = false

        isLoadingMore = false
    }

    #if DEBUG
    private var mockActivities: [ServiceActivity] {
        [
            ServiceActivity(
                id: "act-1",
                connectionId: connectionId,
                type: .auth,
                description: "Login verification from San Francisco, CA",
                fields: nil,
                amount: nil,
                status: "approved",
                timestamp: Date().addingTimeInterval(-1800)
            ),
            ServiceActivity(
                id: "act-2",
                connectionId: connectionId,
                type: .dataRequested,
                description: "Requested email and display name",
                fields: ["email", "display_name"],
                amount: nil,
                status: "approved",
                timestamp: Date().addingTimeInterval(-7200)
            ),
            ServiceActivity(
                id: "act-3",
                connectionId: connectionId,
                type: .payment,
                description: "Purchase at Example Store",
                fields: nil,
                amount: Money(amount: 49.99, currency: "USD"),
                status: "approved",
                timestamp: Date().addingTimeInterval(-86400)
            ),
            ServiceActivity(
                id: "act-4",
                connectionId: connectionId,
                type: .messageReceived,
                description: "Order confirmation for your recent purchase",
                fields: nil,
                amount: nil,
                status: "delivered",
                timestamp: Date().addingTimeInterval(-86400 - 3600)
            ),
            ServiceActivity(
                id: "act-5",
                connectionId: connectionId,
                type: .dataRequested,
                description: "Requested shipping address",
                fields: ["address"],
                amount: nil,
                status: "denied",
                timestamp: Date().addingTimeInterval(-86400 * 2)
            ),
            ServiceActivity(
                id: "act-6",
                connectionId: connectionId,
                type: .contractUpdate,
                description: "Contract updated to version 2",
                fields: nil,
                amount: nil,
                status: "accepted",
                timestamp: Date().addingTimeInterval(-86400 * 7)
            )
        ]
    }

    private var mockSummary: ServiceActivitySummary {
        ServiceActivitySummary(
            connectionId: connectionId,
            totalDataRequests: 12,
            totalDataStored: 3,
            totalAuthRequests: 8,
            totalPayments: 2,
            totalPaymentAmount: Money(amount: 149.98, currency: "USD"),
            lastActivityAt: Date().addingTimeInterval(-1800),
            activityThisMonth: 5
        )
    }
    #endif
}

// MARK: - Preview

#if DEBUG
struct ServiceActivityHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ServiceActivityHistoryView(connectionId: "test-connection")
        }
    }
}
#endif
