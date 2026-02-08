import SwiftUI

// MARK: - Shared Locations View

struct SharedLocationsView: View {
    @StateObject private var viewModel: SharedLocationsViewModel

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self._viewModel = StateObject(wrappedValue: SharedLocationsViewModel(ownerSpaceClient: ownerSpaceClient))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.entries.isEmpty {
                emptyView
            } else {
                locationsList
            }
        }
        .navigationTitle("Shared Locations")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .task {
            await viewModel.startObserving()
        }
    }

    // MARK: - Locations List

    private var locationsList: some View {
        List(viewModel.entries) { entry in
            SharedLocationRow(entry: entry)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text("Listening for shared locations...")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("No Shared Locations")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Locations shared by your connections will appear here in real-time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Shared Location Row

struct SharedLocationRow: View {
    let entry: SharedLocationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.blue)

                Text(entry.peerName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if entry.isStale {
                    Text("Stale")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            // Coordinates
            Text(String(format: "%.6f, %.6f", entry.latitude, entry.longitude))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Metadata
            HStack(spacing: 12) {
                if let accuracy = entry.accuracy {
                    Label(String(format: "\u{00B1}%.0fm", accuracy), systemImage: "scope")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Label(formattedTime, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var formattedTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: entry.date, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SharedLocationsView()
    }
}
