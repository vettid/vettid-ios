import Foundation
import Combine

// MARK: - Peer Location Request Prompt View Model

/// Phase 5.4 — app-root handler for incoming peer location-request
/// pings (V6).
///
/// A peer can ask us to send our location once via the connection card's
/// "Request location" action. The vault forwards the ping as a
/// `forApp.connection.peer-location-requested` event on the
/// `OwnerSpaceClient.peerLocationTransitions` stream. The prompt has to
/// be visible no matter which screen the user happens to be on — pinning
/// it inside ConnectionDetail would lose requests that arrive while the
/// user is browsing the feed.
///
/// The flow:
///   1. Vault publishes the request → OwnerSpaceClient routes it →
///      this VM's queue.
///   2. VettIDApp observes `pendingRequest` and shows an alert.
///   3. User taps Send → `fulfill()` calls `sendLocationOnce`.
///      User taps Ignore → `dismiss()` clears it.
///   4. Multi-request bursts surface in FIFO order — the next one
///      appears when the current is resolved.
///
/// Parity with Android `PeerLocationRequestPromptViewModel`.
@MainActor
final class PeerLocationRequestPromptViewModel: ObservableObject {

    /// One incoming request. `peerLabel` is the connection alias when
    /// known; nil when we couldn't resolve it (the alert falls back to
    /// "A connection" in that case).
    struct PendingRequest: Equatable, Identifiable {
        let connectionId: String
        let peerLabel: String?
        let requestedAt: String

        var id: String { connectionId + requestedAt }
    }

    @Published private(set) var pendingRequest: PendingRequest?
    @Published private(set) var isSending: Bool = false

    private var queued: [PendingRequest] = []
    private var subscriptionTask: Task<Void, Never>?
    private weak var ownerSpaceClient: OwnerSpaceClient?
    private var labelResolver: (String) async -> String? = { _ in nil }

    deinit {
        subscriptionTask?.cancel()
    }

    /// Wire up the VM to the vault's transition stream. Called from
    /// AppState right after the OwnerSpaceClient is built. Idempotent —
    /// safe to call again after a credential rotation.
    func attach(
        ownerSpaceClient: OwnerSpaceClient,
        resolvePeerLabel: @escaping (String) async -> String? = { _ in nil }
    ) {
        self.ownerSpaceClient = ownerSpaceClient
        self.labelResolver = resolvePeerLabel
        // Pump the NATS subject family in case nothing else has yet —
        // the call is idempotent, so it's safe to invoke from both the
        // prompt VM and any future aggregator that wants the stream.
        ownerSpaceClient.startPeerLocationSubscription()
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            guard let self = self else { return }
            for await transition in ownerSpaceClient.peerLocationTransitions {
                if Task.isCancelled { return }
                guard transition.transition == .requested else { continue }
                let label = await self.labelResolver(transition.connectionId)
                let request = PendingRequest(
                    connectionId: transition.connectionId,
                    peerLabel: label,
                    requestedAt: transition.at
                )
                await MainActor.run {
                    self.enqueue(request)
                }
            }
        }
    }

    /// Send our latest cached location once. Routes through
    /// `location.send-once` on the vault.
    func fulfill() async {
        guard let request = pendingRequest, let client = ownerSpaceClient else { return }
        isSending = true
        defer { isSending = false; advance() }
        do {
            try await client.sendLocationOnce(connectionId: request.connectionId)
        } catch {
            #if DEBUG
            print("[PeerLocationPrompt] sendLocationOnce failed: \(error)")
            #endif
        }
    }

    /// User chose to ignore — discard this request and move to the next
    /// queued one (if any).
    func dismiss() {
        advance()
    }

    // MARK: - Internals

    private func enqueue(_ request: PendingRequest) {
        if pendingRequest == nil {
            pendingRequest = request
        } else if pendingRequest?.connectionId != request.connectionId {
            // Same-connection retries collapse — only queue when it's a
            // different peer. A new request from the same peer just
            // takes the slot of the older one on next advance.
            queued.append(request)
        }
    }

    private func advance() {
        if queued.isEmpty {
            pendingRequest = nil
        } else {
            pendingRequest = queued.removeFirst()
        }
    }
}
