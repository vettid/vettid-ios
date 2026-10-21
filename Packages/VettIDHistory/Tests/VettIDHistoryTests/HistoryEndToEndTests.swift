import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory
import VettIDVault

/// History and its export end to end (IOS-PLAN §8 I2.3's acceptance, "export via Save to Files"): the view models over
/// this phone's ``VaultManager`` against ``FakeVaultService``, which answers `audit.list` and `audit.export` as
/// vettid-vault's `features/audit` does: the preview, a wrong PIN audited as `vault.pin_failed`, the PIN backoff, the
/// file of the entries the member confirmed, `audit.exported` on top of the list shown again, and an open clone alarm.
@MainActor
@Suite(.serialized) struct HistoryEndToEndTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    let docs = FakeDocuments()

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    /// Enrolled and open.
    func open() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
    }

    func toPin(_ export: HistoryExportViewModel, _ filter: AuditFilter = AuditFilter(query: "credential rotated")) async {
        export.start(ExportContext(filter: filter))
        await settle { if case .confirm = export.step { true } else { false } }
        export.chooseFormat(.json)
        export.confirm()
    }

    /// Waits (at most 10 s) for [condition]: the vault answers on its own tasks.
    func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func historySearchAndTheExportThroughTheScreensModels() async throws {
        defer { phone.close() }
        try await open()
        service.storeAuditEntries(30, kinds: ["vault.unlocked", "credential.rotated"])
        let history = HistoryViewModel(history: m.history, connections: m.connections, debounce: .zero)
        await settle { !history.state.loading }
        #expect(history.state.error == nil && history.state.entries.count >= 30 && !history.state.chainBroken)
        history.setQuery("credential rotated")
        await settle { !history.state.loading && history.state.filter.q != nil }
        #expect(!history.state.localSearch && history.state.entries.allSatisfy { $0.kind == "credential.rotated" })

        let export = HistoryExportViewModel(repo: m.historyExport, documents: docs)
        await toPin(export)
        guard case .pin(let step) = export.step else { Issue.record("not the PIN step: \(export.step)"); return }
        #expect(step.preview.count >= 15 && service.exportsSeen.isEmpty)
        // A wrong PIN: refused, audited, not an owner check failure.
        export.submitPin("999999")
        await settle { if case .pin(let s) = export.step { !s.busy } else { true } }
        guard case .pin(let wrong) = export.step else { Issue.record("not the PIN step: \(export.step)"); return }
        #expect(wrong.error == .badPin && service.auditKinds.last == "vault.pin_failed")
        export.submitPin(pin)
        await settle { if case .save = export.step { true } else { false } }
        guard case .save(let s) = export.step else { Issue.record("not the save step: \(export.step)"); return }
        let bytes = try #require(docs.files[s.file])
        let o = try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        let entries = try #require(o["entries"] as? [[String: Any]])
        #expect(entries.count == step.preview.count)
        #expect(entries.allSatisfy { $0["kind"] as? String == "credential.rotated" })
        #expect(entries.allSatisfy { $0["label"] as? String == "Your credential was renewed" })
        #expect(service.lastAuditEntry?.kind == "audit.exported" && service.exportsSeen.last?.pin == pin)
        export.saved(true)
        #expect(export.step == .done(written: Int(step.preview.count), authorised: step.preview.count) && docs.files.isEmpty)

        // The list shown again has the export on top.
        history.clearFilters()
        await settle { !history.state.loading && history.state.filter.isEmpty }
        history.refresh()
        await settle { history.state.entries.first?.kind == "audit.exported" }
        #expect(history.state.entries.first?.kind == "audit.exported")
        let summary = HistoryText.exportSummary("audit.exported", history.state.entries.first?.entry.ref)
        #expect(summary == "JSON · \(step.preview.count) entries")
    }

    /// Three wrong PINs start the PIN backoff of §11.8: the export says when to try again, and does not send meanwhile.
    @Test func theExportFollowsThePinBackoff() async throws {
        defer { phone.close() }
        try await open()
        service.storeAuditEntries(5, kinds: ["credential.rotated"])
        let export = HistoryExportViewModel(repo: m.historyExport, documents: docs)
        await toPin(export)
        for wrong in ["111111", "222222", "333333"] {
            export.submitPin(wrong)
            await settle { if case .pin(let s) = export.step { !s.busy } else { true } }
        }
        export.submitPin("444444")
        await settle { if case .pin(let s) = export.step { !s.busy } else { true } }
        guard case .pin(let held) = export.step else { Issue.record("not the PIN step: \(export.step)"); return }
        #expect(held.error == .backoff && held.retryUntil != nil)
        let sent = service.exportsSeen.count
        export.submitPin(pin)
        #expect(service.exportsSeen.count == sent && docs.files.isEmpty)
    }

    /// An open clone alarm refuses the export, the preview included.
    @Test func anOpenAlarmRefusesTheExport() async throws {
        defer { phone.close() }
        try await open()
        service.storeAuditEntries(5)
        service.raiseCloneAlarm()
        let export = HistoryExportViewModel(repo: m.historyExport, documents: docs)
        export.start(ExportContext(filter: AuditFilter()))
        await settle { export.step != .previewing }
        #expect(export.step == .refused(.alarm))
    }
}
