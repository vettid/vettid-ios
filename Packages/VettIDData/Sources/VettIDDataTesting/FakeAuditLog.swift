import Foundation
import VettIDCrypto
import VettIDData
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault calls behind History and its export (VAULT-MESSAGING §10.9), answered from an in-memory log for
/// view-model tests, under the real ``HistoryManager`` and ``HistoryExportManager``: `audit.list` newest first with
/// `next_before_seq`, the category prefixes, the connection, the dates and `q` on the kind (``mode``: a vault that
/// searches, one before 0.20.0 that ignores the search, or one that refuses it), the scan budget's `partial` pages
/// (``budget``), or scripted answers in order (``script``); `audit.export`'s preview and export (``preview``,
/// ``exports``); and `device.list` (``devices``). Every request is recorded in ``calls``. Mirrors the `Log` and `Vault`
/// fakes of vettid-android `HistoryPagerTest` and `HistoryViewModelTest`.
public final class FakeAuditLog: AuditOps, @unchecked Sendable {
    /// How the fake vault treats `q`, `since` and `until`.
    public enum Mode: Sendable { case searches, ignores, refuses }

    /// One `audit.list` request as sent.
    public struct Call: Equatable, Sendable {
        public var connectionID: String?
        public var kinds: [String]?
        public var beforeSeq: Int64?
        public var limit: Int
        public var q: String?
        public var since: String?
        public var until: String?

        public init(connectionID: String? = nil, kinds: [String]? = nil, beforeSeq: Int64? = nil, limit: Int = 50, q: String? = nil, since: String? = nil, until: String? = nil) {
            self.connectionID = connectionID
            self.kinds = kinds
            self.beforeSeq = beforeSeq
            self.limit = limit
            self.q = q
            self.since = since
            self.until = until
        }
    }

    private let lock = NSLock()
    private var entriesValue: [AuditEntry]
    private var callsValue: [Call] = []
    private var scriptValue: [@Sendable () throws -> AuditPage] = []
    private var exportsValue: [@Sendable () throws -> AuditExportAnswer] = []
    private var exportCallsValue: [String] = []

    public var mode: Mode
    /// At most this many candidates evaluated per searched request (§10.9 scan budget); nil: no budget.
    public var budget: Int?
    /// The preview's answer, or its failure.
    public var preview: @Sendable () throws -> AuditExportAnswer = { throw VaultFailure(.vaultCode("internal"), code: "internal") }
    /// `device.list`, or its failure.
    public var devices: @Sendable () throws -> [DeviceEntry] = { [] }
    /// Suspends every `audit.list` until completed.
    public var listGate: TestDeferred<Void>?

    /// [entries] oldest first.
    public init(_ entries: [AuditEntry] = [], mode: Mode = .searches) {
        entriesValue = entries
        self.mode = mode
    }

    public var entries: [AuditEntry] {
        get { lock.withLock { entriesValue } }
        set { lock.withLock { entriesValue = newValue } }
    }

    public var calls: [Call] { lock.withLock { callsValue } }

    /// The exports asked for: `<format>:<upto_seq>:<pin>`.
    public var exportCalls: [String] { lock.withLock { exportCallsValue } }

    /// Answers the next `audit.list` requests with these, in order, before the log answers again.
    public func script(_ pages: [@Sendable () throws -> AuditPage]) { lock.withLock { scriptValue += pages } }

    /// Answers the next exports with these, in order.
    public func answerExports(_ answers: [@Sendable () throws -> AuditExportAnswer]) { lock.withLock { exportsValue += answers } }

    /// The vault records one more entry, a minute after the newest, chained to it.
    public func append(_ kind: String, connectionID: String? = nil, ref: String? = nil) {
        lock.withLock {
            let last = entriesValue.last
            let at = last.flatMap { try? Timestamps.parseMillis($0.at) }.map { $0.addingTimeInterval(60) } ?? Date(timeIntervalSince1970: 1_791_288_000)
            entriesValue.append(Self.entry(seq: (last?.seq ?? 0) + 1, at: at, kind: kind, connectionID: connectionID, ref: ref, prev: last.map { (try? Base64s.decodeStd($0.hash)) ?? [] } ?? [UInt8](repeating: 0, count: 32)))
        }
    }

    public func auditPage(connectionID: String?, kinds: [String]?, beforeSeq: Int64?, limit: Int, search: AuditSearch) async throws -> AuditPage {
        let scripted: (@Sendable () throws -> AuditPage)? = lock.withLock {
            callsValue.append(Call(connectionID: connectionID, kinds: kinds, beforeSeq: beforeSeq, limit: limit, q: search.q, since: search.since, until: search.until))
            return scriptValue.isEmpty ? nil : scriptValue.removeFirst()
        }
        if let gate = listGate { try await gate.value() }
        if let scripted { return try scripted() }
        return try page(connectionID: connectionID, kinds: kinds, beforeSeq: beforeSeq, limit: limit, search: search)
    }

