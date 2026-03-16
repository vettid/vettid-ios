import Foundation

/// ViewModel for agent management screen.
///
/// Lists connected agents, supports revoking connections.
/// Uses OwnerSpaceClient.sendAndAwaitResponse for vault communication.
@MainActor
final class AgentManagementViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: AgentManagementState = .loading

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    /// Configure with OwnerSpaceClient for NATS communication
    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Load Agents

    /// Load agent connections from the vault
    func loadAgents() async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .loading

        do {
            let response = try await client.sendAndAwaitResponse(
                "agent.list",
                payload: [:],
                timeout: 30
            )

            if response.success {
                let agentsArray = response.getArray("agents") ?? []

                if agentsArray.isEmpty {
                    state = .empty
                } else {
                    let agents = agentsArray.map { AgentConnection.from(dict: $0) }
                    state = .loaded(agents)
                }
            } else {
                state = .error(response.error ?? "Failed to load agents")
            }
        } catch {
            #if DEBUG
            print("[AgentManagementVM] Failed to load agents: \(error)")
            #endif
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Revoke Agent

    /// Revoke an agent connection
    func revokeAgent(connectionId: String) async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        do {
            let response = try await client.sendAndAwaitResponse(
                "agent.revoke",
                payload: [
                    "connection_id": AnyCodableValue(connectionId)
                ],
                timeout: 30
            )

            if response.success {
                #if DEBUG
                print("[AgentManagementVM] Agent revoked: \(connectionId)")
                #endif
                // Refresh the list after revoking
                await loadAgents()
            } else {
                #if DEBUG
                print("[AgentManagementVM] Revoke failed: \(response.error ?? "Unknown error")")
                #endif
                // Show error but keep existing state
                if case .loaded = state {
                    // Stay on the loaded state; caller can handle error via return
                } else {
                    state = .error(response.error ?? "Failed to revoke agent")
                }
            }
        } catch {
            #if DEBUG
            print("[AgentManagementVM] Failed to revoke agent: \(error)")
            #endif
        }
    }
}
