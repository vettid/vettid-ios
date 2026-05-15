import Foundation
import SwiftUI

// MARK: - Actions View Model

/// Coordinates the Actions surface (Phase 3.11). Owns the
/// `ActionsClient`, hydrates the my-actions + pending lists, and
/// surfaces approve/deny actions. Mirrors the structure of
/// `GrantsViewModel` so the two reviewer surfaces feel uniform.
@MainActor
final class ActionsViewModel: ObservableObject {

    @Published private(set) var myActions: [PublishedAction] = []
    @Published private(set) var pending: [PendingActionApproval] = []
    @Published var errorMessage: String?

    /// Injected by `ActionsView.task` from `AppState.actionsClient`.
    var client: ActionsClient?

    // MARK: - Load

    func load() async {
        guard let client = client else {
            errorMessage = "Actions client not configured"
            return
        }
        async let mineTask    = (try? client.listMine()) ?? []
        async let pendingTask = (try? client.listPending()) ?? []
        let (mineRaw, pendingRaw) = await (mineTask, pendingTask)
        myActions = mineRaw.compactMap(PublishedAction.from(dict:))
        pending   = pendingRaw.compactMap(PendingActionApproval.from(dict:))
        errorMessage = nil
    }

    // MARK: - Mutations

    func setEnabled(actionId: String, enabled: Bool) async {
        guard let client = client else { return }
        do {
            try await client.setEnabled(actionId: actionId, enabled: enabled)
            // Reflect the change locally so the row's toggle doesn't
            // bounce back if the user is offline by the time the vault
            // round-trips.
            if let idx = myActions.firstIndex(where: { $0.actionId == actionId }) {
                let old = myActions[idx]
                myActions[idx] = PublishedAction(
                    actionId: old.actionId,
                    name: old.name,
                    descriptionText: old.descriptionText,
                    paramsSchema: old.paramsSchema,
                    authMode: old.authMode,
                    allowlist: old.allowlist,
                    enabled: enabled
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approve(requestId: String) async {
        guard let client = client else { return }
        do {
            try await client.approve(requestId: requestId)
            pending.removeAll { $0.requestId == requestId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deny(requestId: String) async {
        guard let client = client else { return }
        do {
            try await client.deny(requestId: requestId)
            pending.removeAll { $0.requestId == requestId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
