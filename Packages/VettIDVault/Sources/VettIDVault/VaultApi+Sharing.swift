import Foundation
import VettIDCrypto

/// A received grant's fetch (VAULT-MESSAGING §10.12): the opened content (`{item_id, version, name, category, fields,
/// notes?}`, ``takeContent()`` it and wipe it after use) and the uses left, or the member's vault's refusal [error] (`not_found`, `revoked`,
/// `expired`, `exhausted`, `unavailable`, and since 0.23.0 `rate_limited`). Mirrors vettid-android `GrantFetched`.
public final class GrantFetched: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    public let grantID: String
    private var held: [UInt8]?
    public let usesLeft: Int64?
    public let error: String?
    /// With `rate_limited` (0.23.0 §10.12): whole seconds until the fetch can succeed again.
    public let retryAfter: Int64?

    public init(grantID: String, content: [UInt8]?, usesLeft: Int64?, error: String?, retryAfter: Int64? = nil) {
        self.grantID = grantID
        self.held = content
        self.usesLeft = usesLeft
        self.error = error
        self.retryAfter = retryAfter
    }

    /// Hands over the opened content, leaving none here: the caller wipes what it got.
    public func takeContent() -> [UInt8]? {
        let c = held
        held = nil
        return c
    }

    public var description: String { "GrantFetched(\(grantID), error=\(error ?? "none"))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

// The member's share rules (VAULT-MESSAGING §10.12) beyond the read of `share.rule.list` (VaultApi+Tags.swift): the
// rule's `share.rule.set` and `share.rule.delete`, the pending decisions' list, and the grants' request, fetch and
// revoke (`grant.list` and `grant.decide` are in VaultApi+Approvals.swift). Mirrors vettid-android `VaultApi`.
extension VaultApi {
    public static let typeShareRuleSet = "share.rule.set"
    public static let typeShareRuleDelete = "share.rule.delete"
    public static let typeSharePendingList = "share.pending.list"
    /// How long a fetch waits for the connection's answer (`grant.value`).
    public static let grantFetchWait: TimeInterval = 60

    private func sharingOp(_ type: String, _ b: JsonBuilder) async throws -> JsonObject {
        VaultJSON.object(try await device.op(type, body: b.bytes()))
    }

    /// `share.rule.set`: creates or replaces a share rule ([rule] as §10.12 has it: subject, tags, match, mode, ...) and
    /// answers the rule; with `dry_run` in [rule] it changes nothing and answers `{matches, total}`.
    public func shareRuleSet(_ rule: JsonObject) async throws -> JsonObject {
        VaultJSON.object(try await device.op(Self.typeShareRuleSet, body: Array(rule.raw.utf8)))
    }

    /// `share.rule.delete`: `not_found` for a rule that is not there.
    public func shareRuleDelete(_ ruleID: String) async throws {
        _ = try await sharingOp(Self.typeShareRuleDelete, JsonBuilder().string("rule_id", ruleID))
    }

    /// One page of `share.pending.list` (0.21.0): the items that wait for the member's share decisions, `{pending:
    /// [{rule_id, subject, item_id, name, category, sensitivity, at, ask_rule_id?, shared?}], next?}`, sorted by rule,
    /// then item; at most one of [ruleID], [connectionID], [agentID].
    public func sharePendingList(
        ruleID: String? = nil, connectionID: String? = nil, agentID: String? = nil, after: String? = nil, limit: Int? = nil
    ) async throws -> JsonObject {
        let b = JsonBuilder()
        if let ruleID { b.string("rule_id", ruleID) }
        if let connectionID { b.string("connection_id", connectionID) }
        if let agentID { b.string("agent_id", agentID) }
        if let after { b.string("after", after) }
        if let limit { b.uint("limit", UInt64(max(limit, 0))) }
        return try await sharingOp(Self.typeSharePendingList, b)
    }

    /// `grant.request`: asks a connection for items (§10.12); [items] are `{kind: "item", ref, label?}` or `{kind:
    /// "category", ref: <category>, label?}`. Returns the `request_id`; the answer arrives as `grant.event`.
    public func grantRequest(
        _ connectionID: String, items: [JsonObject], uses: Int? = nil, expiresIn: Int? = nil, reason: String? = nil
    ) async throws -> String {
        let b = JsonBuilder().string("connection_id", connectionID).raw("items", JsonBuilder.array(items.map(\.raw)))
        if let uses { b.uint("uses", UInt64(max(uses, 0))) }
        if let expiresIn { b.uint("expires_in", UInt64(max(expiresIn, 0))) }
        if let reason { b.string("reason", reason) }
        guard let id = VaultJSON.string(try await sharingOp("grant.request", b), "request_id") else {
            throw VaultStateError(message: "grant.request without request_id")
        }
        return id
    }

    /// `grant.revoke`: revokes a grant given, or gives up one received; revoking one that ended succeeds.
    public func grantRevoke(_ grantID: String) async throws {
        _ = try await sharingOp("grant.revoke", JsonBuilder().string("grant_id", grantID))
    }

    /// Fetches a received grant's current content (§10.12): a one-time KEM key for this fetch only, `grant.fetch`, then
    /// the connection's answer in `grant.value` (matched by `fetch_id`), opened and the key destroyed. The plaintext is
    /// the item's content JSON; the caller wipes it. A refusal of the connection's vault is ``GrantFetched/error``.
    public func grantFetch(_ grantID: String, timeout: TimeInterval = VaultApi.grantFetchWait) async throws -> GrantFetched {
        let rk = try KemPrivateKey.generate()
        defer { rk.destroy() }
        let b = JsonBuilder().string("grant_id", grantID).base64("reply_key", rk.publicKey.bytes)
        guard let fetchID = VaultJSON.string(try await sharingOp("grant.fetch", b), "fetch_id") else {
            throw VaultStateError(message: "grant.fetch without fetch_id")
        }
        let ev = try await device.awaitEvent("grant.value", timeout: timeout) {
            VaultJSON.string($0.object, "fetch_id") == fetchID
        }.object
        if let error = VaultJSON.string(ev, "error") {
            return GrantFetched(grantID: grantID, content: nil, usesLeft: nil, error: error, retryAfter: VaultJSON.int(ev, "retry_after"))
        }
        guard let sealed = VaultJSON.string(ev, "value_sealed") else { throw VaultStateError(message: "grant.value without value_sealed") }
        let pt = try GrantSeal.openValue(reply: rk, grantID: grantID, fetchID: fetchID, sealed: try Base64s.decodeStd(sealed))
        return GrantFetched(grantID: grantID, content: pt, usesLeft: VaultJSON.int(ev, "uses_left"), error: nil)
    }
}
