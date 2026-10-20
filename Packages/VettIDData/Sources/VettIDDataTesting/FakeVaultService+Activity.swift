#if DEBUG
import Foundation
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The fake vault's feed and audit log (VAULT-MESSAGING §10.9), answered with the shapes, codes and events of
/// vettid-vault `features/feed` and `features/audit`: `feed.event` to every owner device for a new item, no
/// `sync.event` to the device that changed an item itself (`SyncEvent` leaves the sender out), the audit log hash-chained
/// as §10.9 says, its search on the kind and the connection's names, and `audit.export`'s preview and export with the
/// PIN sealed to a UTK.
struct FakeActivity {
    struct Item {
        var id: String
        var seq: Int64
        var kind: String
        var at: Date
        var status: String
        var priority: String
        var connectionID: String?
        var ref: String?
        var count = 0
    }

    struct Entry {
        var id: String
        var seq: Int64
        var at: Date
        var kind: String
        var connectionID: String?
        var deviceID: String?
        var ref: String?
        var direction: String?
        var prev: [UInt8]
        var hash: [UInt8]
    }

    var items: [Item] = []
    var feedSeq: Int64 = 0
    var entries: [Entry] = []
    var exports: [ExportSeen] = []
    /// The grants, critical-item uses, authentication and share questions waiting (FakeVaultService+Approvals.swift).
    var asks = FakeAsks()
}

extension FakeVaultService {
    /// The feed and audit requests (§10.9), then the approvals (``approvalsRequest(_:_:)``). Callers hold ``cond``.
    func activityRequest(_ m: Inner, _ body: JsonObject) throws {
        switch m.type {
        case "feed.list": try feedList(m, body)
        case "feed.get", "feed.update", "feed.delete":
            guard let id = try? body.string("item_id"), let i = activity.items.firstIndex(where: { $0.id == id && $0.status != "deleted" }) else {
                return try reply(m.type, "{}", re: m.id, error: (try? body.string("item_id")) == nil ? "bad_request" : "not_found")
            }
            try feedItem(m, body, i)
        case "audit.list", "connection.audit.list": try auditList(m, body)
        case "audit.export": try auditExport(m, body)
        default: try approvalsRequest(m, body)
        }
    }

    // MARK: - Feed

    static func feedJSON(_ it: FakeActivity.Item) -> String {
        var b = JsonBuilder().string("item_id", it.id).uint("seq", UInt64(it.seq)).string("kind", it.kind).string("at", Timestamps.formatMillis(it.at)).string("status", it.status).string("priority", it.priority)
        if let c = it.connectionID { b = b.string("connection_id", c) }
        if let r = it.ref { b = b.string("ref", r) }
        if it.count >= 2 { b = b.uint("count", UInt64(it.count)) }
        return b.build()
    }

