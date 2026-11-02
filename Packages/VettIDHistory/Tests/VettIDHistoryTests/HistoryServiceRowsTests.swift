import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory

/// History's rows that name a service connection carry the label "Service" (VAULT-MESSAGING §6.4, IOS-PLAN §4.13); the
/// name is as always.
@MainActor
@Suite struct HistoryServiceRowsTests {
    @Test func aRowNamingAServiceIsLabelled() async {
        var s = HistoryState()
        s.connectionNames = ["c1": "Example Bank", "c2": "Ada Lovelace"]
        s.serviceIDs = ["c1"]
        let service = s.row(HistoryRowsTests.rec(1, "message.sent", conn: "c1"))
        #expect(service.service && service.supporting == "\u{2068}Example Bank\u{2069}")
        #expect(!s.row(HistoryRowsTests.rec(2, "message.sent", conn: "c2")).service)
        #expect(!s.row(HistoryRowsTests.rec(3, "vault.locked")).service)
    }

    /// The services come from the connections list, and follow it.
    @Test func theServicesFollowTheConnections() async {
        let connections = FakeConnections()
        var bank = ConnectionInfo(id: "c1", name: "", state: .active)
        bank.isService = true
        connections.connections = [bank, ConnectionInfo(id: "c2", name: "", state: .active)]
        let m = HistoryViewModel(history: HistoryManager { FakeAuditLog() }, connections: connections, debounce: .zero)
        await m.settle()
        #expect(m.state.serviceIDs == ["c1"])
        connections.connections = [ConnectionInfo(id: "c2", name: "", state: .active)]
        let deadline = Date().addingTimeInterval(20)
        while !m.state.serviceIDs.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(m.state.serviceIDs.isEmpty)
    }
}
