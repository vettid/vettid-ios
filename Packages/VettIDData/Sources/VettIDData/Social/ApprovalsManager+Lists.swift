import Foundation
import VettIDCrypto
import VettIDVault

// The lists Approvals reads (VAULT-MESSAGING §10.4, §10.12, §10.13): what each answered, and why one could not be read.
extension ApprovalsManager {
    /// [e] as the failure of a list read; nil for a list the vault does not have (`unsupported_type`, an older release)
    /// and for a cancellation.
    static func listFailure(_ e: any Error) -> VaultFailure? {
        guard let f = VaultFailures.map(e) as? VaultFailure, f.kind != .notSupported else { return nil }
        return f
    }

    /// What the vault listed: grant requests, critical-item requests and share decisions, each nil when the vault did not
    /// answer (an older release without the list: nothing listed for it, and nothing dropped by it).
    struct Lists {
        var grants: JsonObject?
        var critical: JsonObject?
        var shares: [ShareDecision]?
        /// Why the lists that were not answered failed (not those the vault does not have), in the order read.
        var failures: [VaultFailure] = []

        func approvals(at t: Date) -> [PendingApproval] {
            var out: [PendingApproval] = shares.map { $0.map(PendingApproval.share) } ?? []
            if let grants {
                out += VaultJSON.objects(grants, "pending").compactMap { ApprovalParser.grant($0, at: t) }
                    .map(PendingApproval.grant)
            }
            if let critical {
                out += VaultJSON.objects(critical, "incoming").compactMap { ApprovalParser.critical($0, at: t) }
                    .map(PendingApproval.critical)
            }
            return out
        }

        /// Whether a list that was read says which requests of [p]'s kind are still waiting.
        func covers(_ p: PendingApproval) -> Bool {
            switch p {
            case .grant: grants != nil
            case .critical: critical != nil
            case .share: shares != nil
            default: false
            }
        }
    }

    func readLists(_ o: any ApprovalOps, at t: Date) async -> Lists {
        let names = itemNames()
        var failures: [VaultFailure] = []
        func read<T>(_ body: () async throws -> T) async -> T? {
            do {
                return try await body()
            } catch {
                if let f = Self.listFailure(error) { failures.append(f) }
                return nil
            }
        }
        // The share decisions (§10.12): nil when the vault answered neither list.
        let shares = await read {
            try await SharePending.decisions(
                pendingPage: { try await o.sharePendingPage(after: $0, limit: SharePending.page) },
                rulePage: { try await o.shareRulePage(after: $0) }, names: names, at: t
            )
        }
        let grants = await read { try await o.grantList() }
        let critical = await read { try await o.criticalUseList() }
        return Lists(grants: grants, critical: critical, shares: shares, failures: failures)
    }

    /// Reads the connection requests (listed with the approvals); the failure of the read, if any (``listFailure(_:)``).
    func readRequests(quietly: Bool) async -> VaultFailure? {
        do {
            try await connections.refreshRequests(quietly: quietly)
            return nil
        } catch {
            return Self.listFailure(error)
        }
    }
}
