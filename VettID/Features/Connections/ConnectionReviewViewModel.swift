import Foundation

@MainActor
final class ConnectionReviewViewModel: ObservableObject {

    enum State {
        case loading
        case loaded(PeerProfilePreview)
        case error(String)
    }

    enum Effect {
        case accepted
        case declined
    }

    @Published var state: State = .loading
    @Published var isProcessing = false

    var connectionsClient: ConnectionsClient?
    private let connectionId: String
    private let eventId: String?

    init(connectionId: String, eventId: String? = nil) {
        self.connectionId = connectionId
        self.eventId = eventId
    }

    func loadPeerProfile() async {
        state = .loading

        guard let client = connectionsClient else {
            state = .error("Connection service unavailable")
            return
        }

        do {
            let result = try await client.list(status: nil)
            guard let record = result.items.first(where: { $0.connectionId == connectionId }) else {
                state = .error("Connection not found")
                return
            }

            if let profile = record.peerProfile {
                state = .loaded(PeerProfilePreview(from: profile))
            } else {
                // Build a minimal profile from the connection record
                let minimalProfile = PeerProfileData(
                    firstName: record.label,
                    lastName: nil,
                    email: nil,
                    photo: nil,
                    publicKey: record.e2ePublicKey,
                    fields: nil,
                    wallets: nil
                )
                state = .loaded(PeerProfilePreview(from: minimalProfile))
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func accept() async -> Effect? {
        guard let client = connectionsClient else { return nil }
        isProcessing = true
        do {
            _ = try await client.respond(connectionId: connectionId, response: "accept")
            isProcessing = false
            return .accepted
        } catch {
            isProcessing = false
            state = .error(error.localizedDescription)
            return nil
        }
    }

    func decline() async -> Effect? {
        guard let client = connectionsClient else { return nil }
        isProcessing = true
        do {
            _ = try await client.respond(connectionId: connectionId, response: "reject")
            isProcessing = false
            return .declined
        } catch {
            isProcessing = false
            state = .error(error.localizedDescription)
            return nil
        }
    }
}
