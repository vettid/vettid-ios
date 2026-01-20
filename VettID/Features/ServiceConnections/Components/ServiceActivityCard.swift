import SwiftUI

/// Card displaying service activity in a feed
struct ServiceActivityCard: View {
    let activity: ServiceActivity
    let serviceName: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Activity Type Icon
                Image(systemName: activity.type.icon)
                    .foregroundColor(iconColor)
                    .frame(width: 36, height: 36)
                    .background(iconColor.opacity(0.1))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(serviceName)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Spacer()

                        Text(activity.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Text(activity.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var iconColor: Color {
        switch activity.type {
        case .dataRequested: return .blue
        case .dataStored: return .green
        case .auth: return .orange
        case .payment: return .green
        case .messageReceived: return .purple
        case .contractUpdate: return .yellow
        }
    }
}

// MARK: - Activity Dashboard View

/// Full activity dashboard for a service connection
struct ServiceActivityDashboardView: View {
    @StateObject private var viewModel: ServiceActivityDashboardViewModel
    @Environment(\.dismiss) private var dismiss

    init(connectionId: String, serviceConnectionHandler: ServiceConnectionHandler) {
        self._viewModel = StateObject(wrappedValue: ServiceActivityDashboardViewModel(
            connectionId: connectionId,
            serviceConnectionHandler: serviceConnectionHandler
        ))
    }

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading && viewModel.activities.isEmpty {
                    ProgressView()
                } else if viewModel.activities.isEmpty {
                    emptyView
                } else {
                    activityList
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(ServiceActivityType.allCases, id: \.self) { type in
                            Button {
                                viewModel.toggleFilter(type)
                            } label: {
                                Label(
                                    type.displayName,
                                    systemImage: viewModel.activeFilters.contains(type) ? "checkmark" : ""
                                )
                            }
                        }

                        Divider()

                        Button("Clear Filters") {
                            viewModel.clearFilters()
                        }
                    } label: {
                        Image(systemName: viewModel.activeFilters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .task {
                await viewModel.loadActivities()
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 50))
                .foregroundColor(.secondary)

            Text("No Activity")
                .font(.headline)

            Text("Activity with this service will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var activityList: some View {
        List {
            // Summary Section
            if let summary = viewModel.summary {
                Section {
                    ActivitySummaryRow(summary: summary)
                }
            }

            // Grouped Activities
            ForEach(viewModel.groupedActivities.keys.sorted(by: >), id: \.self) { date in
                Section(header: Text(formatSectionHeader(date))) {
                    if let activities = viewModel.groupedActivities[date] {
                        ForEach(activities) { activity in
                            ServiceActivityRow(activity: activity)
                        }
                    }
                }
            }

            // Load More
            if viewModel.hasMore {
                Section {
                    Button {
                        Task { await viewModel.loadMore() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Load More")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refresh()
        }
    }

    private func formatSectionHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day, daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        } else {
            return date.formatted(.dateTime.month().day())
        }
    }
}

// MARK: - Activity Summary Row

struct ActivitySummaryRow: View {
    let summary: ServiceActivitySummary

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Last 30 Days")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                SummaryStatItem(
                    icon: "doc.text",
                    title: "Data Requests",
                    value: "\(summary.totalDataRequests)",
                    color: .blue
                )

                SummaryStatItem(
                    icon: "square.and.arrow.up",
                    title: "Data Shared",
                    value: "\(summary.totalDataStored)",
                    color: .green
                )

                SummaryStatItem(
                    icon: "person.badge.key",
                    title: "Auth Requests",
                    value: "\(summary.totalAuthRequests)",
                    color: .orange
                )

                SummaryStatItem(
                    icon: "creditcard",
                    title: "Payments",
                    value: "\(summary.totalPayments)",
                    color: .purple
                )
            }
        }
        .padding(.vertical, 4)
    }
}

struct SummaryStatItem: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Activity Row

struct ServiceActivityRow: View {
    let activity: ServiceActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.type.icon)
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.1))
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.type.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(activity.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(activity.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var iconColor: Color {
        switch activity.type {
        case .dataRequested: return .blue
        case .dataStored: return .green
        case .auth: return .orange
        case .payment: return .green
        case .messageReceived: return .purple
        case .contractUpdate: return .yellow
        }
    }
}

// MARK: - Activity Dashboard ViewModel

@MainActor
final class ServiceActivityDashboardViewModel: ObservableObject {
    @Published private(set) var activities: [ServiceActivity] = []
    @Published private(set) var summary: ServiceActivitySummary?
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var activeFilters: Set<ServiceActivityType> = []

    private let connectionId: String
    private let serviceConnectionHandler: ServiceConnectionHandler
    private var currentOffset = 0
    private let pageSize = 20

    var groupedActivities: [Date: [ServiceActivity]] {
        let calendar = Calendar.current
        return Dictionary(grouping: filteredActivities) { activity in
            calendar.startOfDay(for: activity.timestamp)
        }
    }

    private var filteredActivities: [ServiceActivity] {
        if activeFilters.isEmpty {
            return activities
        }
        return activities.filter { activeFilters.contains($0.type) }
    }

    init(connectionId: String, serviceConnectionHandler: ServiceConnectionHandler) {
        self.connectionId = connectionId
        self.serviceConnectionHandler = serviceConnectionHandler
    }

    func loadActivities() async {
        guard !isLoading else { return }
        isLoading = true

        do {
            async let activitiesTask = serviceConnectionHandler.listActivity(
                connectionId: connectionId,
                limit: pageSize
            )
            async let summaryTask = serviceConnectionHandler.getActivitySummary(connectionId: connectionId)

            activities = try await activitiesTask
            summary = try await summaryTask
            hasMore = activities.count >= pageSize
            currentOffset = activities.count
        } catch {
            // Handle error silently
        }

        isLoading = false
    }

    func loadMore() async {
        guard !isLoading && hasMore else { return }
        isLoading = true

        do {
            let newActivities = try await serviceConnectionHandler.listActivity(
                connectionId: connectionId,
                limit: pageSize,
                offset: currentOffset
            )
            activities.append(contentsOf: newActivities)
            hasMore = newActivities.count >= pageSize
            currentOffset += newActivities.count
        } catch {
            // Handle error silently
        }

        isLoading = false
    }

    func refresh() async {
        currentOffset = 0
        hasMore = true
        await loadActivities()
    }

    func toggleFilter(_ type: ServiceActivityType) {
        if activeFilters.contains(type) {
            activeFilters.remove(type)
        } else {
            activeFilters.insert(type)
        }
    }

    func clearFilters() {
        activeFilters.removeAll()
    }
}

// MARK: - Activity Type Extension

extension ServiceActivityType: CaseIterable {
    static var allCases: [ServiceActivityType] {
        [.dataRequested, .dataStored, .auth, .payment, .messageReceived, .contractUpdate]
    }
}

#if DEBUG
struct ServiceActivityCard_Previews: PreviewProvider {
    static var previews: some View {
        Text("ServiceActivityCard Preview")
    }
}
#endif
