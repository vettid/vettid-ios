import Foundation
import Combine

// MARK: - Grants Repository

/// In-memory cache for the Grants subsystem (Phase 3.3, parity with
/// Android `GrantsRepository`).
///
/// Single source of truth for:
///   - inbound grants (peers I've granted access to),
///   - outbound grants (grants I've received from peers),
///   - pending requests (incoming requests awaiting my approve/deny).
///
/// `hydrate()` is the only path that fans out to the vault. Writes go
/// through `GrantsClient`; the repository refreshes after every
/// successful mutation. As of Phase 3.3 the subscription to live
/// `forApp.grant.*` events is stubbed — the wire-up lands in Phase 3.9
/// alongside the connection-card synthesis.
@MainActor
final class GrantsRepository: ObservableObject {

    static let shared = GrantsRepository()

    // MARK: - Published state

    @Published private(set) var outbound: [GrantSummary] = []
    @Published private(set) var inbound: [GrantSummary] = []
    @Published private(set) var pending: [PendingRequestSummary] = []
    @Published private(set) var isHydrated: Bool = false
    @Published private(set) var lastError: String?

    // MARK: - Dependencies

    private var client: GrantsClient?

    private init() {}

    /// Wire the repository to a live `GrantsClient`. Call after vault
    /// warm-up (alongside the other `configure()`s on AppState).
    /// Idempotent — passing the same client twice is a no-op.
    func configure(client: GrantsClient) {
        self.client = client
    }

    // MARK: - Hydrate

    func hydrate() async {
        guard let client = client else {
            lastError = "Grants client not configured"
            return
        }
        async let outboundTask = (try? client.listOutbound()) ?? []
        async let inboundTask  = (try? client.listInbound())  ?? []
        async let pendingTask  = (try? client.listPending())  ?? []
        let (out, inb, pen) = await (outboundTask, inboundTask, pendingTask)
        self.outbound = out.compactMap(GrantSummary.from(dict:))
        self.inbound  = inb.compactMap(GrantSummary.from(dict:))
        self.pending  = pen.compactMap(PendingRequestSummary.from(dict:))
        self.isHydrated = true
        self.lastError = nil
    }

    // MARK: - Writes (vault-first; cache refreshes on success)

    /// Owner-side: approve a pending request. Password envelope built
    /// by the caller; on success the request flips to a Grant on the
    /// outbound list. Refreshes the cache from vault.
    func approve(
        requestId: String,
        expiresAt: Date?,
        maxUses: Int?,
        mode: GrantMode?,
        encryptedPasswordHash: String,
        ephemeralPublicKey: String,
        nonce: String,
        salt: String
    ) async throws {
        guard let client = client else { throw GrantsRepositoryError.notConfigured }
        _ = try await client.approve(
            requestId: requestId,
            expiresAt: expiresAt?.timeIntervalSince1970,
            maxUses: maxUses,
            mode: mode?.rawValue,
            encryptedPasswordHash: encryptedPasswordHash,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            salt: salt
        )
        await hydrate()
    }

    /// Owner-side: deny a pending request. Drops it from the pending list.
    func deny(requestId: String, reason: String = "") async throws {
        guard let client = client else { throw GrantsRepositoryError.notConfigured }
        try await client.deny(requestId: requestId, reason: reason)
        await hydrate()
    }

    /// Owner-side: revoke an outstanding outbound grant.
    func revoke(grantId: String, reason: String = "") async throws {
        guard let client = client else { throw GrantsRepositoryError.notConfigured }
        try await client.revoke(grantId: grantId, reason: reason)
        await hydrate()
    }

    /// Receiver-side: pull a value the owner approved. Triggers a
    /// foreground fetch — held-in-trust values aren't persisted. The
    /// vault returns the request_id; the actual value lands on a
    /// `forApp.grant.fetch-result` event (wired in Phase 3.9).
    @discardableResult
    func fetchRemote(grantId: String) async throws -> String {
        guard let client = client else { throw GrantsRepositoryError.notConfigured }
        return try await client.fetchRemote(grantId: grantId)
    }

    /// Send a new outbound grant request to a peer. Returns the
    /// server-issued request_id. Doesn't refresh the outbound list —
    /// requests don't appear there until the owner approves.
    @discardableResult
    func sendRequest(
        connectionId: String,
        kind: GrantItemKind,
        itemRef: String,
        itemLabel: String,
        mode: GrantMode,
        deliverTo: String,
        requestedExpiresAt: Date?,
        requestedMaxUses: Int,
        reason: String
    ) async throws -> String {
        guard let client = client else { throw GrantsRepositoryError.notConfigured }
        return try await client.request(
            connectionId: connectionId,
            itemKind: kind.rawValue,
            itemRef: itemRef,
            itemLabel: itemLabel,
            mode: mode.rawValue,
            deliverTo: deliverTo,
            requestedExpiresAt: requestedExpiresAt?.timeIntervalSince1970 ?? 0,
            requestedMaxUses: requestedMaxUses,
            reason: reason
        )
    }

    // MARK: - Reset

    func reset() {
        outbound = []
        inbound = []
        pending = []
        isHydrated = false
        client = nil
    }
}

enum GrantsRepositoryError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Grants repository not configured — call configure() after vault warm."
        }
    }
}
