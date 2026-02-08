import SwiftUI

@MainActor
class SharedLocationsViewModel: ObservableObject {
    @Published var entries: [SharedLocationEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let ownerSpaceClient: OwnerSpaceClient?
    private var latestLocations: [String: SharedLocationUpdate] = [:]
    private var connectionNames: [String: String] = [:]

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    func startObserving() async {
        isLoading = true
        errorMessage = nil

        // Load connection names first
        // Placeholder — would load from ConnectionsViewModel or NATS
        connectionNames = [:]

        guard let client = ownerSpaceClient else {
            isLoading = false
            return
        }

        do {
            let stream: AsyncStream<SharedLocationUpdate> = try await client.subscribeToVault(
                topic: "location-update",
                type: SharedLocationUpdate.self
            )

            isLoading = false

            for await update in stream {
                latestLocations[update.connectionId] = update
                rebuildEntries()
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func rebuildEntries() {
        let now = Date().timeIntervalSince1970
        let oneHour: TimeInterval = 3600

        entries = latestLocations.map { connectionId, update in
            SharedLocationEntry(
                connectionId: connectionId,
                peerName: connectionNames[connectionId] ?? "Connection",
                latitude: update.latitude,
                longitude: update.longitude,
                accuracy: update.accuracy,
                timestamp: update.timestamp,
                isStale: (now - update.timestamp) > oneHour
            )
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    func clearError() {
        errorMessage = nil
    }
}
