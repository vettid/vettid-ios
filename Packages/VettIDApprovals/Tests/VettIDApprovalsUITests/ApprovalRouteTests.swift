#if os(iOS)
import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData
import VettIDDataTesting

/// The decision screen's route: a tap acts on what the render it belongs to showed, never on what the model holds at the tap.
@MainActor
@Suite struct ApprovalRouteTests {
    let fake = FakeApprovals(connections: FakeConnections())
    let vault = FakeItems()
    static let key = "device:approval.pending:h1"

    init() {
        vault.add(FakeItems.item("i1", "GitHub", sensitivity: .secret, fields: [("Token", "x")]))
    }

    func held(_ fields: [String]?) -> PendingApproval {
        .device(DeviceRequest(
            type: "approval.pending", id: "h1", deviceName: "Bot", role: "agent", requestType: "agent.request",
            receivedAt: Date(timeIntervalSince1970: 1_791_115_200), exp: Date().addingTimeInterval(300), deviceID: "A",
            held: .itemGet(itemID: "i1", fieldIDs: fields)
        ))
    }

    @Test func approveSendsTheRequestTheRenderShowed() async throws {
        fake.listed = [held(["f1"])]
        let m = ApprovalDetailViewModel(key: Self.key, approvals: fake, connections: FakeConnections(), vault: vault)
        await m.settle()
        let rendered = ApprovalDetailRoute.actions(m, host: ApprovalsHost())
        // The request changes after that render (all fields now), and the tap comes from it.
        fake.listed = [held(nil)]
        rendered.onApprove()
        await m.settle()
        let sent = try #require(fake.lastDeviceApproval)
        #expect(sent.shown.held == .itemGet(itemID: "i1", fieldIDs: ["f1"]) && !sent.stillShown, "what was rendered, refused as changed")
        #expect(fake.calls == ["approveDeviceRequest:changed:\(Self.key)"] && m.state.error == .requestChanged)
        // A new render's tap sends the request as it shows it now.
        fake.calls = []
        ApprovalDetailRoute.actions(m, host: ApprovalsHost()).onApprove()
        await m.settle()
        #expect(fake.lastDeviceApproval?.shown.held == .itemGet(itemID: "i1", fieldIDs: nil))
        #expect(fake.calls == ["approveDeviceRequest:\(Self.key)"])
    }
}
#endif