    private func feedList(_ m: Inner, _ body: JsonObject) throws {
        let after = VaultJSONLite.int(body, "after_seq")
        let limit = Int(VaultJSONLite.int(body, "limit") ?? 100)
        guard (1...500).contains(limit) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        var sel: [FakeActivity.Item]
        if let after {
            sel = activity.items.filter { $0.seq > after }.sorted { $0.seq < $1.seq }
        } else {
            sel = activity.items.filter { $0.status != "deleted" }.reversed()
        }
        sel = Array(sel.prefix(limit))
        try reply(m.type, #"{"items":\#(JsonBuilder.array(sel.map(Self.feedJSON))),"seq":\#(activity.feedSeq)}"#, re: m.id)
    }

    private func feedItem(_ m: Inner, _ body: JsonObject, _ i: Int) throws {
        switch m.type {
        case "feed.get": try reply(m.type, Self.feedJSON(activity.items[i]), re: m.id)
        case "feed.update":
            let status = try body.optString("status")
            guard let status, ["active", "read", "archived"].contains(status) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
            activity.feedSeq += 1
            activity.items[i].status = status
            activity.items[i].seq = activity.feedSeq
            try reply(m.type, Self.feedJSON(activity.items[i]), re: m.id)
        default:
            activity.feedSeq += 1
            activity.items[i].status = "deleted"
            activity.items[i].seq = activity.feedSeq
            try reply(m.type, "{}", re: m.id)
        }
    }

    /// A new feed item (vettid-vault `add`): every owner device gets `feed.event`. Callers hold ``cond``.
    @discardableResult
    func addFeedItem(_ kind: String, priority: String = "normal", connectionID: String? = nil, ref: String? = nil) throws -> String {
        activity.feedSeq += 1
        let it = FakeActivity.Item(id: Ulid.new(), seq: activity.feedSeq, kind: kind, at: Date(), status: "active", priority: priority, connectionID: connectionID, ref: ref)
        activity.items.append(it)
        try reply("feed.event", Self.feedJSON(it))
        return it.id
    }

    // MARK: - Audit

    /// Appends an entry to the log, chained (§10.9). Callers hold ``cond``.
    func record(_ kind: String, connectionID: String? = nil, deviceID: String? = nil, ref: String? = nil, direction: String? = nil, at: Date = Date()) {
        let prev = activity.entries.last?.hash ?? [UInt8](repeating: 0, count: 32)
        let seq = (activity.entries.last?.seq ?? 0) + 1
        let ms = Int64((at.timeIntervalSince1970 * 1000).rounded(.down))
        var data = Array("vettid/vms/2/audit".utf8) + prev + Bytes.uintBE(UInt64(seq), 8) + Bytes.uintBE(UInt64(ms), 8)
        for f in [kind, connectionID, deviceID, ref, direction] {
            let b = Array((f ?? "").utf8)
            data += Bytes.uintBE(UInt64(b.count), 2) + b
        }
        let when = Date(timeIntervalSince1970: Double(ms) / 1000)
        activity.entries.append(FakeActivity.Entry(id: Ulid.new(), seq: seq, at: when, kind: kind, connectionID: connectionID, deviceID: deviceID, ref: ref, direction: direction, prev: prev, hash: Bytes.sha256(data)))
    }

    static func entryJSON(_ e: FakeActivity.Entry) -> String {
        var b = JsonBuilder().string("entry_id", e.id).uint("seq", UInt64(e.seq)).string("at", Timestamps.formatMillis(e.at)).string("kind", e.kind)
        if let v = e.connectionID { b = b.string("connection_id", v) }
        if let v = e.deviceID { b = b.string("device_id", v) }
        if let v = e.ref { b = b.string("ref", v) }
        if let v = e.direction { b = b.string("direction", v) }
        return b.base64("prev", e.prev).base64("hash", e.hash).build()
    }

    /// The filters of `audit.list` and `audit.export` (§10.9), parsed as vettid-vault does; nil when one is malformed.
    struct AuditQuery {
        var connectionID: String?
        var kinds: [String]?
        var q: String?
        var since: Date?
        var until: Date?
    }

    private func auditQuery(_ body: JsonObject, connectionRequired: Bool = false) -> AuditQuery? {
        var q = AuditQuery()
        q.connectionID = try? body.optString("connection_id")
        if connectionRequired, q.connectionID == nil { return nil }
        if case .array(_, let items)? = body["kinds"] {
            let k = items.compactMap { try? $0.asString() }
            guard !k.isEmpty, k.count <= 16, k.count == items.count else { return nil }
            q.kinds = k
        }
        if let s = try? body.optString("q") {
            guard !s.trimmingCharacters(in: .whitespaces).isEmpty, s.utf8.count <= 128 else { return nil }
            q.q = s
        }
        for (k, path) in [("since", \AuditQuery.since), ("until", \AuditQuery.until)] {
            if let s = try? body.optString(k) {
                guard let d = Self.rfc3339(s) else { return nil }
                q[keyPath: path] = d
            }
        }
        if let s = q.since, let u = q.until, s >= u { return nil }
        return q
    }

    /// Whether [e] passes [q]: the connection, the kind prefixes, the time range, and `q` on the kind and the
    /// connection's names (§10.9 Search, points 1 and 2).
    private func matches(_ e: FakeActivity.Entry, _ q: AuditQuery) -> Bool {
        if let c = q.connectionID, e.connectionID != c { return false }
        if let k = q.kinds, !k.contains(where: { e.kind == $0 || e.kind.hasPrefix($0 + ".") }) { return false }
        if let s = q.since, e.at < s { return false }
        if let u = q.until, e.at >= u { return false }
        guard let text = q.q?.lowercased() else { return true }
        var fields = [e.kind, String(e.kind.map { ".-_".contains($0) ? " " : $0 })]
        if let c = e.connectionID, let p = social.connections[c]?.peer { fields += [p.firstName, p.lastName, p.firstName + " " + p.lastName, p.name ?? ""] }
        return fields.contains { !$0.isEmpty && $0.lowercased().contains(text) }
    }

    private func auditList(_ m: Inner, _ body: JsonObject) throws {
        guard let q = auditQuery(body, connectionRequired: m.type == "connection.audit.list") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        let before = VaultJSONLite.int(body, "before_seq")
        let after = VaultJSONLite.int(body, "after_seq")
        let limit = Int(VaultJSONLite.int(body, "limit") ?? 100)
        guard (1...500).contains(limit), before == nil || after == nil else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        var sel = after != nil ? activity.entries.filter { $0.seq > after! } : activity.entries.reversed().filter { before == nil || $0.seq < before! }
        sel = sel.filter { matches($0, q) }
        let more = sel.count > limit
        sel = Array(sel.prefix(limit))
        var answer = #"{"entries":\#(JsonBuilder.array(sel.map(Self.entryJSON))),"head":"\#(Base64s.encodeStd(activity.entries.last?.hash ?? [UInt8](repeating: 0, count: 32)))","seq":\#(activity.entries.last?.seq ?? 0)"#
        if more, let last = sel.last { answer += after != nil ? #","next_after_seq":\#(last.seq)"# : #","next_before_seq":\#(last.seq)"# }
        try reply(m.type, answer + "}", re: m.id)
    }

    /// `audit.export` (§10.9 History export), in the order of checks of 0.23.0: the preview counts; the export spends the
    /// UTK, checks the request and the PIN, appends `audit.exported` and answers with its `entry_seq`.
    private func auditExport(_ m: Inner, _ body: JsonObject) throws {
        let dry = (try? body.bool("dry_run")) ?? false
        if dry {
            guard !body.has("utk_id"), !body.has("sealed"), !body.has("upto_seq"), let q = auditQuery(body) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
            let newest = activity.entries.last
            return try reply(m.type, exportAnswer(q, upto: newest?.seq ?? 0, entrySeq: nil), re: m.id)
        }
        guard body.has("utk_id"), body.has("sealed") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard let p = try opened(m, body) else { return }
        let pin = (try? p.string("pin")) ?? ""
        let format = (try? body.string("format")) ?? ""
        let upto = VaultJSONLite.int(body, "upto_seq") ?? 0
        activity.exports.append(ExportSeen(format: format, pin: pin, uptoSeq: upto))
        guard let q = auditQuery(body), ["csv", "json"].contains(format), (1...(activity.entries.last?.seq ?? 0)).contains(upto) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard activity.entries.contains(where: { $0.seq <= upto && matches($0, q) }) else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        guard pin == vaultPin else {
            record("vault.pin_failed")
            return try reply(m.type, "{}", re: m.id, error: "bad_pin")
        }
        let summary = exportAnswer(q, upto: upto, entrySeq: nil)
        record("audit.exported", ref: "format=\(format)")
        try reply(m.type, String(summary.dropLast()) + #","entry_seq":\#(activity.entries.last?.seq ?? 0)}"#, re: m.id)
    }

    private func exportAnswer(_ q: AuditQuery, upto: Int64, entrySeq: Int64?) -> String {
        let sel = activity.entries.filter { $0.seq <= upto && matches($0, q) }
        let head = activity.entries.first { $0.seq == upto }?.hash ?? [UInt8](repeating: 0, count: 32)
        var a = #"{"count":\#(sel.count),"more":false,"upto_seq":\#(upto),"upto_hash":"\#(Base64s.encodeStd(head))""#
        if let o = sel.first, let n = sel.last {
            a += #","oldest_seq":\#(o.seq),"newest_seq":\#(n.seq),"oldest_at":"\#(Timestamps.formatMillis(o.at))","newest_at":"\#(Timestamps.formatMillis(n.at))""#
        }
        return a + "}"
    }

    // MARK: - What the test does and reads

    /// The vault created a feed item (as for an event the test does not emulate otherwise): this phone gets `feed.event`.
    @discardableResult
    public func feedItemArrives(_ kind: String, priority: String = "normal", connectionID: String? = nil, ref: String? = nil) throws -> String {
        try locked { try addFeedItem(kind, priority: priority, connectionID: connectionID, ref: ref) }
    }

    /// Another device of the owner changed an item's status: this phone gets `sync.event{feed.updated}`.
    public func otherDeviceSetsFeedStatus(_ itemID: String, _ status: String) throws {
        try locked {
            guard let i = activity.items.firstIndex(where: { $0.id == itemID }) else { return }
            activity.feedSeq += 1
            activity.items[i].status = status
            activity.items[i].seq = activity.feedSeq
            try reply("sync.event", JsonBuilder().string("kind", "feed.updated").string("item_id", itemID).uint("seq", UInt64(activity.feedSeq)).build())
        }
    }

    /// The item's status in the vault.
    public func feedStatus(_ itemID: String) -> String? { locked { activity.items.first { $0.id == itemID }?.status } }

    /// Writes [count] entries to the audit log, of the kinds given in turn, as if they happened while this phone was away.
    public func storeAuditEntries(_ count: Int, kinds: [String] = ["vault.unlocked", "message.received", "credential.rotated"], connectionID: String? = nil) {
        locked {
            for n in 0..<count {
                let kind = kinds[n % kinds.count]
                record(kind, connectionID: kind.hasPrefix("message") ? connectionID : nil, ref: kind.hasPrefix("message") ? Ulid.new() : nil, direction: kind.hasPrefix("message") ? "in" : nil)
            }
        }
    }

    /// The exports the vault was asked for (not the previews): their format, the PIN and `upto_seq`.
    public var exportsSeen: [ExportSeen] { locked { activity.exports } }

    public var auditKinds: [String] { locked { activity.entries.map(\.kind) } }
}

/// TEST ONLY. An `audit.export` the fake vault was asked for (not a preview).
public struct ExportSeen: Equatable, Sendable {
    public var format: String
    public var pin: String
    public var uptoSeq: Int64
}

/// Integer members of a request body, for the fake's parsers.
enum VaultJSONLite {
    static func int(_ o: JsonObject, _ k: String) -> Int64? {
        if case .number(let raw)? = o[k] { return Int64(raw) }
        return nil
    }
}

// swiftlint:enable line_length
#endif
