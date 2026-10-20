import Foundation
import VettIDCrypto
import VettIDVault

/// One entry of a History export as History shows it (VAULT-MESSAGING 0.22.0 §10.9): the vault's [record], the app's
/// [label] for its kind and its [category] identifier, and the names of its connection, device and item (nil where the
/// entry has none). The label and the names are the screens' (the History screen's texts and caches). Mirrors
/// vettid-android `ExportRow`.
public struct ExportRow: Equatable, Sendable {
    public var record: AuditRecord
    public var label: String
    public var category: String
    public var connectionName: String?
    public var deviceName: String?
    public var itemName: String?

    public init(
        record: AuditRecord, label: String, category: String? = nil, connectionName: String? = nil, deviceName: String? = nil,
        itemName: String? = nil
    ) {
        self.record = record
        self.label = label
        self.category = category ?? record.category.rawValue
        self.connectionName = connectionName
        self.deviceName = deviceName
        self.itemName = itemName
    }
}

/// The filters an export used, as sent (§10.9 JSON `filters`: only those used).
public struct ExportFilters: Equatable, Sendable {
    public var category: String?
    public var kinds: [String]?
    public var connectionID: String?
    public var connectionName: String?
    public var q: String?
    public var since: String?
    public var until: String?

    public init(
        category: String? = nil, kinds: [String]? = nil, connectionID: String? = nil, connectionName: String? = nil, q: String? = nil,
        since: String? = nil, until: String? = nil
    ) {
        self.category = category
        self.kinds = kinds
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.q = q
        self.since = since
        self.until = until
    }

    /// [filter] as the export sent it, with the connection's name as History shows it.
    public init(_ filter: AuditFilter, connectionName: String? = nil) {
        let f = filter.exportFilters
        self.init(
            category: filter.category?.rawValue, kinds: f.kinds, connectionID: f.connectionID,
            connectionName: f.connectionID == nil ? nil : connectionName, q: f.q, since: f.since, until: f.until
        )
    }
}

/// The JSON header (§10.9): [exportedAt] the `ts` of the vault's answer, [authorisedCount] the vault's `count`, its
/// range, and the log head (`upto_seq`, `upto_hash`). Nothing that identifies the vault, the account or the device.
public struct ExportHeader: Equatable, Sendable {
    public var exportedAt: Date
    public var filters: ExportFilters
    public var more: Bool
    public var authorisedCount: Int64
    public var oldestSeq: Int64?
    public var newestSeq: Int64?
    public var logHeadSeq: Int64
    public var logHeadHash: String

    public init(exportedAt: Date, filters: ExportFilters, answer: AuditExportAnswer) {
        self.exportedAt = exportedAt
        self.filters = filters
        more = answer.more
        authorisedCount = answer.count
        oldestSeq = answer.oldestSeq
        newestSeq = answer.newestSeq
        logHeadSeq = answer.uptoSeq
        logHeadHash = answer.uptoHash
    }
}

/// The History export's file (§10.9): its name, and its bytes in either format.
public enum HistoryFiles {
    /// `vettid-history-<YYYYMMDD>-<HHMMSS>.<csv|json>`, UTC, the time of the export; no name or email.
    public static func fileName(_ at: Date, _ format: ExportFormat) -> String {
        let ts = Timestamps.formatSeconds(at) // YYYY-MM-DDTHH:MM:SSZ
        let digits = ts.filter(\.isNumber)
        return "vettid-history-\(digits.prefix(8))-\(digits.dropFirst(8).prefix(6)).\(format.fileExtension)"
    }

    /// The file's bytes in [format].
    public static func bytes(_ format: ExportFormat, header: ExportHeader, rows: [ExportRow]) -> [UInt8] {
        switch format {
        case .csv: HistoryCsv.bytes(rows)
        case .json: HistoryJson.bytes(header, rows)
        }
    }
}

