import Foundation
import Testing
import VettIDCrypto
import VettIDData
import VettIDDataTesting
@testable import VettIDHistory
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// A withdrawn request in History (VAULT-MESSAGING 0.80.0 §10.4, §10.9 `connection.authenticate.withdrawn`; ANDROID-PLAN
/// 0.1.101): "Request withdrawn" in the connections' category, the detail naming the connection, never a decline, and the
/// existing mute offered (on a service, confirmed first).
@MainActor
@Suite struct WithdrawnEntryTests {
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_792_411_200)
    let connections = FakeConnections()

    nonisolated static func entry(conn: String? = "c1") -> AuditEntry {
        AuditEntry(entryID: "e7", seq: 7, at: Timestamps.formatMillis(t0), kind: "connection.authenticate.withdrawn", connectionID: conn, deviceID: nil, ref: "01JREQ")
    }

    func model() async -> HistoryEntryViewModel {
        let log = FakeAuditLog()
        log.script([{ AuditPage(entries: [Self.entry()], seq: 7) }])
        let m = HistoryEntryViewModel(seq: 7, history: HistoryManager(selfID: { "d-self" }) { log }, connections: connections)
        await m.settle()
        return m
    }

    func connection(_ id: String, service: Bool = false) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: .active)
        c.firstName = "Sam"
        c.lastName = "Lee"
        c.isService = service
        return c
    }

    @Test func theEntrySaysRequestWithdrawn() {
        let sam = AccountNames.isolate("Sam Lee")
        #expect(HistoryText.title("connection.authenticate.withdrawn") == "Request withdrawn")
        #expect(AuditCategory.of("connection.authenticate.withdrawn") == .connections)
        #expect(HistoryText.details("connection.authenticate.withdrawn", "01JREQ", outcome: .unknown, names: EntryNames(connection: "Sam Lee")) == ["\(sam) withdrew this request before it was answered."])
        #expect(HistoryText.details("connection.authenticate.withdrawn", "01JREQ", outcome: .unknown).isEmpty, "no name, no line")
        for text in [HistoryText.title("connection.authenticate.withdrawn"), HistoryKindTexts.text("history_authn_withdrawn_detail", "Sam")] {
            #expect(!text.lowercased().contains("declin") && !text.lowercased().contains("denied"))
        }
        #expect(HistoryStrings.withdrawnMute(sam) == "Mute requests from \(sam)")
        #expect(HistoryStrings.withdrawnMuteConfirmService(sam) == "You won't be asked to sign in or approve anything for \(sam) until you unmute.")
        #expect(HistoryStrings.withdrawnMuteConfirm == "Mute" && HistoryStrings.withdrawnMuteCancel == "Cancel")
    }

    @Test func aPersonsAsksAreMutedAtOnce() async {
        connections.connections = [connection("c1")]
        let m = await model()
        #expect(m.state.offersMute && !m.state.connectionIsService)
        #expect(m.state.fields().contains { $0.value == "\(AccountNames.isolate("Sam Lee")) withdrew this request before it was answered." })
        m.askMute(true)
        await m.settle()
        #expect(connections.calls.contains("asksMute:c1:true") && m.state.asksMuted && !m.state.offersMute)
    }

    @Test func aServicesMuteIsConfirmedFirst() async {
        connections.connections = [connection("c1", service: true)]
        let m = await model()
        m.askMute(true)
        #expect(m.state.confirmMute && !connections.calls.contains { $0.hasPrefix("asksMute") })
        m.askMute(false)
        #expect(!m.state.confirmMute)
        m.askMute(true)
        m.mute()
        await m.settle()
        #expect(connections.calls.contains("asksMute:c1:true") && m.state.asksMuted)
    }

    /// No mute once the asks are muted, or once the connection is gone.
    @Test func theMuteIsOfferedOnlyWhileItCanApply() async {
        var muted = connection("c1")
        muted.asks = AskState(muted: true)
        connections.connections = [muted]
        #expect(await !model().state.offersMute)
        connections.connections = []
        #expect(await !model().state.offersMute)
    }
}

// swiftlint:enable line_length
