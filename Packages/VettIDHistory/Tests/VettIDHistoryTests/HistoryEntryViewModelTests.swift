import Foundation
import Testing
import VettIDCrypto
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// An entry's detail: read from what History read or from the vault, its connection, item and device, and a failed
/// recovery attempt's outcome from the `recovery.open` entries around it (IOS-PLAN §4.1). Mirrors the detail part of
/// vettid-android `HistoryEventTitlesTest` and the entry page of `HistoryDeviceTest`.
@MainActor
@Suite struct HistoryEntryViewModelTests {
    /// 2026-10-19T12:00:00Z.
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_792_411_200)
    let connections = FakeConnections()

    nonisolated static func entry(_ seq: Int64, _ kind: String, _ ref: String? = nil, seconds: TimeInterval = 0, conn: String? = nil, device: String? = nil) -> AuditEntry {
        AuditEntry(entryID: "e\(seq)", seq: seq, at: Timestamps.formatMillis(t0.addingTimeInterval(seconds)), kind: kind, connectionID: conn, deviceID: device, ref: ref)
    }

    nonisolated static let attempt = entry(20, "recovery.attempt", "2/3/not_success/counter")

    func model(_ log: FakeAuditLog, seq: Int64 = 20, itemNames: [String: String]? = nil) async -> HistoryEntryViewModel {
        var provider: (@MainActor () -> [String: String]?)?
        if let itemNames { provider = { itemNames } }
        let m = HistoryEntryViewModel(seq: seq, history: HistoryManager(selfID: { "d-self" }) { log }, connections: connections, itemNames: provider)
        await m.settle()
        return m
    }

    @Test func anAttemptsDetailReadsTheMatchingOpen() async throws {
        let log = FakeAuditLog()
        log.script([
            { AuditPage(entries: [Self.attempt], seq: 30) },
            // The hour around it: a counted open 40 s before, an uncounted one nearer; the counted one names its phone.
            { AuditPage(entries: [Self.attempt, Self.entry(12, "recovery.open", "01JREC/busy", seconds: -5), Self.entry(11, "recovery.open", "01JREC/wrong/UGl4ZWwgNw", seconds: -40)], seq: 30) },
        ])
        let m = await model(log)
        #expect(m.state.outcome == .matched("wrong", phoneName: "Pixel 7") && m.state.entry?.seq == 20 && !m.state.loading)
        #expect(log.calls[0].beforeSeq == 21 && log.calls[0].limit == 1)
        let read = log.calls[1]
        #expect(read.kinds == ["recovery.open", "recovery.attempt"] && read.limit == 100)
        #expect(read.since == "2026-10-19T11:00:00.000Z" && read.until == "2026-10-19T13:00:00.000Z")
    }

    @Test func anAttemptWithoutAMatchingOpenSaysDetailsNotAvailable() async {
        let log = FakeAuditLog()
        log.script([
            { AuditPage(entries: [Self.attempt], seq: 30) },
            // An open outside the window, and one a vault that ignored the range returned from long before.
            { AuditPage(entries: [Self.attempt, Self.entry(11, "recovery.open", "01JREC/wrong", seconds: -1_200), Self.entry(3, "recovery.open", "01JOLD/wrong", seconds: -86_400)], seq: 30) },
        ])
        let m = await model(log)
        #expect(m.state.outcome == AuditKinds.Outcome.none)
    }

    /// The vault wrote the attempt again as `success` (same `at`): the older row says "Later successful.".
    @Test func anAttemptWrittenAgainAsSuccessIsLaterSuccessful() async {
        let log = FakeAuditLog()
        log.script([
            { AuditPage(entries: [Self.attempt], seq: 30) },
            { AuditPage(entries: [Self.entry(25, "recovery.attempt", "2/3/success/counter"), Self.attempt, Self.entry(11, "recovery.open", "01JREC/wrong", seconds: -40)], seq: 30) },
        ])
        let m = await model(log)
        #expect(m.state.outcome == .laterSuccessful)
    }

    @Test func aFailedReadLeavesTheOutcomeUnknown() async {
        let log = FakeAuditLog()
        log.script([{ AuditPage(entries: [Self.attempt], seq: 30) }, { throw VaultFailure(.vaultCode("internal"), code: "internal") }])
        let m = await model(log)
        #expect(log.calls.count == 2 && m.state.outcome == .unknown && m.state.error == nil && m.state.entry != nil)
    }

    @Test func aSuccessfulAttemptReadsNothingMore() async {
        let log = FakeAuditLog()
        log.script([{ AuditPage(entries: [Self.entry(20, "recovery.attempt", "2/4/success/counter")], seq: 30) }])
        let m = await model(log)
        #expect(log.calls.count == 1 && m.state.outcome == .unknown)
    }

    @Test func anEntryReadBeforeIsNotAskedForAgain() async throws {
        let log = FakeAuditLog(FakeAuditLog.chain(5))
        let repo = HistoryManager { log }
        _ = try await repo.auditPage(AuditRequest())
        let m = HistoryEntryViewModel(seq: 3, history: repo)
        await m.settle()
        #expect(m.state.entry?.entry.entryID == "e3" && log.calls.count == 1)
    }

    @Test func aMissingEntryAndAFailure() async {
        let log = FakeAuditLog()
        log.script([{ AuditPage(entries: [Self.entry(19, "vault.unlocked")], seq: 30) }, { throw VaultFailure(.network) }, { AuditPage(entries: [Self.entry(20, "vault.unlocked")], seq: 30) }])
        let m = await model(log)
        #expect(m.state.missing && m.state.entry == nil && !m.state.loading)
        m.load()
        await m.settle()
        #expect(m.state.error == .network)
        m.load()
        await m.settle()
        #expect(m.state.error == nil && m.state.entry?.seq == 20 && !m.state.missing)
    }

    @Test func theConnectionItemAndDeviceAreNamed() async {
        var ada = ConnectionInfo(id: "c1", name: "", state: .active)
        ada.firstName = "Ada"
        ada.lastName = "Lovelace"
        connections.connections = [ada, ConnectionInfo(id: "c2", name: "", state: .active)]
        let log = FakeAuditLog()
        log.devices = { FakeAuditLog.deviceEntries([("d-self", ""), ("d-other", ""), ("d-desk", "Desktop")]) }
        log.script([{ AuditPage(entries: [Self.entry(20, "message.sent", conn: "c1", device: "d-desk")], seq: 30) }])
        var m = await model(log)
        #expect(m.state.connectionName == "Ada Lovelace" && m.state.connectionExists)
        #expect(m.state.deviceName == "Desktop" && m.state.devicesKnown && !m.state.deviceUnnamed && !m.state.thisDevice)
        // This phone's own app, listed without a name.
        log.script([{ AuditPage(entries: [Self.entry(20, "owner_check.passed", device: "d-self")], seq: 30) }])
        m = await model(log)
        #expect(m.state.deviceName == nil && m.state.deviceUnnamed && m.state.thisDevice)
        // Another listed device without a name; a removed one; a connection whose names have not arrived; a gone one.
        log.script([{ AuditPage(entries: [Self.entry(20, "vault.unlocked", conn: "c2", device: "d-other")], seq: 30) }])
        m = await model(log)
        #expect(m.state.deviceUnnamed && !m.state.thisDevice && m.state.connectionName == nil && m.state.connectionExists)
        log.script([{ AuditPage(entries: [Self.entry(20, "vault.locked", conn: "c9", device: "d-gone")], seq: 30) }])
        m = await model(log)
        #expect(m.state.deviceName == nil && !m.state.deviceUnnamed && m.state.devicesKnown && !m.state.connectionExists)
        // Without the device list: nothing known of the device.
        log.devices = { throw VaultFailure(.network) }
        log.script([{ AuditPage(entries: [Self.entry(20, "vault.unlocked", device: "d-desk")], seq: 30) }])
        m = await model(log)
        #expect(!m.state.devicesKnown && m.state.deviceName == nil)
        // An item entry: its name while listed; not known before the app holds the Vault list.
        log.script([{ AuditPage(entries: [Self.entry(20, "item.revealed", "it1")], seq: 30) }])
        m = await model(log, itemNames: ["it1": "Passport"])
        #expect(m.state.itemName == "Passport" && m.state.itemExists && m.state.itemsKnown)
        log.script([{ AuditPage(entries: [Self.entry(20, "item.revealed", "it2")], seq: 30) }])
        m = await model(log, itemNames: ["it1": "Passport"])
        #expect(m.state.itemName == nil && !m.state.itemExists && m.state.itemsKnown)
        log.script([{ AuditPage(entries: [Self.entry(20, "item.revealed", "it1")], seq: 30) }])
        m = await model(log)
        #expect(m.state.itemName == nil && !m.state.itemsKnown)
    }

    /// The Vault list is read quietly when it has not been read; the entry's item follows it (named once the list is
    /// read, then deleted).
    @Test func theItemFollowsTheVaultList() async {
        let log = FakeAuditLog()
        log.script([{ AuditPage(entries: [Self.entry(20, "item.revealed", "it1")], seq: 30) }])
        let items = FakeItems()
        items.fail["refreshQuietly"] = VaultFailure(.network)
        items.add(FakeItems.item("it1", "Passport"))
        let m = HistoryEntryViewModel(seq: 20, history: HistoryManager(selfID: { "d-self" }) { log }, connections: connections, items: items)
        await m.settle()
        #expect(items.calls == ["refreshQuietly"] && !m.state.itemsKnown && m.state.itemName == nil)
        try? await items.refresh()
        #expect(m.state.itemName == "Passport" && m.state.itemExists && m.state.itemsKnown)
        try? await items.delete("it1", sensitivity: .data, password: nil)
        #expect(m.state.itemName == nil && !m.state.itemExists && m.state.itemsKnown)
    }
}

// swiftlint:enable line_length
