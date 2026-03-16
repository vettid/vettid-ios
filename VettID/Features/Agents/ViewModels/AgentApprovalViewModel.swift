import Foundation

/// ViewModel for agent approval screen.
///
/// Subscribes to agent approval requests from OwnerSpaceClient.
/// On approve/deny, sends the decision to the vault via NATS.
/// The vault then forwards the response to the agent.
@MainActor
final class AgentApprovalViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: AgentApprovalState = .loading

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    // MARK: - Private State

    private var currentRequest: AgentApprovalRequest?
    private var subscriptionTask: Task<Void, Never>?

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    /// Configure with OwnerSpaceClient for NATS communication
    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    deinit {
        subscriptionTask?.cancel()
    }

    // MARK: - Subscription

    /// Start listening for agent approval requests from the vault
    func subscribeToApprovalRequests() {
        guard let client = ownerSpaceClient else { return }

        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            for await request in client.agentApprovalRequests {
                guard let self = self, !Task.isCancelled else { break }
                #if DEBUG
                print("[AgentApprovalVM] Received approval request: \(request.requestId)")
                #endif
                self.currentRequest = request
                self.state = .ready(request)
            }
        }
    }

    /// Load a specific request by ID (if already received)
    func loadRequest(requestId: String) {
        if let request = currentRequest, request.requestId == requestId {
            state = .ready(request)
        }
        // Otherwise wait for it from the subscription; state stays .loading
    }

    // MARK: - Approve

    /// Approve the current agent request
    func approve(requestId: String) async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .processingApproval

        do {
            let response = try await client.sendAndAwaitResponse(
                "agent.approval",
                payload: [
                    "request_id": AnyCodableValue(requestId),
                    "response": AnyCodableValue("approve")
                ],
                timeout: 30
            )

            if response.success {
                state = .approved
                #if DEBUG
                print("[AgentApprovalVM] Request approved: \(requestId)")
                #endif
            } else {
                state = .error(response.error ?? "Failed to approve request")
            }
        } catch {
            #if DEBUG
            print("[AgentApprovalVM] Failed to approve: \(error)")
            #endif
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Deny

    /// Deny the current agent request
    func deny(requestId: String, reason: String = "Owner denied the request") async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .processingDenial

        do {
            let response = try await client.sendAndAwaitResponse(
                "agent.approval",
                payload: [
                    "request_id": AnyCodableValue(requestId),
                    "response": AnyCodableValue("deny"),
                    "reason": AnyCodableValue(reason)
                ],
                timeout: 30
            )

            if response.success {
                state = .denied
                #if DEBUG
                print("[AgentApprovalVM] Request denied: \(requestId)")
                #endif
            } else {
                state = .error(response.error ?? "Failed to deny request")
            }
        } catch {
            #if DEBUG
            print("[AgentApprovalVM] Failed to deny: \(error)")
            #endif
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Reset

    /// Reset to loading state
    func reset() {
        state = .loading
        currentRequest = nil
    }
}
