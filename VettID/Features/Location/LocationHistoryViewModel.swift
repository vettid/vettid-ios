import SwiftUI

@MainActor
class LocationHistoryViewModel: ObservableObject {
    @Published var entries: [LocationHistoryEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedFilter: LocationTimeFilter = .today
    @Published var successMessage: String?

    private let ownerSpaceClient: OwnerSpaceClient?

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    func loadHistory() async {
        isLoading = true
        errorMessage = nil

        guard let client = ownerSpaceClient else {
            // Demo data when no client
            entries = []
            isLoading = false
            return
        }

        do {
            let request = LocationListRequest(
                startTime: selectedFilter.startDate.timeIntervalSince1970,
                endTime: Date().timeIntervalSince1970,
                limit: 500
            )

            let response: LocationListResponse = try await client.request(
                request,
                topic: "location.list",
                responseType: LocationListResponse.self,
                timeout: 30
            )

            entries = response.points.sorted { $0.timestamp > $1.timestamp }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func deleteAll() async {
        guard let client = ownerSpaceClient else { return }

        do {
            let request = ["action": "delete_all"]
            try await client.sendToVault(request, topic: "location.delete-all")
            entries = []
            successMessage = "Location history deleted"
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    func clearSuccess() {
        successMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Grouped Entries

    var groupedByDate: [(String, [LocationHistoryEntry])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let grouped = Dictionary(grouping: entries) { entry in
            formatter.string(from: entry.date)
        }

        return grouped.sorted { pair1, pair2 in
            guard let date1 = pair1.value.first?.timestamp,
                  let date2 = pair2.value.first?.timestamp else { return false }
            return date1 > date2
        }
    }
}
