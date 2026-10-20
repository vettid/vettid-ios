import Foundation
import VettIDCrypto
import VettIDVault

/// The History screen's categories (ANDROID-PLAN §4 History, VAULT-MESSAGING 0.20.0 §10.9): each is the set of audit kind
/// prefixes it sends as `kinds` (an entry matches a prefix when its `kind` equals it or starts with it followed by `.`).
/// Every kind of §10.9 falls in exactly one; ``other`` holds a kind a newer vault adds outside these prefixes, which
/// appears under "All" only (it is not a filter). [rawValue] is the category's stable, untranslated name in a History
/// export file (§10.9). Mirrors vettid-android `AuditCategory`.
public enum AuditCategory: String, CaseIterable, Sendable {
    /// Unlocks and owner checks.
    case vaultAccess = "unlocks"
    /// `audit` (`audit.exported`, a History export) belongs here.
    case security
    case devices
    case connections
    case messages
    /// "Vault (items, sharing, wallet)".
    case items = "vault"
    case agents
    case location
    case account
    /// Blocked and dropped messages.
    case dropped
    case other

    public var prefixes: [String] {
        switch self {
        case .vaultAccess: ["vault", "owner_check"]
        case .security: ["credential", "identity", "recovery", "audit"]
        case .devices: ["device", "approval"]
        case .connections: ["connection", "intro", "profile"]
        case .messages: ["message", "call"]
        case .items: ["item", "tag", "share", "grant", "critical-secret", "wallet"]
        case .agents: ["leash", "action"]
        case .location: ["location"]
        case .account: ["account", "settings"]
        case .dropped: ["drop"]
        case .other: []
        }
    }

    /// The categories offered as filters, in chip order.
    public static var filters: [AuditCategory] { allCases.filter { $0 != .other } }

    /// §10.9's prefix rule.
    public static func matches(_ kind: String, prefix: String) -> Bool { kind == prefix || kind.hasPrefix(prefix + ".") }

    /// The category of [kind]; ``other`` for a kind no category names.
    public static func of(_ kind: String) -> AuditCategory {
        allCases.first { c in c.prefixes.contains { matches(kind, prefix: $0) } } ?? .other
    }
}

/// An audit log entry (§10.9) as History holds it: the vault's [entry], with its time parsed ([at] nil when the vault's
/// timestamp does not parse; the entry keeps the text as sent).
public struct AuditRecord: Equatable, Sendable {
    public var entry: AuditEntry
    public var at: Date?

    public init(_ entry: AuditEntry) {
        self.entry = entry
        at = OwnerCheckManager.instant(entry.at)
    }

    public var seq: Int64 { entry.seq }
    public var kind: String { entry.kind }
    public var category: AuditCategory { AuditCategory.of(entry.kind) }

    /// Kinds whose `ref` is an item's id (§10.9 Search, item names): the vault may match `q` on the item's name.
    public static let itemRefKinds: Set<String> = [
        "item.added", "item.updated", "item.deleted", "item.sensitivity_changed", "item.revealed",
        "share.included", "share.declined", "share.withdrawn", "wallet.created", "wallet.deleted", "wallet.address_issued",
    ]

    /// The item id this entry's `ref` names, for the kinds whose `ref` is one.
    public var itemID: String? { Self.itemRefKinds.contains(entry.kind) ? entry.ref : nil }
}

/// What the member filters History by (ANDROID-PLAN §4 History): one [category] (nil: all), one connection, the search
/// [query] (`q`) and a date range ([since] inclusive, [until] exclusive). Mirrors vettid-android `AuditFilter`.
public struct AuditFilter: Equatable, Sendable {
    public var category: AuditCategory?
    public var connectionID: String?
    public var query: String
    public var since: Date?
    public var until: Date?

    public init(category: AuditCategory? = nil, connectionID: String? = nil, query: String = "", since: Date? = nil, until: Date? = nil) {
        self.category = category
        self.connectionID = connectionID
        self.query = query
        self.since = since
        self.until = until
    }

