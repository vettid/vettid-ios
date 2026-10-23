import Foundation
import VettIDCrypto
import VettIDVault

// The member's decisions in Approvals (VAULT-MESSAGING §6.4, §10.4, §10.12, §10.13, §6.8): each sent, then the request
// leaves the list and its feed item is marked read. The connection requests are decided by the ``ConnectionsManager``.
// Mirrors the decisions of vettid-android `SocialManager`.
extension ApprovalsManager {
    /// Runs a decision; a request the vault no longer knows (`not_found`) leaves the list too. [whole] false: the decision
    /// does not answer the whole request: the body takes out what the vault's answer decided (a share question keeps its
    /// other items, and its feed item is read only once nothing of it is left; VAULT-MESSAGING 0.55.7 §10.12).
    private func decide(_ key: String, whole: Bool = true, _ body: (any ApprovalOps) async throws -> Void) async throws {
        do {
            try await guarded { try await body(try await ops()) }
        } catch let f as VaultFailure where f.kind == .notFound {
            drop(key)
            throw f
        }
        guard whole else { return }
        drop(key)
        decided(key)
    }

    /// Deciding an ask marks its feed item read (ANDROID-PLAN §4 Notifications, §9 question 2).
    func decided(_ key: String) {
        if let (kinds, ref) = FeedAsks.of(key) { onDecided(kinds, ref) }
    }

    private func pending(_ key: String) -> PendingApproval? { approvals.first { $0.key == key } }

    public func approveAuthentication(_ requestID: String, password: String) async throws {
        try await guarded { try await openUnlockWindow(password) }
        try await decide("auth:\(requestID)") { try await $0.authenticateApprove(requestID) }
    }

    public func denyAuthentication(_ requestID: String) async throws {
        try await decide("auth:\(requestID)") { try await $0.authenticateDeny(requestID) }
    }

    public func decideGrant(_ requestID: String, approve: Bool) async throws {
        guard approve else {
            return try await decide("grant:\(requestID)") {
                _ = try await $0.grantDecide(requestID, approve: false, choice: GrantChoice())
            }
        }
        guard case .grant(let g)? = pending("grant:\(requestID)"), !g.grantable.isEmpty else { throw VaultFailure(.notSupported) }
        try await decide("grant:\(requestID)") {
            _ = try await $0.grantDecide(requestID, approve: true, choice: GrantChoice(items: g.grantable))
        }
    }

    public func decideGrant(_ requestID: String, decision: GrantDecision) async throws {
        guard !decision.items.isEmpty else { throw VaultFailure(.other, code: "bad_request") }
        let answers = decision.answers.filter { decision.items.contains($0.key) }.sorted { $0.key < $1.key }
            .map { GrantAnswer(index: $0.key, itemID: $0.value) }
        try await decide("grant:\(requestID)") {
            let choice = GrantChoice(
                items: decision.items, answers: answers.isEmpty ? nil : answers, uses: decision.uses, expiresIn: decision.expiresInSeconds
            )
            _ = try await $0.grantDecide(requestID, approve: true, choice: choice)
        }
    }

    public func approveCriticalUse(_ requestID: String, password: String) async throws -> String? {
        guard case .critical(let c)? = pending("critical:\(requestID)") else { throw VaultFailure(.notFound) }
        // §10.13: offered only for a payload the member saw that matches `payload_sha256`; the hash sealed with the
        // password is the one computed from that payload.
        guard c.payloadVerified, let sha = CriticalUse.sha256(c.payload) else { throw VaultFailure(.other, code: "payload_mismatch") }
        var status: String?
        try await decide("critical:\(requestID)") {
            status = try await $0.criticalUseApprove(requestID, password: password, payloadSha256: sha)
        }
        return status
    }

    public func denyCriticalUse(_ requestID: String) async throws {
        try await decide("critical:\(requestID)") { try await $0.criticalUseDeny(requestID) }
    }

