import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// The vault calls behind ``ApprovalsManager`` (VAULT-MESSAGING §10.4, §10.12, §10.13, §6.8), one per type, as
/// ``VaultApi`` has them; a test passes its own.
public protocol ApprovalOps: Sendable {
    func authenticateApprove(_ requestID: String) async throws
    func authenticateDeny(_ requestID: String) async throws
    func grantList() async throws -> JsonObject
    func grantDecide(_ requestID: String, approve: Bool, choice: GrantChoice) async throws -> JsonObject
    func criticalUseList() async throws -> JsonObject
    func criticalUseGet(_ requestID: String) async throws -> JsonObject
    func criticalUseApprove(_ requestID: String, password: String, payloadSha256: [UInt8]) async throws -> String?
    func criticalUseDeny(_ requestID: String) async throws
    func shareDecide(_ ruleID: String, include: [String], decline: [String]) async throws -> JsonObject
    func shareDecide(_ ruleID: String, items: [String], approve: Bool) async throws -> JsonObject
    func sessionDeny(_ requestID: String) async throws
    func approvalDecide(_ approvalID: String, approve: Bool) async throws -> String?
    /// One page of `share.pending.list` (0.21.0, §10.12) from [after].
    func sharePendingPage(after: String?, limit: Int?) async throws -> JsonObject
    /// One page of `share.rule.list` from [after]: the rules' tags and the subject's other rules.
    func shareRulePage(after: String?) async throws -> JsonObject
    /// One page of `pending.list` (VAULT-MESSAGING 0.70.0 §10.4.2) from [after], with the vault's time.
    func pendingListPage(after: String?, limit: Int?) async throws -> PendingListPage
}

extension VaultApi: ApprovalOps {
    public func sharePendingPage(after: String?, limit: Int?) async throws -> JsonObject {
        try await sharePendingList(after: after, limit: limit)
    }

    public func shareRulePage(after: String?) async throws -> JsonObject { try await shareRuleList(after: after) }
}

/// Everything that waits for the member's decision (ANDROID-PLAN §4 Approvals), as ``Repositories.swift`` describes the
/// repositories: the connection requests of either side (they move here from the Connections list, IOS-PLAN §8 I2.3,
/// as in vettid-android), member authentication, grant requests, share decisions, critical-item uses, and desktop and
/// agent requests. Every failure is a ``VaultFailure``; a request the vault no longer knows (`not_found`) leaves the list.
/// Deciding an ask marks its feed item read. Mirrors vettid-android `ApprovalsRepository`.
@MainActor
public protocol ApprovalsRepository: ConnectionRequestsRepository {
    /// Everything waiting, newest first; expired requests are left out. The connection requests are ``requests``.
    var approvals: [PendingApproval] { get }

    /// Counts the times every approval was dropped from memory (a lock, a hold, a wipe; IOS-PLAN §6.9), so that an
    /// approval gone from ``approvals`` is not taken to be decided when it was only dropped.
    var forgetCount: Int { get }

    /// Whether the approval [key], missing from ``approvals``, may only have been dropped from memory rather than decided
    /// or expired (IOS-PLAN §6.9): an ask that only events bring (``PendingApproval/eventOnly(key:)``) and that has not
    /// arrived since the approvals were last dropped. A request a vault list names is read again, so missing means ended.
    func mayHaveBeenDropped(_ key: String) -> Bool

    /// Re-reads what the vault lists (the connection requests, the grant and critical-item requests) and drops expired
    /// and decided requests kept from events.
    func refreshApprovals() async throws

    /// Fetches a critical-item request's payload (`critical-secret-use.get`) when the app has only its hash; it is shown,
    /// and the approval offered, only if it matches the hash (``CriticalUse/payloadVerified``).
    func loadCriticalUse(_ requestID: String) async throws

    /// Opens the credential's unlock window with [password] and signs the challenge (§10.4).
    func approveAuthentication(_ requestID: String, password: String) async throws

    func denyAuthentication(_ requestID: String) async throws

    /// Approves the grantable entries (``GrantRequest/grantable``) or denies the whole request (a decline, §10.4.1).
    func decideGrant(_ requestID: String, approve: Bool) async throws

    /// Decides a grant request entry by entry (§10.12 `grant.decide`): the indexes granted, category entries answered
    /// with the member's item, and the uses and lifetime the member chose.
    func decideGrant(_ requestID: String, decision: GrantDecision) async throws

    /// One use of a critical item, consented with the credential password (§10.13), only for a payload the member saw
    /// that matches its hash. Returns the status the connection receives (`ok`, `unsuitable`, `unavailable`); a wrong
    /// password (`bad_password`) leaves the request waiting.
    func approveCriticalUse(_ requestID: String, password: String) async throws -> String?

    func denyCriticalUse(_ requestID: String) async throws

    /// Includes [include] and declines [decline], items of one share rule's question (§10.12).
    func decideShare(_ ruleID: String, include: [String], decline: [String]) async throws

    /// Declines a desktop's or agent's request (§6.8), by its ``PendingApproval/key``.
    func declineDeviceRequest(_ key: String) async throws
}
