import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory

/// History's rows that name a service connection carry the label "Service" on the line that names it (VAULT-MESSAGING
/// §6.4, IOS-PLAN §4.13): the title when the title names the connection, else the second line, which does.
@MainActor
@Suite struct HistoryServiceRowsTests {
    func state() -> HistoryState {
        var s = HistoryState()
        s.connectionNames = ["c1": "Example Bank", "c2": "Ada Lovelace"]
        s.serviceIDs = ["c1"]
        return s
    }

    /// "Message sent" with the name under it: the label goes on the second line.
    @Test func aSecondLineNamingAServiceIsLabelled() {
        let row = state().row(HistoryRowsTests.rec(1, "message.sent", conn: "c1"))
        #expect(!row.title.contains("Example Bank") && row.supporting == "\u{2068}Example Bank\u{2069}")
        #expect(row.supportingNamesService && !row.titleNamesService)
    }

    /// A title that names the connection carries the label itself.
    @Test func aTitleNamingAServiceIsLabelled() {
        let row = state().row(HistoryRowsTests.rec(2, "identity.rotate_conflict", conn: "c1"))
        #expect(row.title.contains("Example Bank"))
        #expect(row.titleNamesService && !row.supportingNamesService)
    }

    @Test func aPersonsOrNoConnectionsRowIsNot() {
        let person = state().row(HistoryRowsTests.rec(3, "message.sent", conn: "c2"))
        #expect(!person.titleNamesService && !person.supportingNamesService)
        let none = state().row(HistoryRowsTests.rec(4, "vault.locked"))
        #expect(!none.titleNamesService && !none.supportingNamesService)
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