    /// §10.9: `q` is 1–128 bytes.
    public static let maxQBytes = 128

    /// `q` (§10.9): NFC, control characters dropped, trimmed, at most 128 bytes of UTF-8 (cut at a character), nil
    /// when blank.
    public var q: String? { Self.searchText(query) }

    public var isEmpty: Bool { category == nil && connectionID == nil && q == nil && since == nil && until == nil }

    /// The `kinds` member: the category's prefixes (at most 6 of §10.9's 16), nil for all.
    public var kinds: [String]? { category.flatMap { $0.prefixes.isEmpty ? nil : $0.prefixes } }

    /// Whether [r] passes the category, the connection and the date range (what a vault before 0.20.0 may ignore).
    public func acceptsExceptSearch(_ r: AuditRecord) -> Bool {
        (category == nil || r.category == category) && (connectionID == nil || r.entry.connectionID == connectionID)
            && (since.map { s in r.at.map { $0 >= s } ?? false } ?? true) && (until.map { u in r.at.map { $0 < u } ?? false } ?? true)
    }

    /// The filters as `audit.export` and `audit.list` send them; `since` and `until` in the `ts` format.
    public var exportFilters: AuditExportFilters {
        AuditExportFilters(connectionID: connectionID, kinds: kinds, q: q, since: since.map(Self.ts), until: until.map(Self.ts))
    }

    static func ts(_ d: Date) -> String { Timestamps.formatMillis(d) }

    /// [raw] as `q`.
    public static func searchText(_ raw: String) -> String? {
        // C0, DEL and C1, as §10.9 refuses them.
        let clean = raw.precomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }
        let text = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var out = ""
        var bytes = 0
        for c in text {
            let n = String(c).utf8.count
            if bytes + n > maxQBytes { break }
            out.append(c)
            bytes += n
        }
        let cut = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? nil : cut
    }

    /// The kind as §10.9 searches it: itself and with `.`, `_` and `-` as spaces.
    public static func kindText(_ kind: String) -> [String] {
        [kind, String(kind.map { ".-_".contains($0) ? " " : $0 })]
    }

    /// §10.9's comparison: lower-case, substring, each field on its own; an empty field never matches.
    public static func matches(_ q: String, fields: [String]) -> Bool {
        let lq = q.lowercased()
        return fields.contains { !$0.isEmpty && $0.lowercased().contains(lq) }
    }
}

/// One `audit.list` request (§10.9, newest first). ANDROID-PLAN §4 History: pages of 50.
public struct AuditRequest: Equatable, Sendable {
    public static let defaultLimit = 50

    public var filter: AuditFilter
    public var beforeSeq: Int64?
    public var limit: Int

    public init(filter: AuditFilter = AuditFilter(), beforeSeq: Int64? = nil, limit: Int = AuditRequest.defaultLimit) {
        self.filter = filter
        self.beforeSeq = beforeSeq
        self.limit = limit
    }

    public var hasSearch: Bool { filter.q != nil || filter.since != nil || filter.until != nil }
}

/// A page of the log, newest first. [nextBeforeSeq] continues it (nil: the end of the results); [partial]: a search ran
/// out of its scan budget (§10.9, 0.20.0); [searchSent]: the request carried `q`, `since` or `until`.
public struct AuditResult: Equatable, Sendable {
    public var entries: [AuditRecord]
    public var nextBeforeSeq: Int64?
    public var searchSent: Bool
    public var partial: Bool
}

