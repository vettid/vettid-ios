import Foundation
import Testing
import VettIDCrypto
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The History export's steps (ANDROID-PLAN §4 History "Export"): preview → confirm → PIN → reading → writing → "Save to
/// Files" → done, and every refusal, through the real ``HistoryExportManager``. Mirrors vettid-android
/// `HistoryExportViewModelTest`.
@MainActor
@Suite struct HistoryExportViewModelTests {
    /// 2026-10-08T14:03:12.511Z.
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_791_468_192.511)
    nonisolated static let preview: AuditExportAnswer = {
        var a = AuditExportAnswer(count: 3, uptoSeq: 30, uptoHash: "AA==")
        a.oldestSeq = 10
        a.newestSeq = 30
        a.oldestAt = "2026-10-01T10:00:00.000Z"
        a.newestAt = "2026-10-08T10:00:00.000Z"
        return a
    }()

    nonisolated static func success() -> AuditExportAnswer {
        var a = preview
        a.entrySeq = 31
        a.answeredAt = t0
        return a
    }

    /// Entries 30, 20, 10: a message to c1 from d1, then two item entries from a removed device.
    nonisolated static func entries(_ n: Int) -> [AuditEntry] {
        (0..<n).map { i in
            let seq = Int64(30 - i * 10)
            return AuditEntry(entryID: "e\(seq)", seq: seq, at: "2026-10-0\(i + 1)T10:00:00.000Z", kind: i == 0 ? "message.sent" : "item.added", connectionID: i == 0 ? "c1" : nil, deviceID: i == 0 ? "d1" : "d9", ref: i == 0 ? nil : "it\(i)", direction: i == 0 ? "out" : nil, prev: "AA==", hash: "AQ==")
        }
    }

    let log = FakeAuditLog()
    let ctx = ExportContext(filter: AuditFilter(category: .messages, connectionID: "c1"), connectionNames: ["c1": "Alice Moreau"], itemNames: ["it1": "Passport"])

    init() {
        log.preview = { Self.preview }
        log.devices = { FakeAuditLog.deviceEntries([("d1", "Pixel 7")]) }
    }

    func model() -> HistoryExportViewModel {
        HistoryExportViewModel(repo: HistoryExportManager(ops: { [log] in log }), now: { Self.t0 })
    }

    /// Up to the PIN step with [format].
    func toPin(_ format: ExportFormat) async -> HistoryExportViewModel {
        let m = model()
        m.start(ctx)
        await m.settle()
        m.chooseFormat(format)
        m.confirm()
        return m
    }

    /// The JSON file "Save to Files" would write.
    func json(_ m: HistoryExportViewModel) throws -> [String: Any] {
        let file = try #require(m.exportFile)
        return try #require(try JSONSerialization.jsonObject(with: file.bytes) as? [String: Any])
    }

    @Test func theWholeFlowWritesTheFileForTheChosenPlace() async throws {
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let m = model()
        m.start(ctx)
        #expect(m.step == .previewing)
        await m.settle()
        #expect(m.step == .confirm(Self.preview, format: nil))
        // No format is preselected: Continue does nothing yet.
        m.confirm()
        #expect(m.step == .confirm(Self.preview, format: nil))
        m.chooseFormat(.json)
        m.confirm()
        #expect(m.step == .pin(ExportPin(preview: Self.preview, format: .json)))
        m.submitPin("12a345")
        m.submitPin("12345")
        #expect(log.exportCalls.isEmpty)
        m.submitPin("123456")
        guard case .pin(let busy) = m.step else { Issue.record("not the PIN step"); return }
        #expect(busy.busy)
        await m.settle()
        #expect(log.exportCalls == ["json:30:123456"])
        #expect(log.calls.first?.beforeSeq == 31 && log.calls.first?.limit == 100 && log.calls.first?.kinds == ["message", "call"] && log.calls.first?.connectionID == "c1")
        guard case .save(let s) = m.step else { Issue.record("not the save step: \(m.step)"); return }
        #expect(s.fileName == "vettid-history-20261008-140312.json" && s.format == .json && !s.requested)
        m.saveRequested()
        guard case .save(let r) = m.step else { return }
        #expect(r.requested)
        #expect(m.exportFile?.name == s.fileName && m.exportFile?.format == .json)
        let o = try json(m)
        #expect(o["exported_at"] as? String == "2026-10-08T14:03:12.511Z")
        let f = try #require(o["filters"] as? [String: Any])
        #expect(f["category"] as? String == "messages" && f["connection_name"] as? String == "Alice Moreau")
        let e = try #require(o["entries"] as? [[String: Any]])
        #expect(e.count == 3)
        #expect(e[0]["connection_name"] as? String == "Alice Moreau" && e[0]["device_name"] as? String == "Pixel 7")
        #expect(e[0]["category"] as? String == "messages" && e[0]["label"] as? String == "Message sent")
        #expect(e[1]["item_name"] as? String == "Passport" && e[1]["device_name"] as? String == "Removed device")
        #expect(e[2]["item_name"] as? String == "Deleted item")
        m.saved(true)
        #expect(m.step == .done(written: 3, authorised: 3))
        // The bytes are dropped once the exporter answered.
        #expect(m.exportFile == nil)
    }

    @Test func csvAndFewerEntriesThanAuthorised() async throws {
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(2), seq: 31) }])
        let m = await toPin(.csv)
        m.submitPin("123456")
        await m.settle()
        guard case .save(let s) = m.step else { Issue.record("not the save step"); return }
        #expect(s.fileName == "vettid-history-20261008-140312.csv")
        let b = Array(try #require(m.exportFile).bytes)
        #expect(b.prefix(3) == [0xEF, 0xBB, 0xBF])
        #expect((String(bytes: b.dropFirst(3), encoding: .utf8) ?? "").components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 3)
        m.saved(true)
        #expect(m.step == .done(written: 2, authorised: 3))
    }

    @Test func nothingToExport() async {
        log.preview = {
            var a = Self.preview
            a.count = 0
            return a
        }
        let m = model()
        m.start(ctx)
        await m.settle()
        #expect(m.step == .nothingToExport)
    }

    @Test func anOpenAlarmRefusesThePreviewAndTheExport() async {
        for (kind, code) in [(FailureKind.credentialFrozen, "credential_frozen"), (.rotationRequired, "rotation_required")] {
            log.preview = { throw VaultFailure(kind, code: code) }
            let m = model()
            m.start(ctx)
            await m.settle()
            #expect(m.step == .refused(.alarm))
        }
        log.preview = { Self.preview }
        log.answerExports([{ throw VaultFailure(.credentialFrozen, code: "credential_frozen") }])
        let m = await toPin(.csv)
        m.submitPin("123456")
        await m.settle()
        #expect(m.step == .refused(.alarm) && m.exportFile == nil)
    }

    @Test func anOlderVaultSaysSo() async {
        for f in [VaultFailure(.notSupported, code: "unsupported_type"), VaultFailure(.vaultCode("bad_request"), code: "bad_request")] {
            log.preview = { throw f }
            let m = model()
            m.start(ctx)
            await m.settle()
            #expect(m.step == .refused(.oldVault))
        }
    }

    @Test func aWrongPinThenTheBackoff() async {
        log.answerExports([{ throw VaultFailure(.badPin, code: "bad_pin") }, { throw VaultFailure(.backoff, code: "backoff", retryAfterSeconds: 60) }])
        let m = await toPin(.json)
        m.submitPin("111111")
        await m.settle()
        guard case .pin(let wrong) = m.step else { Issue.record("not the PIN step"); return }
        #expect(wrong.error == .badPin && wrong.retryUntil == nil && !wrong.busy)
        m.submitPin("222222")
        await m.settle()
        guard case .pin(let held) = m.step else { Issue.record("not the PIN step"); return }
        #expect(held.error == .backoff && held.retryUntil == Self.t0.addingTimeInterval(60))
        #expect(!held.canSend(pinLength: 6, now: Self.t0))
        // Still in the backoff: not sent.
        m.submitPin("333333")
        await m.settle()
        #expect(log.exportCalls.count == 2)
        #expect(held.canSend(pinLength: 6, now: Self.t0.addingTimeInterval(60)))
        #expect(m.exportFile == nil && log.calls.isEmpty)
    }

    @Test func aUtkTheVaultNoLongerKnowsIsReplacedOnce() async {
        log.answerExports([{ throw VaultFailure(.vaultCode("utk_invalid"), code: "utk_invalid") }, { Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let m = await toPin(.json)
        m.submitPin("123456")
        await m.settle()
        #expect(log.exportCalls.count == 2)
        guard case .save = m.step else { Issue.record("not the save step"); return }
    }

    @Test func notFoundAtTheExport() async {
        log.answerExports([{ throw VaultFailure(.notFound, code: "not_found") }])
        let m = await toPin(.csv)
        m.submitPin("123456")
        await m.settle()
        #expect(m.step == .nothingToExport)
    }

    @Test func ownerCheckRequired() async {
        log.preview = { throw VaultFailure(.ownerCheckRequired, code: "owner_check_required") }
        let m = model()
        m.start(ctx)
        await m.settle()
        #expect(m.step == .failed(.ownerCheckRequired))
        log.preview = { Self.preview }
        log.answerExports([{ throw VaultFailure(.ownerCheckRequired, code: "owner_check_required") }])
        let p = await toPin(.csv)
        p.submitPin("123456")
        await p.settle()
        #expect(p.step == .failed(.ownerCheckRequired))
    }

    @Test func cancelWhileReadingDropsEverything() async {
        let gate = TestDeferred<Void>()
        log.listGate = gate
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let m = await toPin(.json)
        m.submitPin("123456")
        #expect(await eventually { m.step == .reading(done: 0, total: 3) })
        m.close()
        gate.complete()
        await m.settle()
        #expect(m.step == .closed && m.exportFile == nil)
        m.saved(true)
        #expect(m.step == .closed)
    }

    /// ANDROID-PLAN §4 History "Export": a dismissed dialog discards the data. The exporter cancelled (or swiped away)
    /// closes the export and drops the bytes; a late "saved" changes nothing.
    @Test func aCancelledExporterDiscardsTheFile() async {
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let m = await toPin(.json)
        m.submitPin("123456")
        await m.settle()
        guard case .save = m.step else { Issue.record("not the save step"); return }
        #expect(m.exportFile != nil)
        m.saveRequested()
        m.saved(false)
        #expect(m.step == .closed && m.exportFile == nil)
        m.saved(true)
        #expect(m.step == .closed)
    }

    @Test func closingAtTheSaveStepDiscardsTheFile() async {
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let m = await toPin(.json)
        m.submitPin("123456")
        await m.settle()
        #expect(m.exportFile != nil)
        m.close()
        #expect(m.step == .closed && m.exportFile == nil)
    }

    @Test func aFailedReadWritesNothing() async {
        log.answerExports([{ Self.success() }])
        log.script([{ throw VaultFailure(.network) }])
        let m = await toPin(.csv)
        m.submitPin("123456")
        await m.settle()
        #expect(m.step == .failed(.network) && m.exportFile == nil)
    }

    /// The exporter could not write the file: said so, and nothing is kept.
    @Test func aFailedWriteSaysSoAndKeepsNothing() async {
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let p = await toPin(.csv)
        p.submitPin("123456")
        await p.settle()
        p.saveFailed()
        #expect(p.step == .failed(nil, saveFailed: true) && p.exportFile == nil)
    }

    @Test func withoutDeviceNamesTheFileKeepsTheIds() async throws {
        log.devices = { throw VaultFailure(.network) }
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let m = await toPin(.json)
        m.submitPin("123456")
        await m.settle()
        guard case .save = m.step else { Issue.record("not the save step"); return }
        let e = try #require(try json(m)["entries"] as? [[String: Any]])
        #expect(e[0]["device_id"] as? String == "d1" && e[0]["device_name"] == nil && e[1]["device_name"] == nil)
    }

    @Test func aListedUnnamedDeviceIsNotRemovedInTheFile() async throws {
        log.devices = { FakeAuditLog.deviceEntries([("d1", "")]) }
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let m = await toPin(.json)
        m.submitPin("123456")
        await m.settle()
        guard case .save = m.step else { Issue.record("not the save step"); return }
        let e = try #require(try json(m)["entries"] as? [[String: Any]])
        #expect(e[0]["device_id"] as? String == "d1" && e[0]["device_name"] == nil)
        #expect(e[1]["device_name"] as? String == "Removed device")
    }

    /// Before the app holds the Vault list (IOS-PLAN §8 I3.1) no item is named, rather than every one called deleted.
    @Test func withoutTheItemListNoItemIsNamed() async throws {
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(3), seq: 31) }])
        let m = model()
        m.start(ExportContext(filter: AuditFilter(), connectionNames: [:]))
        await m.settle()
        m.chooseFormat(.json)
        m.confirm()
        m.submitPin("123456")
        await m.settle()
        guard case .save = m.step else { Issue.record("not the save step"); return }
        let o = try json(m)
        let e = try #require(o["entries"] as? [[String: Any]])
        #expect(e[1]["item_name"] == nil && e[0]["connection_name"] as? String == "Removed connection")
        #expect((o["filters"] as? [String: Any])?.isEmpty == true)
    }

    /// As vettid-android writes the file: a connection whose names have not arrived keeps its name as held (""), only a
    /// gone one is "Removed connection"; the title drops the name.
    @Test func theFileWritesTheConnectionsNameAsHeld() async throws {
        log.answerExports([{ Self.success() }])
        log.script([{ AuditPage(entries: Self.entries(1), seq: 31) }])
        let m = model()
        m.start(ExportContext(filter: AuditFilter(connectionID: "c1"), connectionNames: ["c1": ""]))
        await m.settle()
        m.chooseFormat(.json)
        m.confirm()
        m.submitPin("123456")
        await m.settle()
        let o = try json(m)
        let e = try #require(o["entries"] as? [[String: Any]])
        #expect(e[0]["connection_name"] as? String == "" && e[0]["label"] as? String == "Message sent")
        #expect((o["filters"] as? [String: Any])?["connection_name"] as? String == "")
    }
}

// swiftlint:enable line_length
