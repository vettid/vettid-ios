import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData
import VettIDDataTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.145 and 0.1.146: a desktop's held block or removal is approved only as the screen showed its connection.
extension HeldRequestsViewModelTests {
    static func desktop(_ h: HeldApproval) -> PendingApproval {
        .device(DeviceRequest(type: "approval.pending", id: "h1", deviceName: "Work desktop", role: "desktop", requestType: "block.add", receivedAt: Samples.t0, exp: Date().addingTimeInterval(300), deviceID: "D", held: h))
    }

    func ana(_ id: String = "c1", last: String = "Lee", at: Date? = nil) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: .active)
        (c.firstName, c.lastName, c.createdAt) = ("Ana", last, at)
        return c
    }

    static let block = HeldApproval.desktopConnection(DesktopConnection(remove: false, connectionID: "c1", note: "spam"))

    @Test func aDesktopsBlockIsNamedFromTheConnectionList() async {
        connections.connections = [ana()]
        fake.listed = [Self.desktop(Self.block)]
        let m = await model()
        #expect(m.state.heldShow == .desktopConnection(remove: false, target: DesktopTargets.Shown(name: "Ana Lee", service: false), note: "spam") && m.state.canApprove())
        connections.connections = []
        #expect(m.state.heldShow == .desktop && !m.state.canApprove(), "gone from the list: deny only")
    }

    /// The connection renamed, or a namesake added, between the render and the tap: nothing is approved.
    @Test func aConnectionRenamedOrANamesakeAddedSinceTheRenderIsNotApproved() async throws {
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        for change in ["renamed", "namesake"] {
            fake.calls = []
            connections.connections = [ana(at: day)]
            fake.listed = [Self.desktop(Self.block)]
            let m = await model()
            let rendered = try #require(m.shownHeld())
            connections.connections = change == "renamed" ? [ana(last: "Lee-Park", at: day)] : [ana(at: day), ana("c2", at: day.addingTimeInterval(-86_400 * 30))]
            m.approve(held: rendered)
            await m.settle()
            #expect(fake.calls == ["approveDeviceRequest:changed:\(Self.key)"] && m.state.error == .requestChanged, Comment(rawValue: change))
        }
        connections.connections = [ana()]
        let m = await model()
        fake.calls = []
        m.approve(held: m.shownHeld())
        await m.settle()
        #expect(fake.calls == ["approveDeviceRequest:\(Self.key)"] && m.state.outcome == .approved(result: "ok"))
    }
}
// swiftlint:enable line_length
