import Foundation
import Testing
import VettIDCrypto
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The History screen's loads end and show what they read: a connection's History, the full History, searches through
/// partial pages, paging, the list shown again, a list refused while the daily check was due, failures; the filters
/// sent; the names. Each test is the vault's answers through the real ``HistoryManager``. Mirrors vettid-android
/// `HistoryViewModelTest` and `HistoryReturnTest`.
@MainActor
@Suite struct HistoryViewModelTests {
    /// 2026-10-08T12:00:00Z.
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_791_460_800)
    let connections = FakeConnections()

    init() {
        // The connection whose names have not arrived ("Name not shared yet").
        connections.connections = [ConnectionInfo(id: "c1", name: "", state: .active)]
    }

    nonisolated static func entry(_ seq: Int64, _ kind: String = "message.sent", conn: String? = "c1", device: String? = nil) -> AuditEntry {
        AuditEntry(entryID: "e\(seq)", seq: seq, at: Timestamps.formatMillis(t0.addingTimeInterval(-60 * Double(1000 - seq))), kind: kind, connectionID: conn, deviceID: device)
    }

    nonisolated static func page(_ seqs: [Int64], next: Int64? = nil, partial: Bool = false, kind: String = "message.sent") -> @Sendable () throws -> AuditPage {
        { AuditPage(entries: seqs.map { entry($0, kind) }, seq: 1000, nextBeforeSeq: next, partial: partial) }
    }

    func model(_ log: FakeAuditLog, connectionID: String? = "c1", owner: FakeVaultRepository? = nil) async -> HistoryViewModel {
        let m = HistoryViewModel(history: HistoryManager { log }, connections: connections, ownerChecks: owner, connectionID: connectionID, debounce: .zero)
        await m.settle()
        return m
    }

    @Test func aConnectionsHistoryShowsItsEntriesAndStopsLoading() async {
        let log = FakeAuditLog()
        log.script([Self.page([900, 700, 650])])
        let m = await model(log)
        #expect(log.calls.count == 1 && log.calls[0].connectionID == "c1" && log.calls[0].q == nil)
        #expect(m.state.entries.map(\.seq) == [900, 700, 650] && m.state.end && !m.state.loading && m.state.error == nil)
        #expect(m.state.connectionNames == ["c1": "Name not shared yet"] && m.state.filter.connectionID == "c1")
        #expect(connections.calls.contains("refresh"))
    }

    @Test func aConnectionWithoutEntriesEndsEmptyNotSpinning() async {
        let log = FakeAuditLog()
        log.script([Self.page([])])
        let m = await model(log)
        #expect(m.state.entries.isEmpty && m.state.end && !m.state.loading && !m.state.emptyHistory)
    }

    @Test func theFullHistoryLoadsToo() async {
        let log = FakeAuditLog()
        log.script([{ AuditPage(entries: [Self.entry(5, "vault.unlocked", conn: nil)], seq: 5) }])
        let m = await model(log, connectionID: nil)
        #expect(log.calls.first?.connectionID == nil && m.state.entries.map(\.seq) == [5] && m.state.end)
    }

    @Test func aSearchOfAConnectionThroughPartialPagesEnds() async {
        let log = FakeAuditLog()
        // q "unlock": the budget runs out twice (§10.9 partial), then the last page.
        log.script([Self.page([900, 800]), Self.page([], next: 500, partial: true), Self.page([450], next: 200, partial: true, kind: "vault.unlocked"), Self.page([])])
        let m = await model(log)
        m.setQuery("unlock")
        await m.settle()
        #expect(log.calls.map(\.q) == [nil, "unlock", "unlock", "unlock"])
        #expect(log.calls.map(\.beforeSeq) == [nil, nil, 500, 200])
        #expect(m.state.entries.map(\.seq) == [450] && m.state.end && !m.state.partial && !m.state.localSearch && !m.state.loading)
    }

    @Test func aSearchWithNoMatchEndsAndShowsNoMatch() async {
        let log = FakeAuditLog()
        log.script([Self.page([900]), Self.page([])])
        let m = await model(log)
        m.setQuery("zzz")
        await m.settle()
        #expect(log.calls.count == 2 && m.state.entries.isEmpty && m.state.end && !m.state.emptyHistory)
        // Only a change of what is sent restarts the list.
        m.setQuery("zzz  ")
        await m.settle()
        #expect(log.calls.count == 2 && m.state.filter.query == "zzz  ")
    }

    @Test func moreEntriesLoadAndLoadingMoreClears() async {
        let log = FakeAuditLog()
        log.script([Self.page(Array((950...999).reversed()), next: 950), Self.page([949, 948])])
        let m = await model(log)
        #expect(m.state.entries.count == 50 && !m.state.end)
        m.loadMore()
        #expect(m.state.loadingMore)
        await m.settle()
        #expect(m.state.entries.count == 52 && m.state.end && !m.state.loadingMore && log.calls.last?.beforeSeq == 950)
        // Nothing more once at the end.
        m.loadMore()
        await m.settle()
        #expect(log.calls.count == 2)
    }

    /// The list shown again (from the drawer, back from an entry, or the export closed) reads the newest page and puts
    /// what arrived on top: after an export, "History exported" is first.
    @Test func shownAgainHistoryReadsTheNewestPageAndPutsNewEntriesOnTop() async {
        let log = FakeAuditLog()
        log.script([
            { AuditPage(entries: [Self.entry(5, "vault.unlocked", conn: nil), Self.entry(4, "vault.unlocked", conn: nil)], seq: 5) },
            { AuditPage(entries: [Self.entry(6, "audit.exported", conn: nil), Self.entry(5, "vault.unlocked", conn: nil)], seq: 6, nextBeforeSeq: 5) },
        ])
        let m = HistoryViewModel(history: HistoryManager { log }, connections: connections, debounce: .zero)
        // The screen's first refresh while the first page loads is that load.
        m.refresh()
        await m.settle()
        #expect(log.calls.count == 1)
        m.refresh()
        await m.settle()
        #expect(log.calls.last?.beforeSeq == nil && m.state.entries.map(\.seq) == [6, 5, 4] && m.state.entries.first?.kind == "audit.exported" && m.state.end)
    }

    /// The same with the real log: the two new entries on top of the first page read; older ones still load on scrolling.
    @Test func theNewestEntryIsOnTopAfterAnExportAndAfterComingBack() async {
        let log = FakeAuditLog(FakeAuditLog.chain(56, newest: Self.t0))
        let m = await model(log, connectionID: nil)
        #expect(m.state.entries.first?.seq == 56)
        log.append("audit.exported")
        m.refresh()
        await m.settle()
        #expect(m.state.entries.first?.seq == 57)
        log.append("vault.unlocked")
        m.refresh()
        await m.settle()
        #expect(m.state.entries.map(\.seq) == [58, 57] + Array((7...56).reversed()) && !m.state.chainBroken)
    }

    /// Refused because the daily check was due: History reads again once the check passes; another failure stays.
    @Test func aListRefusedForTheDailyCheckReloadsWhenTheCheckPasses() async {
        let owner = FakeVaultRepository(.unlocked)
        owner.ownerCheck = OwnerCheckView(state: .due, deadline: nil, hold: true)
        let log = FakeAuditLog()
        log.script([{ throw VaultFailure(.ownerCheckRequired, code: "owner_check_required") }, Self.page([900])])
        let m = await model(log, owner: owner)
        #expect(m.state.error == .ownerCheckRequired && !m.state.loading)
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: true)
        await m.settle()
        #expect(m.state.error == nil && m.state.entries.map(\.seq) == [900] && log.calls.count == 2)
    }

    @Test func aFailureIsShownNotSpunOnAndRetried() async {
        let log = FakeAuditLog()
        log.script([{ throw VaultFailure(.vaultCode("internal"), code: "internal") }, Self.page([3])])
        let m = await model(log)
        #expect(m.state.entries.isEmpty && m.state.error == .vaultCode("internal") && !m.state.loading)
        m.retry()
        await m.settle()
        #expect(m.state.error == nil && m.state.entries.map(\.seq) == [3])
    }

    @Test func theFiltersAreSentAndClearedAtOnce() async {
        let log = FakeAuditLog(FakeAuditLog.chain(30, kinds: ["vault.unlocked", "device.paired"], newest: Self.t0, connection: "c1"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let m = HistoryViewModel(history: HistoryManager { log }, connections: connections, debounce: .zero, now: { Self.t0 }, calendar: cal)
        await m.settle()
        m.setCategory(.devices)
        await m.settle()
        #expect(log.calls.last?.kinds == ["device", "approval"] && m.state.entries.allSatisfy { $0.kind == "device.paired" })
        m.setCategory(.devices)
        await m.settle()
        #expect(log.calls.last?.kinds == nil && m.state.filter.category == nil)
        m.setConnection("c1")
        await m.settle()
        #expect(log.calls.last?.connectionID == "c1")
        m.setDates(.week)
        await m.settle()
        #expect(m.state.datePreset == .week && log.calls.last?.since == "2026-10-02T00:00:00.000Z" && log.calls.last?.until == nil)
        let n = log.calls.count
        m.setConnection("c1")
        await m.settle()
        #expect(log.calls.count == n)
        m.clearFilters()
        await m.settle()
        #expect(m.state.filter.isEmpty && m.state.datePreset == .any && log.calls.last == FakeAuditLog.Call(connectionID: nil, kinds: nil, beforeSeq: nil, limit: 50, q: nil, since: nil, until: nil))
    }

    /// A vault that does not search: this phone searches what it loads, the connection's names among it.
    @Test func withoutTheVaultsSearchThePhoneSearchesTheNamesItHolds() async {
        var ada = ConnectionInfo(id: "c1", name: "Ace", state: .active)
        ada.firstName = "Ada"
        ada.lastName = "Lovelace"
        connections.connections = [ada]
        let log = FakeAuditLog(FakeAuditLog.chain(20, kinds: ["vault.unlocked", "message.sent"], newest: Self.t0, connection: "c1"), mode: .refuses)
        let m = await model(log, connectionID: nil)
        m.setQuery("lovelace")
        await m.settle()
        #expect(m.state.localSearch && !m.state.entries.isEmpty && m.state.entries.allSatisfy { $0.entry.connectionID == "c1" })
        m.setQuery("Message sent")
        await m.settle()
        #expect(m.state.entries.count == 10 && m.state.entries.allSatisfy { $0.kind == "message.sent" })
    }

    @Test func theDevicesAreReadOnceAndAgainWhenShownAgain() async {
        let log = FakeAuditLog(FakeAuditLog.chain(3, newest: Self.t0))
        log.devices = { FakeAuditLog.deviceEntries([("d1", ""), ("d2", "Laptop")]) }
        let m = await model(log, connectionID: nil)
        #expect(m.state.devices?.device("d2") == .named("Laptop") && m.state.devices?.device("d9") == .removed)
        log.devices = { FakeAuditLog.deviceEntries([("d1", "")]) }
        m.refresh()
        await m.settle()
        #expect(m.state.devices?.device("d2") == .removed)
    }

    /// What the state prints holds counts only.
    @Test func theStateNamesNothing() async {
        let log = FakeAuditLog()
        log.script([Self.page([1])])
        let m = await model(log)
        #expect(!"\(m.state)".contains("Name not shared") && !String(reflecting: m.state).contains("message.sent"))
    }
}

// swiftlint:enable line_length