/// The CSV of §10.9: RFC 4180 (CRLF line ends; a field with a comma, a double quote, CR or LF in double quotes, inner
/// quotes doubled), UTF-8 with a byte order mark, a header row, `hash` in lowercase hex, absent values empty. A field
/// starting with `=`, `+`, `-`, `@`, a tab or CR gets an apostrophe before it, inside the quoting (formula injection).
/// Mirrors vettid-android `HistoryCsv`.
public enum HistoryCsv {
    public static let columns = ["seq", "time", "category", "event", "kind", "direction", "connection", "device", "item", "ref", "hash"]
    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    static let formulaStart: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    public static func bytes(_ rows: [ExportRow]) -> [UInt8] {
        var out = line(columns)
        for r in rows {
            let e = r.record.entry
            out += line([
                String(e.seq), e.at, r.category, r.label, e.kind, e.direction ?? "", r.connectionName ?? "", r.deviceName ?? "",
                r.itemName ?? "", e.ref ?? "", hex(e.hash),
            ])
        }
        return bom + Array(out.utf8)
    }

    private static func line(_ fields: [String]) -> String { fields.map(field).joined(separator: ",") + "\r\n" }

    /// One field: the apostrophe against formula injection, then RFC 4180 quoting.
    public static func field(_ raw: String) -> String {
        let v = raw.unicodeScalars.first.map { formulaStart.contains($0) } == true ? "'" + raw : raw
        // Unicode scalars, so that a CR LF pair (one Character) is seen.
        let quote = v.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }
        return quote ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
    }

    /// A base64 hash as lowercase hex; empty when absent or unreadable.
    public static func hex(_ b64: String) -> String {
        guard !b64.isEmpty, let b = try? Base64s.decodeStd(b64) else { return "" }
        return b.map { String(format: "%02x", $0) }.joined()
    }
}

/// The JSON of §10.9 (`application/json`, UTF-8 without a byte order mark, one object): the header, then the entries
/// with the chain fields (`prev`, `hash`, base64) so that the export can be checked against the log. Optional members are
/// absent, never `null`. Mirrors vettid-android `HistoryJson`.
public enum HistoryJson {
    public static let format = "vettid-history"
    public static let formatVersion: UInt64 = 1

    public static func bytes(_ header: ExportHeader, _ rows: [ExportRow]) -> [UInt8] {
        let b = JsonBuilder().string("format", format).uint("format_version", formatVersion)
            .string("exported_at", Timestamps.formatMillis(header.exportedAt)).raw("filters", filters(header.filters))
            .uint("count", UInt64(rows.count)).bool("more", header.more).uint("authorised_count", UInt64(max(header.authorisedCount, 0)))
        if let o = header.oldestSeq { b.uint("oldest_seq", UInt64(max(o, 0))) }
        if let n = header.newestSeq { b.uint("newest_seq", UInt64(max(n, 0))) }
        b.raw("log_head", JsonBuilder().uint("seq", UInt64(max(header.logHeadSeq, 0))).string("hash", header.logHeadHash).build())
        b.raw("entries", JsonBuilder.array(rows.map(entry)))
        return b.bytes()
    }

    private static func filters(_ f: ExportFilters) -> String {
        let b = JsonBuilder()
        if let v = f.category { b.string("category", v) }
        if let v = f.kinds { b.raw("kinds", JsonBuilder.array(v.map(JsonBuilder.quote))) }
        if let v = f.connectionID { b.string("connection_id", v) }
        if let v = f.connectionName { b.string("connection_name", v) }
        if let v = f.q { b.string("q", v) }
        if let v = f.since { b.string("since", v) }
        if let v = f.until { b.string("until", v) }
        return b.build()
    }

    private static func entry(_ r: ExportRow) -> String {
        let e = r.record.entry
        let b = JsonBuilder().uint("seq", UInt64(max(e.seq, 0))).string("entry_id", e.entryID).string("at", e.at).string("kind", e.kind)
            .string("label", r.label).string("category", r.category)
        if let v = e.direction { b.string("direction", v) }
        if let v = e.connectionID { b.string("connection_id", v) }
        if let v = r.connectionName { b.string("connection_name", v) }
        if let v = e.deviceID { b.string("device_id", v) }
        if let v = r.deviceName { b.string("device_name", v) }
        if let v = e.ref { b.string("ref", v) }
        if let v = r.itemName { b.string("item_name", v) }
        return b.string("prev", e.prev).string("hash", e.hash).build()
    }
}