/// The vault calls behind ``HistoryManager`` and ``HistoryExportManager``; a test passes its own.
public protocol AuditOps: Sendable {
    /// `audit.list` (`connection.audit.list` with [connectionID]) from [beforeSeq], newest first.
    func auditPage(connectionID: String?, kinds: [String]?, beforeSeq: Int64?, limit: Int, search: AuditSearch) async throws -> AuditPage
    func auditExportPreview(_ filters: AuditExportFilters, format: String?) async throws -> AuditExportAnswer
    func auditExport(_ filters: AuditExportFilters, format: String, uptoSeq: Int64, pin: String) async throws -> AuditExportAnswer
    func deviceList() async throws -> [DeviceEntry]
}

extension VaultApi: AuditOps {
    public func auditPage(
        connectionID: String?, kinds: [String]?, beforeSeq: Int64?, limit: Int, search: AuditSearch
    ) async throws -> AuditPage {
        try await auditList(connectionID: connectionID, kinds: kinds, beforeSeq: beforeSeq, limit: limit, search: search)
    }
}

/// The member's audit log (§10.9), read-only, as ``Repositories.swift`` describes the repositories. Failures are
/// ``VaultFailure``s. Mirrors vettid-android `HistoryRepository`.
@MainActor
public protocol HistoryRepository: AnyObject, Sendable {
    func auditPage(_ request: AuditRequest) async throws -> AuditResult

    /// An entry already read while the vault is open, else nil.
    func cached(_ seq: Int64) -> AuditRecord?

    /// The vault answered a search unfiltered (a vault before 0.20.0 ignores unknown members): the search is no longer
    /// sent and the app filters the entries it loads (``AuditFilter/acceptsExceptSearch(_:)``, ``AuditFilter/matches``).
    func searchIgnored()

    /// The vault's devices (`device.list`, §10.3), for an entry's device. Read once while the vault is open and kept;
    /// [refresh] reads it again. Nil when it was never read (the call failed): no device is then named, rather than every
    /// device called removed.
    func devices(refresh: Bool) async -> HistoryDevices?
}

/// The vault's devices as History names them (§10.3, §10.9 History export): every listed device by id, with its name, or
/// "" when it has none (the vault lists this app with an empty name), and this phone's own device id. Only a device
/// that is not listed is a removed one.
public struct HistoryDevices: Equatable, Sendable {
    public var names: [String: String]
    public var selfID: String?

    public init(names: [String: String], selfID: String? = nil) {
        self.names = names
        self.selfID = selfID
    }