    /// Includes [include] and declines [decline] in one change (§10.12 `share.decide{include, decline}`, 0.21.0: one
    /// flush, nothing changed on an error). A vault before 0.21.0 refuses that form (`unsupported_type`, or `bad_request`
    /// with nothing changed): the two lists then go as two `{items, approve}` calls. A request that is malformed in either
    /// form (more than 500 items together, an item twice or in both lists) is refused here and never split into two calls
    /// that are not atomic (chosen; not in the spec). With the fallback, an inclusion that went through stays when the
    /// decline after it fails: the failure is shown, and the question keeps all its items until the next read.
    public func decideShare(_ ruleID: String, include: [String], decline: [String]) async throws {
        let all = include + decline
        guard !all.isEmpty, all.count <= Self.maxShareDecide, Set(all).count == all.count else {
            throw VaultFailure(.other, code: "bad_request")
        }
        // Only the items the answer decided leave: the question keeps the rest, and the batches noted for a read on its
        // way (VAULT-MESSAGING 0.55.7 §10.12; a question is forgotten only on `not_found`, rule 3).
        let key = "share:\(ruleID)"
        try await decide(key, whole: false) { o in
            var answers: [JsonObject] = []
            do {
                answers.append(try await o.shareDecide(ruleID, include: include, decline: decline))
            } catch let e as VaultOpError where e.code == "bad_request" || e.code == "unsupported_type" {
                if !include.isEmpty { answers.append(try await o.shareDecide(ruleID, items: include, approve: true)) }
                if !decline.isEmpty { answers.append(try await o.shareDecide(ruleID, items: decline, approve: false)) }
            }
            // One answer per item and subject (§10.12): the answer's `included` and `declined` list every item the decision
            // changed, in the subject's other rules too (a vault before 0.23.0 asks per rule and lists only this rule's).
            // An answer with neither member is taken as having changed what was sent (chosen; not in the spec).
            let named = answers.contains { $0.has("included") || $0.has("declined") }
            let changed = answers.flatMap { VaultJSON.strings($0, "included") + VaultJSON.strings($0, "declined") }
            let done = named ? changed : all
            self.shareDecided(ruleID, done)
            // Sent but not named by the answer: the vault did not hold them pending. They leave this rule's question only;
            // that is not a decision, so nothing is noted for a read on its way (as vettid-android does).
            let ignored = Set(all).subtracting(done)
            if !ignored.isEmpty { self.removeShareItems(ignored) { $0.ruleID == ruleID } }
        }
        // The feed item is read only when nothing of the question is left (a batch may have added an item meanwhile).
        if !listed.contains(where: { $0.key == key }), !stored.contains(where: { parsed($0)?.key == key }) { decided(key) }
    }

    /// `share.decide`'s limit: 1–500 distinct items in all (vettid-vault `MaxDecide`).
    static let maxShareDecide = 500

    public func declineDeviceRequest(_ key: String) async throws {
        guard case .device(let d)? = pending(key) else { throw VaultFailure(.notFound) }
        try await decide(key) { o in
            if d.type == "approval.pending" { _ = try await o.approvalDecide(d.id, approve: false) } else { try await o.sessionDeny(d.id) }
        }
    }

    // MARK: - ConnectionRequestsRepository, through the connections

    public var requests: [PendingConnection] { connections.requests }
    public var requestEnds: [String: RequestEnd] { connections.requestEnds }
    public var peerDeclines: [PeerDecline] { connections.peerDeclines }

    public func dismissPeerDecline(_ requestID: String) { connections.dismissPeerDecline(requestID) }

    public func refreshRequests() async throws { try await connections.refreshRequests() }

    public func approveConnection(_ pendingID: String) async throws {
        try await connections.approveConnection(pendingID)
        decided("connection:\(pendingID)")
    }

    public func declineConnection(_ pendingID: String) async throws {
        try await connections.declineConnection(pendingID)
        decided("connection:\(pendingID)")
    }

    public func blockConnectionRequest(_ pendingID: String) async throws {
        try await connections.blockConnectionRequest(pendingID)
        decided("connection:\(pendingID)")
    }

    public func approveOutgoing(_ connectionID: String) async throws { try await connections.approveOutgoing(connectionID) }

    public func declineOutgoing(_ connectionID: String) async throws { try await connections.declineOutgoing(connectionID) }
}
