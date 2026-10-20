import Foundation
import VettIDCrypto

// Body models of VAULT-MESSAGING §10.9 (the audit log, its search and export, and the feed), read from the strict JSON
// object of the body as vettid-vault `features/audit` and `features/feed` write it; unknown members are ignored (§10.1).
// Mirrors the audit and feed models of vettid-android `Models.kt`.

/// A feed item (§10.9): [status] `active`, `read`, `archived` or `deleted`; [priority] `low`, `normal`, `high` or
/// `urgent`; [count] (0.23.0) present from 2 on a batch of a connection's asks (§10.4.1) or on a `call.missed` item for
/// several calls; [title] and [body] only on `guide` items (absent on deleted ones).
public struct FeedItem: Equatable, Sendable {
    public var itemID: String
    public var seq: Int64
    public var kind: String
    public var at: String
    public var status: String
    public var priority: String
    public var connectionID: String?
    public var deviceID: String?
    public var ref: String?
    public var count: Int?
    public var title: String?
    public var body: String?

    public init(
        itemID: String, seq: Int64, kind: String, at: String, status: String, priority: String = "normal",
        connectionID: String? = nil, deviceID: String? = nil, ref: String? = nil
    ) {
        self.itemID = itemID
        self.seq = seq
        self.kind = kind
        self.at = at
        self.status = status
        self.priority = priority
        self.connectionID = connectionID
        self.deviceID = deviceID
        self.ref = ref
    }

    /// `<item>`; nil without its `item_id`, `seq`, `kind`, `at` or `status`. Empty optional members count as absent.
    public static func of(_ o: JsonObject) -> FeedItem? {
        guard let id = VaultJSON.string(o, "item_id"), let seq = VaultJSON.int(o, "seq"), let kind = VaultJSON.string(o, "kind"),
              let at = VaultJSON.string(o, "at"), let status = VaultJSON.string(o, "status") else { return nil }
        var i = FeedItem(
            itemID: id, seq: seq, kind: kind, at: at, status: status, priority: VaultJSON.string(o, "priority") ?? "normal",
            connectionID: VaultJSON.nonEmpty(o, "connection_id"), deviceID: VaultJSON.nonEmpty(o, "device_id"),
            ref: VaultJSON.nonEmpty(o, "ref")
        )
        i.count = VaultJSON.int(o, "count").map { Int(clamping: $0) }
        i.title = VaultJSON.string(o, "title")
        i.body = VaultJSON.string(o, "body")
        return i
    }
}

/// `feed.list`'s answer (§10.9): [items] (newest first, or in `seq` order with `after_seq`, deleted ones included) and
/// [seq], the vault's feed counter.
public struct FeedPage: Equatable, Sendable {
    public let items: [FeedItem]
    public let seq: Int64

    public init(items: [FeedItem], seq: Int64) {
        self.items = items
        self.seq = seq
    }

    /// `{items, seq}`; an entry that is not an item is left out.
    public static func of(_ o: JsonObject) -> FeedPage {
        FeedPage(items: VaultJSON.objects(o, "items").compactMap(FeedItem.of), seq: VaultJSON.int(o, "seq") ?? 0)
    }
}

/// An audit log entry (§10.9). [prev] and [hash] are standard base64 of 32 bytes, as sent; [at] is the vault's `ts`.
public struct AuditEntry: Equatable, Sendable {
    public var entryID: String
    public var seq: Int64
    public var at: String
    public var kind: String
    public var connectionID: String?
    public var deviceID: String?
    public var ref: String?
    public var direction: String?
    public var prev: String
    public var hash: String

    public init(
        entryID: String, seq: Int64, at: String, kind: String, connectionID: String? = nil, deviceID: String? = nil,
        ref: String? = nil, direction: String? = nil, prev: String = "", hash: String = ""
    ) {
        self.entryID = entryID
        self.seq = seq
        self.at = at
        self.kind = kind
        self.connectionID = connectionID
        self.deviceID = deviceID
        self.ref = ref
        self.direction = direction
        self.prev = prev
        self.hash = hash
    }

    /// `<entry>`; nil without its `entry_id`, `seq`, `at` or `kind`. Empty optional members count as absent (the hash
    /// covers them as empty either way).
    public static func of(_ o: JsonObject) -> AuditEntry? {
        guard let id = VaultJSON.string(o, "entry_id"), let seq = VaultJSON.int(o, "seq"), let at = VaultJSON.string(o, "at"),
              let kind = VaultJSON.string(o, "kind") else { return nil }
        return AuditEntry(
            entryID: id, seq: seq, at: at, kind: kind, connectionID: VaultJSON.nonEmpty(o, "connection_id"),
            deviceID: VaultJSON.nonEmpty(o, "device_id"), ref: VaultJSON.nonEmpty(o, "ref"),
            direction: VaultJSON.nonEmpty(o, "direction"), prev: VaultJSON.string(o, "prev") ?? "",
            hash: VaultJSON.string(o, "hash") ?? ""
        )
    }
}

