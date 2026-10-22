import Foundation
import VettIDCrypto
import VettIDVault

// The grants (VAULT-MESSAGING §10.12): the list, revoking, asking a connection for something, and fetching what a
// connection shares. Mirrors vettid-android `SharingManager` (`grants`, `revokeGrant`, `requestGrant`, `fetchShared`).
extension SharingManager {
    /// §10.12: a request entry's label at most 128 bytes, its reason at most 256.
    public nonisolated static let maxLabel = 128
    public nonisolated static let maxReason = 256

    public func grants() async throws -> GrantLists {
        let o = try await run { try await ops().grantList() }
        return GrantLists(
            given: VaultJSON.objects(o, "given").compactMap { GrantView.of($0, .given) },
            received: VaultJSON.objects(o, "received").compactMap { GrantView.of($0, .received) },
            requested: VaultJSON.objects(o, "requested").compactMap(GrantAsk.of)
        )
    }

    public func revokeGrant(_ grantID: String) async throws {
        try await run { try await ops().grantRevoke(grantID) }
    }

    public func requestGrant(connectionID: String, category: String, label: String?, reason: String?) async throws -> String {
        let l = label.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let r = reason.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let tooLong = (l?.utf8.count ?? 0) > Self.maxLabel || (r?.utf8.count ?? 0) > Self.maxReason
        guard ItemChecks.isValidCategory(category), !tooLong else { throw Self.badRequest() }
        let entry = JsonBuilder().string("kind", "category").string("ref", category)
        if let l { entry.string("label", l) }
        let item = VaultJSON.object(entry.bytes())
        return try await run { try await ops().grantRequest(connectionID: connectionID, items: [item], reason: r) }
    }

    public func fetchShared(_ grantID: String) async throws -> FetchOutcome {
        let r = try await run { try await ops().grantFetch(grantID) }
        if let e = r.error { return .refused(e, retryAfter: r.retryAfter.flatMap { $0 > 0 ? $0 : nil }) }
        guard var pt = r.takeContent() else { return .refused("unavailable") }
        defer { Bytes.wipe(&pt) }
        return .shared(try SharedContent.of(pt, usesLeft: r.usesLeft))
    }
}

extension GrantView {
    /// A `<grant>` (§10.12) of `grant.list`; nil without its `grant_id` or `connection_id`. The grant's own `direction`
    /// member wins over the list it was in.
    public static func of(_ o: JsonObject, _ direction: GrantDirection) -> GrantView? {
        guard let id = VaultJSON.string(o, "grant_id"), let connection = VaultJSON.string(o, "connection_id") else { return nil }
        let n = { (k: String) in VaultJSON.int(o, k).map { Int(clamping: $0) } }
        let limits = VaultJSON.obj(o, "limits")
        let limit = { (k: String) in limits.flatMap { VaultJSON.int($0, k) }.map { Int(clamping: $0) } }
        var fields: [String]?
        if case .array? = o["fields"] { fields = VaultJSON.strings(o, "fields") }
        let dir: GrantDirection = switch VaultJSON.string(o, "direction") {
        case "given": .given
        case "received": .received
        default: direction
        }
        return GrantView(
            grantID: id, connectionID: connection, direction: dir, itemRef: VaultJSON.string(o, "ref") ?? "",
            name: VaultJSON.string(o, "name") ?? VaultJSON.string(o, "label") ?? "",
            category: VaultJSON.string(o, "category") ?? "other", fields: fields, label: VaultJSON.string(o, "label"),
            ruleID: VaultJSON.string(o, "rule_id"), uses: n("uses"), used: n("used") ?? 0,
            expiresAt: OwnerCheckManager.instant(VaultJSON.string(o, "expires_at")),
            state: VaultJSON.string(o, "state") ?? GrantView.stateActive,
            createdAt: OwnerCheckManager.instant(VaultJSON.string(o, "created_at")), labels: labels(o), perHour: limit("per_hour"),
            perDay: limit("per_day")
        )
    }

    /// `labels: [{field_id, label, kind}]` (§10.12: a received grant's); malformed entries are skipped.
    static func labels(_ o: JsonObject) -> [GrantFieldLabel] {
        VaultJSON.objects(o, "labels").compactMap { l in
            guard let id = VaultJSON.string(l, "field_id") else { return nil }
            let kind = VaultJSON.string(l, "kind") ?? FieldKinds.text
            return GrantFieldLabel(fieldID: id, label: VaultJSON.string(l, "label") ?? "", kind: kind)
        }
    }
}

extension GrantAsk {
    /// An entry of `grant.list`'s `requested` (§10.12 as 0.21.0 pins it); nil without its ids. The entries are as sent
    /// (one without its `kind` is skipped), a blank label is none, and the state is `pending` when absent.
    public static func of(_ r: JsonObject) -> GrantAsk? {
        guard let id = VaultJSON.string(r, "request_id"), let connection = VaultJSON.string(r, "connection_id") else { return nil }
        let entries = VaultJSON.objects(r, "items").compactMap { e -> GrantAskEntry? in
            guard let kind = VaultJSON.string(e, "kind") else { return nil }
            let label = VaultJSON.string(e, "label").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return GrantAskEntry(kind: kind, ref: VaultJSON.string(e, "ref") ?? "", label: label)
        }
        return GrantAsk(requestID: id, connectionID: connection, entries: entries, state: VaultJSON.string(r, "state") ?? "pending")
    }
}

extension SharedContent {
    /// A fetched content (`{item_id, version, name, category, fields: [{field_id, label, kind, value}], notes?}`, §10.12);
    /// `unreadable_value` when it is not a JSON object.
    public static func of(_ pt: [UInt8], usesLeft: Int64?) throws -> SharedContent {
        let o: JsonObject
        do {
            o = try StrictJson.parseObject(pt)
        } catch {
            throw VaultFailure(.other, code: "unreadable_value")
        }
        let fields = VaultJSON.objects(o, "fields").map { f -> ItemFieldView in
            let kind = VaultJSON.string(f, "kind") ?? FieldKinds.text
            var value: String?
            if let v = f["value"] { if case .null = v { value = nil } else { value = v.raw } }
            return ItemFieldView(
                fieldID: VaultJSON.string(f, "field_id"), label: VaultJSON.string(f, "label") ?? "", kind: kind,
                value: ItemsManager.fieldValue(kind, value)
            )
        }
        return SharedContent(
            itemID: VaultJSON.string(o, "item_id") ?? "", name: VaultJSON.string(o, "name") ?? "",
            category: VaultJSON.string(o, "category") ?? "other", fields: fields, notes: VaultJSON.string(o, "notes"), usesLeft: usesLeft
        )
    }
}