    /// `device.list`'s entries, names trimmed; a blank name stays as "" (the device is known, not removed).
    public init(_ list: [DeviceEntry], selfID: String?) {
        let pairs = list.map { ($0.id, ($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
        self.init(names: Dictionary(pairs, uniquingKeysWith: { a, _ in a }), selfID: selfID)
    }

    /// How History shows [deviceID]: a name, this phone, a listed device without a name (its id alone in the detail, no
    /// name on the row), or a removed device. Nil for an entry without a device.
    public func device(_ deviceID: String?) -> HistoryDevice? {
        guard let id = deviceID else { return nil }
        guard let name = names[id] else { return .removed }
        if id == selfID { return .thisPhone }
        return name.isEmpty ? .unnamed : .named(name)
    }
}

/// An entry's device as History shows it.
public enum HistoryDevice: Equatable, Sendable {
    case named(String)
    /// This phone's own app (the row shows no name; the detail says "This phone").
    case thisPhone
    /// Listed, without a name: no name on the row; the detail shows the device id only.
    case unnamed
    /// Not in `device.list`: "Removed device".
    case removed

    /// The name a row shows; nil for any device without one.
    public var rowName: String? { if case .named(let n) = self { n } else { nil } }
}

/// ``HistoryRepository`` over ``AuditOps``. The search (`q`, `since`, `until`, 0.20.0) has no capability signal: it is
/// sent until the vault refuses it with `bad_request` (then the request is sent again without it) or answers it
/// unfiltered (``searchIgnored()``); from then on, while the vault is open, the app filters on the phone. What was read
/// is kept in memory only and dropped when the vault is no longer open. Mirrors vettid-android `HistoryManager`.
@MainActor
public final class HistoryManager: HistoryRepository {
    static let maxCache = 5_000

    public private(set) var searchUnsupported = false
    private var cache: [Int64: AuditRecord] = [:]
    private var devicesRead: HistoryDevices?
    /// Bumped by ``clear()``: an answer to a call made before is not kept.
    private var generation = 0
    private let ops: @MainActor () async throws -> any AuditOps
    private let selfID: @MainActor () -> String?

    /// [selfID] this phone's device id (its pairing), to mark this phone's own entries.
    public init(selfID: @escaping @MainActor () -> String? = { nil }, ops: @escaping @MainActor () async throws -> any AuditOps) {
        self.selfID = selfID
        self.ops = ops
    }

    public func cached(_ seq: Int64) -> AuditRecord? { cache[seq] }

    public func searchIgnored() { searchUnsupported = true }

    /// Forgets what was read (the vault locked, or a wipe).
    public func clear() {
        generation += 1
        cache = [:]
        devicesRead = nil
        searchUnsupported = false
    }

    public func devices(refresh: Bool = false) async -> HistoryDevices? {
        if let devicesRead, !refresh { return devicesRead }
        let g = generation
        guard let list = try? await ops().deviceList(), g == generation else { return devicesRead }
        let d = HistoryDevices(list, selfID: selfID())
        devicesRead = d
        return d
    }

    public func auditPage(_ request: AuditRequest) async throws -> AuditResult {
        let withSearch = request.hasSearch && !searchUnsupported
        let g = generation
        let page: AuditPage
        do {
            page = try await fetch(request, search: withSearch)
        } catch let f as VaultFailure where withSearch && f.code == "bad_request" {
            if g == generation { searchUnsupported = true }
            page = try await fetch(request, search: false)
        }
        let records = page.entries.map(AuditRecord.init)
        // Read before a lock or a wipe: answered, but not kept.
        if g == generation {
            if cache.count > Self.maxCache { cache = [:] }
            for r in records { cache[r.seq] = r }
        }
        return AuditResult(
            entries: records, nextBeforeSeq: page.nextBeforeSeq, searchSent: withSearch && !searchUnsupported, partial: page.partial
        )
    }

    private func fetch(_ r: AuditRequest, search: Bool) async throws -> AuditPage {
        do {
            let f = r.filter.exportFilters
            return try await ops().auditPage(
                connectionID: f.connectionID, kinds: f.kinds, beforeSeq: r.beforeSeq, limit: r.limit,
                search: search ? AuditSearch(q: f.q, since: f.since, until: f.until) : AuditSearch()
            )
        } catch {
            throw VaultFailures.map(error)
        }
    }
}

/// The integrity check of ANDROID-PLAN §4 History: an unfiltered list, newest first, chains (each entry's `prev` is the
/// next older entry's `hash`, and each `hash` is §10.9's) where its `seq`s are contiguous. Filtered and searched lists
/// are never checked. True when nothing contradicts the chain. Mirrors vettid-android `AuditChain`.
public enum AuditChain {
    public static func consistent(_ newestFirst: [AuditRecord]) -> Bool {
        guard let first = newestFirst.first else { return true }
        var runs: [[AuditEntry]] = [[first.entry]]
        for r in newestFirst.dropFirst() {
            if let last = runs[runs.count - 1].last, r.seq == last.seq - 1 {
                runs[runs.count - 1].append(r.entry)
            } else {
                runs.append([r.entry])
            }
        }
        return runs.allSatisfy { VaultApi.auditChains($0.reversed(), atMillis: millis) }
    }

    /// `at` in Unix milliseconds (§10.9 `at_ms`); nil when it is not the `ts` format.
    static func millis(_ at: String) -> Int64? {
        (try? Timestamps.parseMillis(at)).map { Int64(($0.timeIntervalSince1970 * 1000 + 0.001).rounded(.down)) }
    }
}
