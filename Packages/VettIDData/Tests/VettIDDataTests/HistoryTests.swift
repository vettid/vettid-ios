import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault calls of History and its export, answered from a list of entries; every call recorded.
final class FakeAuditOps: AuditOps, @unchecked Sendable {
    var entries: [AuditEntry] = []
    var calls: [String] = []
    var refuseSearch = false
    var exportErrors: [String] = []
    /// A search that runs out of its budget after this many entries per request (§10.9 Scan budget).
    var budget: Int?

    func auditPage(connectionID: String?, kinds: [String]?, beforeSeq: Int64?, limit: Int, search: AuditSearch) async throws -> AuditPage {
        calls.append("list:\(beforeSeq.map(String.init) ?? "-"):\(search.q ?? "-")")
        if refuseSearch, search != AuditSearch() { throw VaultOpError(type: "audit.list", code: "bad_request", detail: "", body: nil) }
        let pool = entries.reversed().filter { beforeSeq == nil || $0.seq < beforeSeq! }.filter { e in kinds == nil || kinds!.contains { e.kind.hasPrefix($0) } }
        let scanned = budget.map { Array(pool.prefix($0)) } ?? pool
        let hits = scanned.filter { search.q == nil || $0.kind.contains(search.q!) }
        let page = Array(hits.prefix(limit))
        let partial = budget != nil && page.count < limit && scanned.count < pool.count
        let next = partial ? scanned.last?.seq : (hits.count > limit ? page.last?.seq : nil)
        return AuditPage(entries: page, seq: entries.last?.seq ?? 0, nextBeforeSeq: next, partial: partial)
    }

    func auditExportPreview(_ filters: AuditExportFilters, format: String?) async throws -> AuditExportAnswer {
        calls.append("preview")
        return AuditExportAnswer(count: Int64(entries.count), uptoSeq: entries.last?.seq ?? 0, uptoHash: entries.last?.hash ?? "")
    }

    func auditExport(_ filters: AuditExportFilters, format: String, uptoSeq: Int64, pin: String) async throws -> AuditExportAnswer {
        calls.append("export:\(format):\(uptoSeq)")
        if !exportErrors.isEmpty { throw VaultOpError(type: "audit.export", code: exportErrors.removeFirst(), detail: "", body: nil) }
        var a = AuditExportAnswer(count: Int64(entries.filter { $0.seq <= uptoSeq }.count), uptoSeq: uptoSeq, uptoHash: "aGFzaA==")
        a.entrySeq = uptoSeq + 1
        return a
    }