    private func page(connectionID: String?, kinds: [String]?, beforeSeq: Int64?, limit: Int, search: AuditSearch) throws -> AuditPage {
        let searched = search != AuditSearch()
        if mode == .refuses, searched { throw VaultFailure(.vaultCode("bad_request"), code: "bad_request") }
        let honour = mode == .searches
        let all = entries
        let since = search.since.flatMap { try? Timestamps.parseMillis($0) }
        let until = search.until.flatMap { try? Timestamps.parseMillis($0) }
        let candidates = all.reversed().filter { e in
            let at = try? Timestamps.parseMillis(e.at)
            return (beforeSeq.map { e.seq < $0 } ?? true) && (connectionID.map { e.connectionID == $0 } ?? true)
                && (kinds.map { k in k.contains { AuditCategory.matches(e.kind, prefix: $0) } } ?? true)
                && (!honour || since.map { s in at.map { $0 >= s } ?? false } ?? true)
                && (!honour || until.map { u in at.map { $0 < u } ?? false } ?? true)
        }
        let head = all.last?.seq ?? 0
        if honour, let q = search.q {
            let evaluated = budget.map { Array(candidates.prefix($0)) } ?? candidates
            let matches = Array(evaluated.filter { AuditFilter.matches(q, fields: AuditFilter.kindText($0.kind)) }.prefix(limit))
            let ranOut = evaluated.count < candidates.count && matches.count < limit
            let cursor: Int64? = ranOut ? evaluated.last?.seq : (matches.count == limit && (candidates.last?.seq ?? 0) < (matches.last?.seq ?? 0) ? matches.last?.seq : nil)
            return AuditPage(entries: matches, seq: head, nextBeforeSeq: cursor, partial: ranOut)
        }
        let page = Array(candidates.prefix(limit))
        return AuditPage(entries: page, seq: head, nextBeforeSeq: candidates.count > limit ? page.last?.seq : nil)
    }

    public func auditExportPreview(_ filters: AuditExportFilters, format: String?) async throws -> AuditExportAnswer { try preview() }

    public func auditExport(_ filters: AuditExportFilters, format: String, uptoSeq: Int64, pin: String) async throws -> AuditExportAnswer {
        let next: (@Sendable () throws -> AuditExportAnswer)? = lock.withLock {
            exportCallsValue.append("\(format):\(uptoSeq):\(pin)")
            return exportsValue.isEmpty ? nil : exportsValue.removeFirst()
        }
        guard let next else { throw VaultFailure(.vaultCode("internal"), code: "internal") }
        return try next()
    }

    public func deviceList() async throws -> [DeviceEntry] { try devices() }

    // MARK: - Fixtures

    /// One entry chained to [prev] as §10.9 hashes it.
    public static func entry(seq: Int64, at: Date, kind: String, connectionID: String? = nil, deviceID: String? = nil, ref: String? = nil, direction: String? = nil, prev: [UInt8]) -> AuditEntry {
        let ms = Int64((at.timeIntervalSince1970 * 1000).rounded(.down))
        var data = Array("vettid/vms/2/audit".utf8) + prev + Bytes.uintBE(UInt64(seq), 8) + Bytes.uintBE(UInt64(ms), 8)
        for f in [kind, connectionID, deviceID, ref, direction] {
            let b = Array((f ?? "").utf8)
            data += Bytes.uintBE(UInt64(b.count), 2) + b
        }
        let when = Date(timeIntervalSince1970: Double(ms) / 1000)
        return AuditEntry(entryID: "e\(seq)", seq: seq, at: Timestamps.formatMillis(when), kind: kind, connectionID: connectionID, deviceID: deviceID, ref: ref, direction: direction, prev: Base64s.encodeStd(prev), hash: Base64s.encodeStd(Bytes.sha256(data)))
    }

    /// [n] entries, seq 1…n, a minute apart, the newest at [newest], chained; the kinds in turn, even seqs of [connection].
    public static func chain(_ n: Int, kinds: [String] = ["vault.unlocked"], newest: Date = Date(timeIntervalSince1970: 1_791_288_000), connection: String? = nil) -> [AuditEntry] {
        var prev = [UInt8](repeating: 0, count: 32)
        var out: [AuditEntry] = []
        for s in 1...max(n, 1) where n > 0 {
            let e = entry(seq: Int64(s), at: newest.addingTimeInterval(-60 * Double(n - s)), kind: kinds[s % kinds.count], connectionID: s.isMultiple(of: 2) ? connection : nil, prev: prev)
            prev = (try? Base64s.decodeStd(e.hash)) ?? []
            out.append(e)
        }
        return out
    }

    /// `device.list`'s entries from (id, name) pairs (an empty name: a device listed without one).
    public static func deviceEntries(_ list: [(String, String)]) -> [DeviceEntry] {
        let json = "[" + list.map { #"{"id":"\#($0.0)","kind":"app","state":"active","name":"\#($0.1)"}"# }.joined(separator: ",") + "]"
        return (try? VaultJSON.decode([DeviceEntry].self, Array(json.utf8))) ?? []
    }
}

// swiftlint:enable line_length
