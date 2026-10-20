import Foundation
import VettIDCrypto

// The audit log, its search and its export, and the feed (VAULT-MESSAGING §10.9): one function per type, the shapes of
// vettid-vault `features/audit` and `features/feed`. Mirrors the audit and feed part of vettid-android `VaultApi`.
extension VaultApi {
    public static let typeAuditExport = "audit.export"

    private func activityOp(_ type: String, _ body: JsonBuilder = JsonBuilder()) async throws -> JsonObject {
        VaultJSON.object(try await device.op(type, body: body.bytes()))
    }

    // MARK: - Audit

    /// One page of the audit log (§10.9). With [connectionID] and no [afterSeq] it is `connection.audit.list` (that
    /// connection's entries), else `audit.list`. [q], [since] (inclusive) and [until] (exclusive, RFC 3339) are the search
    /// of 0.20.0, sent only when given; a search answers `partial` when its 2,000-entry scan budget ran out. [limit] is
    /// 1–500 (the vault's default 100). `bad_request` for a bad filter or cursor.
    public func auditList(
        connectionID: String? = nil, kinds: [String]? = nil, beforeSeq: Int64? = nil, afterSeq: Int64? = nil, limit: Int? = nil,
        search: AuditSearch = AuditSearch()
    ) async throws -> AuditPage {
        let type = connectionID != nil && afterSeq == nil ? "connection.audit.list" : "audit.list"
        let b = JsonBuilder()
        if let connectionID { b.string("connection_id", connectionID) }
        if let kinds { b.raw("kinds", JsonBuilder.array(kinds.map(JsonBuilder.quote))) }
        if let q = search.q { b.string("q", q) }
        if let since = search.since { b.string("since", since) }
        if let until = search.until { b.string("until", until) }
        if let beforeSeq { b.uint("before_seq", UInt64(max(beforeSeq, 0))) }
        if let afterSeq { b.uint("after_seq", UInt64(max(afterSeq, 0))) }
        if let limit { b.uint("limit", UInt64(max(limit, 1))) }
        return AuditPage.of(try await activityOp(type, b))
    }

    /// `audit.export`'s preview (0.22.0 §10.9 History export, `dry_run: true`): counts what [filters] match, without the
    /// PIN; spends nothing and writes no audit entry. [format] (`csv` or `json`) is only checked. The holder's only:
    /// `forbidden` otherwise; `credential_frozen` / `rotation_required` while a clone alarm is open.
    public func auditExportPreview(_ filters: AuditExportFilters, format: String? = nil) async throws -> AuditExportAnswer {
        let b = JsonBuilder()
        filters.write(b)
        b.bool("dry_run", true)
        if let format { b.string("format", format) }
        let o = try await activityOp(Self.typeAuditExport, b)
        guard let a = AuditExportAnswer.of(o) else { throw VaultStateError(message: "audit.export without count or upto") }
        return a
    }

    /// The export (§10.9): the same [filters] and [format], the preview's [uptoSeq], and the vault [pin] alone sealed to
    /// a UTK (no blob: not a credential operation). Answers the preview's members for `seq` ≤ [uptoSeq] with `entry_seq`
    /// and the answer's `ts` (the file's `exported_at`). `bad_pin`, `backoff` (`retry_after`), `utk_invalid`,
    /// `not_found` (nothing matches). No UTKs come back: the pool is topped up when it runs out.
    public func auditExport(_ filters: AuditExportFilters, format: String, uptoSeq: Int64, pin: String) async throws -> AuditExportAnswer {
        var outer: [(String, String)] = []
        if let c = filters.connectionID { outer.append(("connection_id", JsonBuilder.quote(c))) }
        if let k = filters.kinds { outer.append(("kinds", JsonBuilder.array(k.map(JsonBuilder.quote)))) }
        if let q = filters.q { outer.append(("q", JsonBuilder.quote(q))) }
        if let s = filters.since { outer.append(("since", JsonBuilder.quote(s))) }
        if let u = filters.until { outer.append(("until", JsonBuilder.quote(u))) }
        outer.append(("format", JsonBuilder.quote(format)))
        outer.append(("upto_seq", String(max(uptoSeq, 0))))
        let r = try await credential.sealedOpAt(Self.typeAuditExport, [.string("pin", pin)], outer: outer)
        guard let a = AuditExportAnswer.of(VaultJSON.object(r.body), at: r.ts) else {
            throw VaultStateError(message: "audit.export without count or upto")
        }
        return a
    }