/// `audit.list`'s and `connection.audit.list`'s answer (§10.9): [entries] newest first (oldest first with `after_seq`),
/// the log's [head] and [seq], the cursor that continues it (absent: the end of the results), and [partial] (0.20.0)
/// when a search ran out of its scan budget.
public struct AuditPage: Equatable, Sendable {
    public var entries: [AuditEntry]
    public var head: String?
    public var seq: Int64
    public var nextBeforeSeq: Int64?
    public var nextAfterSeq: Int64?
    public var partial: Bool

    public init(
        entries: [AuditEntry], head: String? = nil, seq: Int64 = 0, nextBeforeSeq: Int64? = nil, nextAfterSeq: Int64? = nil,
        partial: Bool = false
    ) {
        self.entries = entries
        self.head = head
        self.seq = seq
        self.nextBeforeSeq = nextBeforeSeq
        self.nextAfterSeq = nextAfterSeq
        self.partial = partial
    }

    /// `{entries, head, seq, next_before_seq? | next_after_seq?, partial?}`; an entry that is not one is left out.
    public static func of(_ o: JsonObject) -> AuditPage {
        AuditPage(
            entries: VaultJSON.objects(o, "entries").compactMap(AuditEntry.of), head: VaultJSON.string(o, "head"),
            seq: VaultJSON.int(o, "seq") ?? 0, nextBeforeSeq: VaultJSON.int(o, "next_before_seq"),
            nextAfterSeq: VaultJSON.int(o, "next_after_seq"), partial: VaultJSON.bool(o, "partial") ?? false
        )
    }
}

/// The filters of `audit.list` that `audit.export` takes (§10.9 History export): no cursor and no `limit`. [since] and
/// [until] are RFC 3339, as sent.
public struct AuditExportFilters: Equatable, Sendable {
    public var connectionID: String?
    public var kinds: [String]?
    public var q: String?
    public var since: String?
    public var until: String?

    public init(connectionID: String? = nil, kinds: [String]? = nil, q: String? = nil, since: String? = nil, until: String? = nil) {
        self.connectionID = connectionID
        self.kinds = kinds
        self.q = q
        self.since = since
        self.until = until
    }

    /// Writes the filters that are set, in the order of §10.9's table.
    func write(_ b: JsonBuilder) {
        if let connectionID { b.string("connection_id", connectionID) }
        if let kinds { b.raw("kinds", JsonBuilder.array(kinds.map(JsonBuilder.quote))) }
        if let q { b.string("q", q) }
        if let since { b.string("since", since) }
        if let until { b.string("until", until) }
    }
}

/// `audit.export`'s answer (§10.9), a preview's or an export's: [count] (0–10,000) entries match, newest first, [more]
/// beyond the cap; [uptoSeq] bounds the export and [uptoHash] (base64, 32 bytes) is that entry's hash; the range only
/// when [count] > 0; [entrySeq] the `audit.exported` entry (an export, not a preview); [answeredAt] the `ts` of the
/// vault's answer (an export's: the file's `exported_at`).
public struct AuditExportAnswer: Equatable, Sendable {
    public var count: Int64
    public var more: Bool
    public var uptoSeq: Int64
    public var uptoHash: String
    public var oldestSeq: Int64?
    public var newestSeq: Int64?
    public var oldestAt: String?
    public var newestAt: String?
    public var entrySeq: Int64?
    public var answeredAt: Date?

    public init(count: Int64, more: Bool = false, uptoSeq: Int64, uptoHash: String) {
        self.count = count
        self.more = more
        self.uptoSeq = uptoSeq
        self.uptoHash = uptoHash
    }

    /// The answer's members; nil without `count`, `upto_seq` or `upto_hash`.
    public static func of(_ o: JsonObject, at: Date? = nil) -> AuditExportAnswer? {
        guard let count = VaultJSON.int(o, "count"), let upto = VaultJSON.int(o, "upto_seq"),
              let hash = VaultJSON.string(o, "upto_hash") else { return nil }
        var a = AuditExportAnswer(count: count, more: VaultJSON.bool(o, "more") ?? false, uptoSeq: upto, uptoHash: hash)
        a.oldestSeq = VaultJSON.int(o, "oldest_seq")
        a.newestSeq = VaultJSON.int(o, "newest_seq")
        a.oldestAt = VaultJSON.string(o, "oldest_at")
        a.newestAt = VaultJSON.string(o, "newest_at")
        a.entrySeq = VaultJSON.int(o, "entry_seq")
        a.answeredAt = at
        return a
    }
}

public extension VaultJSON {
    /// The string member [k]; nil when absent, not a string or empty.
    static func nonEmpty(_ o: JsonObject, _ k: String) -> String? {
        string(o, k).flatMap { $0.isEmpty ? nil : $0 }
    }
}
