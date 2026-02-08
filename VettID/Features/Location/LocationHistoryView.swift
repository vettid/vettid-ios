import SwiftUI
import MapKit

// MARK: - Location History View

struct LocationHistoryView: View {
    @StateObject private var viewModel: LocationHistoryViewModel
    @State private var showDeleteConfirmation = false

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self._viewModel = StateObject(wrappedValue: LocationHistoryViewModel(ownerSpaceClient: ownerSpaceClient))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Time filter
            filterBar

            // Content
            if viewModel.isLoading {
                loadingView
            } else if viewModel.entries.isEmpty {
                emptyView
            } else {
                locationList
            }
        }
        .navigationTitle("Location History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { Task { await viewModel.loadHistory() } }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    if !viewModel.entries.isEmpty {
                        Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                            Label("Delete All", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Delete All Locations?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all location history from your vault.")
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .task {
            await viewModel.loadHistory()
        }
        .onChange(of: viewModel.selectedFilter) { _ in
            Task { await viewModel.loadHistory() }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LocationTimeFilter.allCases, id: \.self) { filter in
                    Button(action: { viewModel.selectedFilter = filter }) {
                        Text(filter.displayName)
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                viewModel.selectedFilter == filter
                                    ? Color.blue
                                    : Color(.systemGray5)
                            )
                            .foregroundStyle(viewModel.selectedFilter == filter ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Location List

    private var locationList: some View {
        List {
            ForEach(viewModel.groupedByDate, id: \.0) { dateString, entries in
                Section(dateString) {
                    ForEach(entries) { entry in
                        LocationEntryRow(entry: entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text("Loading location history...")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "location.slash")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("No Location Data")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Enable location tracking in settings to start recording your location history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Location Entry Row

struct LocationEntryRow: View {
    let entry: LocationHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Timestamp
            HStack {
                Image(systemName: entry.isSummary ? "mappin.and.ellipse" : "location.fill")
                    .foregroundStyle(entry.isSummary ? .orange : .blue)
                    .font(.caption)

                Text(formattedTime)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text(entry.source.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            // Coordinates
            Text(String(format: "%.6f, %.6f", entry.latitude, entry.longitude))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Metadata row
            HStack(spacing: 12) {
                if let accuracy = entry.accuracy {
                    Label(String(format: "\u{00B1}%.0fm", accuracy), systemImage: "scope")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let altitude = entry.altitude {
                    Label(String(format: "%.0fm", altitude), systemImage: "mountain.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let speed = entry.speed, speed > 0 {
                    Label(String(format: "%.1f m/s", speed), systemImage: "speedometer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: entry.date)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        LocationHistoryView()
    }
}
