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

    /// A vault call's failure as the approvals say it (``VaultFailures``).
    func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    private func pending(_ key: String) -> PendingApproval? { approvals.first { $0.key == key } }

    public func approveAuthentication(_ requestID: String, password: String) async throws {
        // §10.4 "Approval documents": a challenge held with a document is approved only over it
        // (``approveAuthentication(_:password:document:)``). The screen decides from the request it shows as well.
        if case .authentication(let r)? = pending("auth:\(requestID)"), r.hasDocument {
            throw VaultFailure(.other, code: Self.documentNotShown)
        }
        try await guarded { try await openUnlockWindow(password) }
        try await decide("auth:\(requestID)") { try await $0.authenticateApprove(requestID, documentSha256: nil) }
    }

    public func authenticationDocument(_ request: AuthenticationRequest) async throws
        -> Result<ApprovalDocument, ApprovalDocument.Failure> {
        // Only a challenge that names a document is asked for one: for any other the vault answers not_found, which would
        // drop a live ask.
        guard request.hasDocument else { return .failure(.hash) }
        let key = "auth:\(request.requestID)"
        let answer: String?
        do {
            answer = try await guarded { try await ops().authenticateDocument(request.requestID) }
        } catch let f as VaultFailure where f.kind == .notFound {
            // The vault also answers not_found for a challenge without a document; this ask named one, so not_found
            // means it ended, as for a decision.
            drop(key)
            throw f
        }
        // An answer without a `document` string is no document.
        guard let base64 = answer else { return .failure(.encoding) }
        return ApprovalDocument.check(
            base64, sha256: request.documentSha256, size: request.documentSize, context: request.context
        )
    }

    public func approveAuthentication(_ request: AuthenticationRequest, password: String, document: ApprovalDocument)
        async throws -> DocumentApproval {
        // Only the document this request announced, before anything is opened or sent.
        guard request.hasDocument, document.sha256 == request.documentSha256 else {
            throw VaultFailure(.other, code: Self.documentMismatch)
        }
        try await guarded { try await openUnlockWindow(password) }
        let key = "auth:\(request.requestID)"
        do {
            try await decide(key) { try await $0.authenticateApprove(request.requestID, documentSha256: document.sha256) }
            return .approved
        } catch let f as VaultFailure where f.kind == .vaultCode(Self.documentNotFetched) {
            let again = try await authenticationDocument(request)
            guard case .success(let fetched) = again, fetched == document else { return .changed(again) }
            try await decide(key) { try await $0.authenticateApprove(request.requestID, documentSha256: fetched.sha256) }
            return .approved
        }
    }

    /// The vault's answer to an approval with the hash of a document this device has not fetched (0.89.0).
    static let documentNotFetched = "document_not_fetched"
    /// The app's own refusal of a document that is not the one its request announced (never sent to the vault).
    static let documentMismatch = "document_mismatch"
    /// The app's own refusal to approve a challenge with a document without it (never sent to the vault).
    static let documentNotShown = "document_not_shown"

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
        // The subject's questions before the decision: one answer per item and subject (§10.12) can empty the others too.
        let subjectKeys = shareKeys(subjectOf: ruleID)
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
        // A feed item is read only when nothing of its question is left (a batch may have added an item meanwhile): the
        // decided rule's, and those of the subject's other rules the decision emptied.
        for k in subjectKeys.sorted() where !holds(k) { decided(k) }
    }

    /// `share.decide`'s limit: 1–500 distinct items in all (vettid-vault `MaxDecide`).
    static let maxShareDecide = 500

    public func declineDeviceRequest(_ key: String) async throws {
        guard case .device(let d)? = pending(key) else { throw VaultFailure(.notFound) }
        try await decide(key) { o in
            if d.type == "approval.pending" { _ = try await o.approvalDecide(d.id, approve: false) } else { try await o.sessionDeny(d.id) }
        }
    }

    public func approveDeviceRequest(
        _ shown: DeviceRequest, generation: Int, stillShown: @escaping @MainActor () -> Bool
    ) async throws -> DeviceDecision {
        // Looked up as the list shows it (a replaced or expired approval is gone, a differing one is deny only), never through the
        // kept events. Only the request the member was shown: every member compared as bytes (its `exp`, names, device and what
        // it asks) but not its time of arrival, so the same `approval.pending` delivered again is the same request; no lock since
        // the screen showed it ([generation]); and the screen still showing it as it did ([stillShown]).
        let key = PendingApproval.device(shown).key
        guard shown.type == Self.approvalType, case .device(let d)? = pending(key) else { throw VaultFailure(.notFound) }
        guard generation == forgetCount, d.sameContent(as: shown), stillShown() else { throw VaultFailure(.requestChanged) }
        try checkApprovable(d)
        var result: String?
        var goneAtSend = false
        do {
            try await decide(key) { o in
                // A run with a `cwd` and no `member_folder` only when the item's settings, read now for the request's own agent and
                // item, carry `run` without `folders` (AA8): read here, after `ops()` and before the last check, which has no
                // `await` between it and the send. Its answer is judged after that check, so a request that is gone or changed
                // meanwhile says so, not that its `cwd` is not allowed.
                var cwdAllowed = true
                if case .itemRun(let run)? = d.held, run.hasCwd {
                    cwdAllowed = await self.runCwdRule(agentID: d.deviceID ?? "", itemID: run.itemID) == true
                }
                // `ops()` and that read may have waited, and an event, a list read, a lock or the item list may have changed the
                // approval since the checks: judged again here, with no `await` between this and the send.
                guard case .device(let now)? = self.pending(key) else {
                    goneAtSend = true
                    throw VaultFailure(.requestChanged)
                }
                guard generation == self.forgetCount, now.sameContent(as: shown), !self.mismatched.contains(key),
                      !self.replaced.contains(key), let held = now.held, held.approvable,
                      HeldApprovals.nameable(held, self.itemCache()), stillShown() else { throw VaultFailure(.requestChanged) }
                guard cwdAllowed else { throw VaultFailure(.notSupported) }
                result = try await o.approvalDecide(d.id, approve: true)
            }
        } catch let f as VaultFailure where goneAtSend && f.kind == .requestChanged {
            // Expired, or dropped by a lock, while the session opened: no longer waiting here. Thrown past `decide`, which would
            // count a `not_found` as the vault's own and forget the approval.
            throw VaultFailure(.notFound)
        }
        return DeviceDecision(result: result)
    }

    /// Only what is read in full and whose item and field the item list names. Else nothing sent: ``FailureKind/notSupported``
    /// for what this version does not approve, ``FailureKind/requestChanged`` for an item or field the list no longer names. A
    /// run's `cwd` rule is read in the decision, after the session opens (``approveDeviceRequest(_:generation:stillShown:)``).
    private func checkApprovable(_ d: DeviceRequest) throws {
        guard let held = d.held, held.approvable else { throw VaultFailure(.notSupported) }
        guard HeldApprovals.nameable(held, itemCache()) else { throw VaultFailure(.requestChanged) }
    }

    public func runCwdRule(agentID: String, itemID: String) async -> Bool? {
        do {
            // Settings listed for another agent are not this agent's.
            return ItemWaysRules.runCwdAllowed(try await itemWaysRead(agentID, itemID), agentID: agentID, itemID: itemID)
        } catch {
            return nil
        }
    }

    public func programRecorded(agentID: String, itemID: String, program: String, sha256: String) async -> Bool {
        guard let read = (try? await itemWaysRead(agentID, itemID)).flatMap({ $0 }), !read.foreign, read.agentID.sameBytes(agentID),
              let programs = read.ways?.run?.programs else { return false }
        // The matched entry records the run's file at its `path` (a bare-name entry's `program` is only its name).
        return programs.contains { ($0.path.map { $0.sameBytes(program) } ?? false) && ($0.sha256.map { $0.sameBytes(sha256) } ?? false) }
    }

    /// Drops every open ask of the device [deviceID] (its session request and its held approvals) and marks their feed
    /// items read. The vault sends `approval.decided` and `sync.event` `device.session` to the member's other devices only
    /// (§10.1), so the app that ended the device's access or unlinked it calls this itself, once the vault has answered
    /// (VAULT-MESSAGING 0.77.0 §6.8). A denied session request is not this: it ends only that request, which
    /// ``declineDeviceRequest(_:)`` drops, and the device's held approvals stay.
    public func dropAsks(ofDevice deviceID: String) {
        let keys = (stored.compactMap { parsed($0) } + listed).compactMap { p -> String? in
            if case .device(let d) = p, d.deviceID == deviceID { p.key } else { nil }
        }
        for key in Set(keys).sorted() {
            drop(key)
            decided(key)
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
