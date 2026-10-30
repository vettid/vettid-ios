import Foundation
import VettIDCrypto
import VettIDVault

/// Turns the vault's approval bodies (VAULT-MESSAGING §10.4, §10.12, §10.13, §6.8) into the app's models. Bodies come
/// from the member's own vault inside an authenticated session; unknown members are ignored (§10.1) and a body missing a
/// required member yields nil. Connection requests are ``ConnectionParser``'s. Mirrors vettid-android `ApprovalParser`.
public enum ApprovalParser {
    /// The event types of the approvals besides the connection requests.
    public static let types: Set<String> = [
        "connection.authenticate.pending", "grant.pending", "critical-secret-use.pending", "share.pending", "approval.pending",
        "device.session.pending",
    ]

    /// One approval from an event of [type] received at [at].
    public static func parse(_ type: String, _ o: JsonObject, at: Date) -> PendingApproval? {
        switch type {
        case "connection.authenticate.pending": authentication(o, at: at).map(PendingApproval.authentication)
        case "grant.pending": grant(o, at: at).map(PendingApproval.grant)
        case "critical-secret-use.pending": critical(o, at: at).map(PendingApproval.critical)
        case "share.pending": share(o, at: at).map(PendingApproval.share)
        case "approval.pending", "device.session.pending": device(type, o, at: at).map(PendingApproval.device)
        default: nil
        }
    }

    static func instant(_ s: String?) -> Date? { OwnerCheckManager.instant(s) }

    /// `connection.authenticate.pending`: `{request_id, connection_id, context?, purpose?, match_code?, exp}`; a `purpose`
    /// other than `signin` or `approval` is read as absent (0.65.0), and a `match_code` that is not a string of 2 or 3
    /// digits on a sign-in is ignored (0.79.0).
    public static func authentication(_ o: JsonObject, at: Date) -> AuthenticationRequest? {
        guard let id = VaultJSON.string(o, "request_id"), let conn = VaultJSON.string(o, "connection_id") else { return nil }
        let purpose = AuthenticationPurpose.of(VaultJSON.string(o, "purpose"))
        return AuthenticationRequest(
            requestID: id, connectionID: conn, context: VaultJSON.string(o, "context"), receivedAt: at,
            exp: instant(VaultJSON.string(o, "exp")), purpose: purpose,
            matchCode: AuthenticationRequest.matchCode(VaultJSON.string(o, "match_code"), purpose: purpose)
        )
    }

    /// `grant.pending`, or an entry of `grant.list`'s `pending`: `{request_id, connection_id, items, uses, expires_in,
    /// reason?, exp}`; an entry without its `kind` is left out.
    public static func grant(_ o: JsonObject, at: Date) -> GrantRequest? {
        guard let id = VaultJSON.string(o, "request_id"), let conn = VaultJSON.string(o, "connection_id") else { return nil }
        let entries = VaultJSON.objects(o, "items").compactMap { i -> GrantEntry? in
            guard let kind = VaultJSON.string(i, "kind") else { return nil }
            return GrantEntry(
                kind: kind, ref: VaultJSON.string(i, "ref") ?? "", label: VaultJSON.string(i, "label"),
                available: VaultJSON.bool(i, "available") ?? false, name: VaultJSON.string(i, "name"),
                category: VaultJSON.string(i, "category"), labels: labels(i)
            )
        }
        return GrantRequest(
            requestID: id, connectionID: conn, entries: entries, uses: VaultJSON.int(o, "uses").map { Int(clamping: $0) },
            expiresIn: VaultJSON.int(o, "expires_in"), reason: VaultJSON.string(o, "reason"), receivedAt: at,
            exp: instant(VaultJSON.string(o, "exp"))
        )
    }

    /// An entry's `labels` (`[{field_id, label, kind}]`, 0.21.0); nil when absent (an older vault).
    static func labels(_ o: JsonObject) -> [GrantFieldLabel]? {
        guard case .array? = o["labels"] else { return nil }
        return VaultJSON.objects(o, "labels").compactMap { l in
            guard let id = VaultJSON.string(l, "field_id") else { return nil }
            return GrantFieldLabel(fieldID: id, label: VaultJSON.string(l, "label") ?? "", kind: VaultJSON.string(l, "kind") ?? "")
        }
    }

    /// `critical-secret-use.pending`, or an entry of `critical-secret-use.list`'s `incoming` (which has no `payload`).
    public static func critical(_ o: JsonObject, at: Date) -> CriticalUse? {
        guard let id = VaultJSON.string(o, "request_id"), let conn = VaultJSON.string(o, "connection_id"),
              let sha = VaultJSON.string(o, "payload_sha256") else { return nil }
        return CriticalUse(
            requestID: id, connectionID: conn, itemName: VaultJSON.string(o, "name") ?? "", fieldLabel: VaultJSON.string(o, "label") ?? "",
            operation: VaultJSON.string(o, "operation") ?? "", payload: VaultJSON.string(o, "payload") ?? "", payloadSha256: sha,
            context: VaultJSON.string(o, "context"), receivedAt: at, exp: instant(VaultJSON.string(o, "exp")),
            kind: VaultJSON.string(o, "kind")
        )
    }

    /// `share.pending`: `{rule_id, subject: {connection_id | agent_id}, items, reason?}`.
    public static func share(_ o: JsonObject, at: Date) -> ShareDecision? {
        guard let rule = VaultJSON.string(o, "rule_id") else { return nil }
        let subject = VaultJSON.obj(o, "subject")
        return ShareDecision(
            ruleID: rule, subjectConnectionID: subject.flatMap { VaultJSON.string($0, "connection_id") },
            subjectAgentID: subject.flatMap { VaultJSON.string($0, "agent_id") },
            items: VaultJSON.objects(o, "items").compactMap(shareItem), reason: VaultJSON.string(o, "reason"), receivedAt: at
        )
    }

    /// An item of `share.pending` (0.23.0: `ask_rule_id`, `shared`).
    public static func shareItem(_ i: JsonObject) -> ShareItem? {
        guard let id = VaultJSON.string(i, "item_id") else { return nil }
        return ShareItem(
            itemID: id, name: VaultJSON.string(i, "name") ?? "", category: VaultJSON.string(i, "category") ?? "other",
            sensitivity: VaultJSON.string(i, "sensitivity") ?? "data", askRuleID: VaultJSON.nonEmpty(i, "ask_rule_id"),
            shared: VaultJSON.bool(i, "shared") ?? false
        )
    }

    /// `approval.pending` (`approval_id`, with the request's `type`) or `device.session.pending` (`request_id`).
    public static func device(_ type: String, _ o: JsonObject, at: Date) -> DeviceRequest? {
        let approval = type == "approval.pending"
        guard let id = VaultJSON.string(o, approval ? "approval_id" : "request_id") else { return nil }
        return DeviceRequest(
            type: type, id: id, deviceName: VaultJSON.string(o, "name"), role: VaultJSON.string(o, "role"),
            requestType: approval ? VaultJSON.string(o, "type") : nil, receivedAt: at, exp: instant(VaultJSON.string(o, "exp")),
            deviceID: VaultJSON.string(o, "device_id")
        )
    }
}