    /// Whether [entries] (oldest first) chain (§10.9): each entry's `hash` is SHA-256("vettid/vms/2/audit" || prev ||
    /// uint64be(seq) || uint64be(at_ms) || lp(kind) || lp(connection_id) || lp(device_id) || lp(ref) || lp(direction))
    /// and each `prev` the previous entry's `hash`. [atMillis] reads `at`; nil (a time that does not parse) fails.
    public static func auditChains(_ entries: [AuditEntry], atMillis: (String) -> Int64?) -> Bool {
        var previous: [UInt8]?
        for e in entries {
            guard let p = try? Base64s.decodeStd(e.prev, 32), let h = try? Base64s.decodeStd(e.hash, 32),
                  let at = atMillis(e.at), e.seq >= 0, at >= 0 else { return false }
            if let previous, !Bytes.constantTimeEquals(previous, p) { return false }
            var data = Array("vettid/vms/2/audit".utf8) + p + Bytes.uintBE(UInt64(e.seq), 8) + Bytes.uintBE(UInt64(at), 8)
            for field in [e.kind, e.connectionID, e.deviceID, e.ref, e.direction] {
                let b = Array((field ?? "").utf8)
                guard b.count <= 0xFFFF else { return false }
                data += Bytes.uintBE(UInt64(b.count), 2) + b
            }
            let computed = Bytes.sha256(data)
            if !Bytes.constantTimeEquals(computed, h) { return false }
            previous = computed
        }
        return true
    }

    // MARK: - Feed

    /// `feed.list` (§10.9): without [afterSeq] the items that are not deleted, newest first, filtered by [status]
    /// (`active`, `read`, `archived` or `all`, the default); with it every item changed after it, in `seq` order, deleted
    /// ones included (without `title` and `body`). [limit] is 1–500 (the vault's default 100).
    public func feedList(status: String? = nil, afterSeq: Int64? = nil, limit: Int? = nil) async throws -> FeedPage {
        let b = JsonBuilder()
        if let status { b.string("status", status) }
        if let afterSeq { b.uint("after_seq", UInt64(max(afterSeq, 0))) }
        if let limit { b.uint("limit", UInt64(max(limit, 1))) }
        return FeedPage.of(try await activityOp("feed.list", b))
    }

    /// `feed.get`: one item; `not_found` for an unknown or deleted one.
    public func feedGet(_ itemID: String) async throws -> FeedItem {
        try Self.item(try await activityOp("feed.get", JsonBuilder().string("item_id", itemID)))
    }

    /// `feed.update`: sets [status] (`active`, `read` or `archived`) and/or [priority]; the item with its new `seq`. The
    /// owner's other devices get `sync.event{feed.updated}`; `not_found` for an unknown or deleted one.
    public func feedUpdate(_ itemID: String, status: String? = nil, priority: String? = nil) async throws -> FeedItem {
        let b = JsonBuilder().string("item_id", itemID)
        if let status { b.string("status", status) }
        if let priority { b.string("priority", priority) }
        return try Self.item(try await activityOp("feed.update", b))
    }

    /// `feed.delete`: the item becomes `deleted` (the other devices get `sync.event{feed.deleted}`); `not_found`.
    public func feedDelete(_ itemID: String) async throws {
        _ = try await activityOp("feed.delete", JsonBuilder().string("item_id", itemID))
    }

    private static func item(_ o: JsonObject) throws -> FeedItem {
        guard let i = FeedItem.of(o) else { throw VaultStateError(message: "feed item without its members") }
        return i
    }
}

/// The search of `audit.list` (VAULT-MESSAGING 0.20.0 §10.9): [q] a case-insensitive substring, [since] (inclusive) and
/// [until] (exclusive) RFC 3339 times; each sent only when set.
public struct AuditSearch: Equatable, Sendable {
    public var q: String?
    public var since: String?
    public var until: String?

    public init(q: String? = nil, since: String? = nil, until: String? = nil) {
        self.q = q
        self.since = since
        self.until = until
    }
}
