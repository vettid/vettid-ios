import Foundation
import VettIDVault

/// A History export's file format (VAULT-MESSAGING 0.22.0 §10.9): the wire name, the content type and the extension.
public enum ExportFormat: String, CaseIterable, Sendable {
    case csv
    case json

    public var wire: String { rawValue }
    public var fileExtension: String { rawValue }

    /// §10.9: `text/csv; charset=utf-8; header=present`, or `application/json`.
    public var contentType: String {
        switch self {
        case .csv: "text/csv; charset=utf-8; header=present"
        case .json: "application/json"
        }
    }
}

/// The member's History export (0.22.0 §10.9, ANDROID-PLAN §4 History; IOS-PLAN §4: saved through Save to Files). Failures
/// are ``VaultFailure``s: `credential_frozen` / `rotation_required` while a clone alarm is open (the preview too),
/// `unsupported_type` from a vault before 0.22.0, `not_found` when nothing matches, `bad_pin`, `backoff` with its
/// `retry_after`. Mirrors vettid-android `HistoryExportRepository`.
@MainActor
public protocol HistoryExportRepository: AnyObject, Sendable {
    /// The dry run: what [filter] matches, without the PIN.
    func preview(_ filter: AuditFilter) async throws -> AuditExportAnswer

    /// The export: the vault PIN sealed to a UTK authorises a file of [format] for the entries up to [uptoSeq].
    func export(_ filter: AuditFilter, format: ExportFormat, uptoSeq: Int64, pin: String) async throws -> AuditExportAnswer

    /// The authorised entries, newest first: `audit.list` with [filter] from `before_seq` = `upto_seq` + 1, `limit` 100,
    /// following `next_before_seq` across partial pages, the first ``AuditExportAnswer/count`` (fewer when the retention
    /// dropped some meanwhile). [onProgress] gets the number read so far. Cancellable between pages.
    func entries(_ filter: AuditFilter, answer: AuditExportAnswer, onProgress: @MainActor (Int) -> Void) async throws -> [AuditRecord]

    /// The vault's devices (`device.list`, §10.3), for the file's device names as History shows them.
    func devices() async throws -> HistoryDevices
}

/// ``HistoryExportRepository`` over ``AuditOps``. The paging reads `audit.list` directly, never with
/// ``HistoryManager``'s fallback for an older vault's search: a vault that answered `audit.export` searches, and an export
/// must hold only what its filters match. Entries newer than `upto_seq`, repeated or out of order are dropped: the file
/// holds only what the member confirmed (§10.9 "What the PIN is for"). Mirrors vettid-android `HistoryExportManager`.
@MainActor
public final class HistoryExportManager: HistoryExportRepository {
    /// 0.22.0 §10.9: `limit` 100 keeps each page well under the claim-check threshold.
    public static let pageSize = 100
    /// 10,000 entries are 100 full pages; partial pages of a search (§10.9 scan budget) add a few.
    static let maxPages = 1_000
    /// The export cap (§10.9).
    public static let maxEntries: Int64 = 10_000

    private let ops: @MainActor () async throws -> any AuditOps
    private let pageSize: Int
    private let selfID: @MainActor () -> String?

    public init(
        ops: @escaping @MainActor () async throws -> any AuditOps, pageSize: Int = HistoryExportManager.pageSize,
        selfID: @escaping @MainActor () -> String? = { nil }
    ) {
        self.ops = ops
        self.pageSize = pageSize
        self.selfID = selfID
    }

    private func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    public func preview(_ filter: AuditFilter) async throws -> AuditExportAnswer {
        try await guarded { try await ops().auditExportPreview(filter.exportFilters, format: nil) }
    }

    public func export(_ filter: AuditFilter, format: ExportFormat, uptoSeq: Int64, pin: String) async throws -> AuditExportAnswer {
        let f = filter.exportFilters
        do {
            return try await guarded { try await ops().auditExport(f, format: format.wire, uptoSeq: uptoSeq, pin: pin) }
        } catch let e as VaultFailure where e.code == "utk_invalid" {
            // A UTK the vault no longer knows (it was spent): once more with the next one from the pool.
            return try await guarded { try await ops().auditExport(f, format: format.wire, uptoSeq: uptoSeq, pin: pin) }
        }
    }

    public func entries(
        _ filter: AuditFilter, answer: AuditExportAnswer, onProgress: @MainActor (Int) -> Void = { _ in }
    ) async throws -> [AuditRecord] {
        let want = Int(min(max(answer.count, 0), Self.maxEntries))
        var out: [AuditRecord] = []
        guard want > 0 else { return out }
        let f = filter.exportFilters
        let search = AuditSearch(q: f.q, since: f.since, until: f.until)
        var before: Int64? = answer.uptoSeq + 1
        var last = answer.uptoSeq + 1
        var pages = 0
        while let cursor = before, out.count < want, pages < Self.maxPages {
            try Task.checkCancellation()
            let page = try await guarded {
                try await ops().auditPage(connectionID: f.connectionID, kinds: f.kinds, beforeSeq: cursor, limit: pageSize, search: search)
            }
            pages += 1
            for e in page.entries where out.count < want && e.seq < last && e.seq <= answer.uptoSeq {
                out.append(AuditRecord(e))
                last = e.seq
            }
            onProgress(out.count)
            // Only a cursor that moves down continues (a page without one is the end of the results).
            before = page.nextBeforeSeq.flatMap { $0 < cursor ? $0 : nil }
        }
        return out
    }

    public func devices() async throws -> HistoryDevices {
        HistoryDevices(try await guarded { try await ops().deviceList() }, selfID: selfID())
    }
}
