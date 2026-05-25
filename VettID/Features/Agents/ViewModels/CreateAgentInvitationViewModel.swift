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

        // Area G (Android bbe0f2a + 8649b2f): the name + scope prompt
        // is deferred to AuthorizeAgentView at Stage 2 — Stage 1
        // creates the invite with a "Pending agent…" placeholder so
        // the brief window between Stage 1 and Stage 2 doesn't paint
        // a generic "Agent" label on the connection list.
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "Pending agent…" : trimmed

        state = .creating

        do {
            // Stage 1 of the agent pairing flow — see
            // vettid-agent/docs/AGENT-PAIRING-FLOW.md. The vault mints
            // a 12-char invite code + scoped NATS creds, publishes the
            // payload to invite.<code> on JetStream, and returns the
            // code for the user to paste into `vettid-agent init`.
            // Mirrors Android aecfa99 (vettid-dev 338ca24).
            let response = try await client.sendAndAwaitResponse(
                "agent.create-invite",
                payload: [
                    "label": AnyCodableValue(label)
                ],
                timeout: 30
            )

            if response.success {
                let inviteCode = response.getString("invite_code") ?? ""
                let connectionId = response.getString("connection_id") ?? ""
                let expiresAt = response.getString("expires_at") ?? ""

                guard !inviteCode.isEmpty else {
                    state = .error("Vault returned an empty invite code")
                    return
                }

                state = .created(
                    inviteCode: inviteCode,
                    connectionId: connectionId,
                    expiresAt: expiresAt
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
