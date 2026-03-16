import Foundation

/// ViewModel for creating agent invitations.
///
/// Calls the vault to create an agent invitation and returns the
/// invite token which can be used with `vettid-agent init`.
@MainActor
final class CreateAgentInvitationViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: CreateAgentInvitationState = .ready

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

    // MARK: - Create Invitation

    /// Create a new agent invitation
    /// - Parameter agentName: The display name/label for the agent
    func createInvitation(agentName: String) async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        let label = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            state = .error("Agent name cannot be empty")
            return
        }

        state = .creating

        do {
            let response = try await client.sendAndAwaitResponse(
                "agent.create-invitation",
                payload: [
                    "label": AnyCodableValue(label)
                ],
                timeout: 30
            )

            if response.success {
                let inviteToken = response.getString("invite_token") ?? ""
                let connectionId = response.getString("connection_id") ?? ""
                let ownerGuid = response.getString("owner_guid") ?? ""

                // Build the short link for vettid-agent init
                let shortLink: String
                if !inviteToken.isEmpty {
                    shortLink = "https://vettid.com/agent?t=\(inviteToken)&o=\(ownerGuid)"
                } else {
                    shortLink = ""
                }

                state = .created(
                    inviteToken: inviteToken,
                    connectionId: connectionId,
                    shortLink: shortLink
                )

                #if DEBUG
                print("[CreateAgentInvitationVM] Invitation created: \(connectionId)")
                #endif
            } else {
                state = .error(response.error ?? "Failed to create invitation")
            }
        } catch {
            #if DEBUG
            print("[CreateAgentInvitationVM] Failed to create invitation: \(error)")
            #endif
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Reset

    /// Reset to ready state
    func reset() {
        state = .ready
    }
}