    func deviceList() async throws -> [DeviceEntry] {
        try VaultJSON.decode([DeviceEntry].self, Array(#"[{"id":"d1","kind":"app","state":"active","name":"iPhone"},{"id":"d2","kind":"desktop","state":"active","name":" "}]"#.utf8))
    }

    /// [n] entries chained as §10.9 says, the kinds in turn.
    static func chain(_ n: Int, kinds: [String] = ["vault.unlocked", "message.received", "credential.rotated"]) -> [AuditEntry] {
        var prev = [UInt8](repeating: 0, count: 32)
        var out: [AuditEntry] = []
        for i in 1...n {
            let at = "2026-10-20T12:00:\(String(format: "%02d", i % 60)).000Z"
            let kind = kinds[(i - 1) % kinds.count]
            let ms = AuditChain.millis(at)!
            var data = Array("vettid/vms/2/audit".utf8) + prev + Bytes.uintBE(UInt64(i), 8) + Bytes.uintBE(UInt64(ms), 8)
            for f in [kind, "", "", "", ""] { data += Bytes.uintBE(UInt64(f.utf8.count), 2) + Array(f.utf8) }
            let h = Bytes.sha256(data)
            out.append(AuditEntry(entryID: "e\(i)", seq: Int64(i), at: at, kind: kind, prev: Base64s.encodeStd(prev), hash: Base64s.encodeStd(h)))
            prev = h
        }
        return out
    }
}

/// History and its export (VAULT-MESSAGING §10.9, ANDROID-PLAN §4 History; IOS-PLAN §4): the categories, the search
/// text, an older vault's search, the chain check, the export's paging and its CSV and JSON files. Mirrors
/// vettid-android `HistoryExportManagerTest`, `HistoryExportFormatsTest` and `AuditKindsTest`.
@MainActor
@Suite struct HistoryTests {
    let ops = FakeAuditOps()

    @Test func categoriesAndTheSearchText() {
        #expect(AuditCategory.of("owner_check.failed") == .vaultAccess && AuditCategory.of("audit.exported") == .security)
        #expect(AuditCategory.of("critical-secret.used") == .items && AuditCategory.of("drop.ask_muted") == .dropped)
        #expect(AuditCategory.of("vaultx.y") == .other && AuditCategory.of("future") == .other && !AuditCategory.filters.contains(.other))
        #expect(AuditCategory.items.rawValue == "vault" && AuditFilter(category: .security).kinds == ["credential", "identity", "recovery", "audit"])
        #expect(AuditFilter(query: "  ").q == nil && AuditFilter(query: " Cafe\u{0301}\u{7}  ").q == "Café")
        let long = String(repeating: "é", count: 70)
        #expect(AuditFilter.searchText(long)?.utf8.count == 128)
        #expect(AuditFilter.kindText("credential.password_changed") == ["credential.password_changed", "credential password changed"])
        #expect(AuditFilter.matches("PASSWORD", fields: ["", "credential password changed"]) && !AuditFilter.matches("x", fields: [""]))
    }

    @Test func anOlderVaultsSearchFallsBackToThePhone() async throws {
        ops.entries = FakeAuditOps.chain(5)
        ops.refuseSearch = true
        let h = HistoryManager { [ops] in ops }
        let r = try await h.auditPage(AuditRequest(filter: AuditFilter(query: "rotated")))
        #expect(!r.searchSent && h.searchUnsupported && r.entries.count == 5)
        #expect(ops.calls == ["list:-:rotated", "list:-:-"])
        #expect(h.cached(3)?.kind == "credential.rotated")
        #expect(await h.deviceNames() == ["d1": "iPhone"])
        h.clear()
        #expect(h.cached(3) == nil && !h.searchUnsupported)
    }

    @Test func theChainCheck() {
        let records = FakeAuditOps.chain(6).reversed().map(AuditRecord.init)
        #expect(AuditChain.consistent(records))
        #expect(AuditChain.consistent(records.enumerated().filter { $0.offset != 2 }.map(\.element)), "a gap starts a new run")
        var bad = records
        bad[1].entry.kind = "vault.locked"
        #expect(!AuditChain.consistent(bad))
    }

    @Test func theExportReadsTheAuthorisedEntriesAcrossPartialPages() async throws {
        ops.entries = FakeAuditOps.chain(250)
        let x = HistoryExportManager(ops: { [ops] in ops }, pageSize: 100)
        let preview = try await x.preview(AuditFilter())
        #expect(preview.count == 250 && preview.uptoSeq == 250)
        ops.exportErrors = ["utk_invalid"]
        let answer = try await x.export(AuditFilter(), format: .csv, uptoSeq: 240, pin: "402817")
        #expect(answer.count == 240 && ops.calls.filter { $0.hasPrefix("export") }.count == 2, "a spent UTK: once more")
        ops.entries = FakeAuditOps.chain(253) // newer entries meanwhile are not included
        var progress: [Int] = []
        let rows = try await x.entries(AuditFilter(), answer: answer, onProgress: { progress.append($0) })
        #expect(rows.count == 240 && rows.first?.seq == 240 && rows.last?.seq == 1 && progress.last == 240)

        ops.entries = FakeAuditOps.chain(90)
        ops.budget = 30
        var a = AuditExportAnswer(count: 30, uptoSeq: 90, uptoHash: "")
        a.entrySeq = 91
        let found = try await x.entries(AuditFilter(query: "rotated"), answer: a)
        #expect(found.count == 30 && found.allSatisfy { $0.kind == "credential.rotated" }, "partial pages are followed")
        ops.exportErrors = ["bad_pin"]
        await #expect(throws: VaultFailure.self) { _ = try await x.export(AuditFilter(), format: .json, uptoSeq: 1, pin: "0") }
    }

    @Test func theCsvFile() throws {
        var e = FakeAuditOps.chain(1)[0]
        e.ref = "=SUM(A1)"
        e.direction = "in"
        let rows = [ExportRow(record: AuditRecord(e), label: "Vault, \"unlocked\"", connectionName: "+Lee", deviceName: "Line\r\nTwo")]
        let b = HistoryCsv.bytes(rows)
        #expect(Array(b.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let text = (String(bytes: b.dropFirst(3), encoding: .utf8) ?? "")
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "seq,time,category,event,kind,direction,connection,device,item,ref,hash")
        #expect(lines[1].hasPrefix(#"1,2026-10-20T12:00:01.000Z,unlocks,"Vault, ""unlocked""",vault.unlocked,in,'+Lee,"Line"#))
        #expect(text.hasSuffix(",'=SUM(A1),\(HistoryCsv.hex(e.hash))\r\n") && HistoryCsv.hex(e.hash).count == 64)
        #expect(HistoryCsv.field("-1") == "'-1" && HistoryCsv.field("\tx") == "'\tx" && HistoryCsv.field("plain") == "plain")
    }

    @Test func theJsonFileAndItsName() throws {
        var e = FakeAuditOps.chain(2)[1]
        e.connectionID = "c1"
        var answer = AuditExportAnswer(count: 1, uptoSeq: 2, uptoHash: "aGFzaA==")
        answer.oldestSeq = 2
        answer.newestSeq = 2
        let at = Date(timeIntervalSince1970: 1_791_115_200.511)
        let filter = AuditFilter(category: .messages, connectionID: "c1")
        let header = ExportHeader(exportedAt: at, filters: ExportFilters(filter, connectionName: "Morgan Lee"), answer: answer)
        let b = HistoryFiles.bytes(.json, header: header, rows: [ExportRow(record: AuditRecord(e), label: "Message received", connectionName: "Morgan Lee")])
        let o = try StrictJson.parseObject(b)
        #expect(try o.string("format") == "vettid-history" && o.string("exported_at") == Timestamps.formatMillis(at))
        let f = try #require(VaultJSON.obj(o, "filters"))
        #expect(VaultJSON.string(f, "category") == "messages" && VaultJSON.strings(f, "kinds") == ["message", "call"] && VaultJSON.string(f, "connection_name") == "Morgan Lee" && f["q"] == nil)
        #expect(VaultJSON.int(o, "count") == 1 && VaultJSON.int(o, "authorised_count") == 1 && VaultJSON.int(o, "oldest_seq") == 2)
        let entry = try #require(VaultJSON.objects(o, "entries").first)
        #expect(VaultJSON.string(entry, "category") == "messages" && VaultJSON.string(entry, "connection_id") == "c1" && entry["device_id"] == nil && entry["direction"] == nil)
        #expect(VaultJSON.string(entry, "prev") == e.prev && VaultJSON.string(entry, "hash") == e.hash)
        #expect(!(String(bytes: b, encoding: .utf8) ?? "").contains("null"))
        #expect(HistoryFiles.fileName(at, .json) == "vettid-history-20261004-120000.json")
    }
}

// swiftlint:enable line_length
