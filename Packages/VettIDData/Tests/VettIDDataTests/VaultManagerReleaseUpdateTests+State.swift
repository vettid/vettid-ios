import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// Rule 3 (#r60): the one older-release case the app must handle is the upgrade step itself. A vault on the previous
/// release that moves to the current one through "Approve and update" keeps its state.
extension VaultManagerReleaseUpdateTests {
    /// Previous → current through "Approve and update": the same connection, item and conversation are there afterwards,
    /// on the same device and the same vault, with no enrollment.
    @Test func theUpgradeStepKeepsTheVaultsState() async throws {
        defer { phone.close() }
        try await setUp()
        let c = m.connections
        let r = try await c.acceptInvite(try service.peerInvite(first: "Morgan", last: "Lee", name: "Mo"))
        #expect(await eventually { c.requests.first?.sas != nil })
        try service.peerApproves(r.connectionID)
        try await c.approveOutgoing(r.connectionID)
        #expect(await eventually { c.connections.map(\.id) == [r.connectionID] })
        let sent = try await m.messages.send(r.connectionID, text: "Before the update")
        let item = try await m.items.create(ItemDraft(
            name: "Passport", category: "identity_document", fields: [DraftField(label: "Number", kind: "text", text: "X123")]
        ))
        let device = try #require(m.session?.device)
        let (vaultID, userGuid) = (m.record.value.vaultID, m.record.value.userGuid)

        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        await m.listsRead?.value
        let before = service.requestsSeen.count
        #expect(m.releaseUpdate.start(pin: pin, offer: offer))
        await m.releaseUpdate.settle()
        #expect(try #require(m.releaseUpdate.progress).step == .done)
        m.releaseUpdate.finish()
        #expect(service.routedRelease == 4)

        // The same phone and vault, open: no enrollment, no setup.
        #expect(m.phase == .unlocked)
        #expect(m.session?.device === device)
        #expect(m.record.value.vaultID == vaultID && m.record.value.userGuid == userGuid && !userGuid.isEmpty)
        // The lists are read again from the vault on the new release (not only kept in memory), and hold what was there
        // before; nothing was enrolled again.
        for list in ["connection.list", "item.list", "message.list"] {
            #expect(await eventually { service.requestsSeen.dropFirst(before).contains(list) }, "\(list) read again")
        }
        #expect(!service.requestsSeen.dropFirst(before).contains { $0.contains("enroll") }, "no enrollment")
        #expect(await eventually { c.connections.map(\.id) == [r.connectionID] })
        #expect(await eventually { m.items.items.map(\.id) == [item] })
        #expect(await eventually { m.messages.messages(r.connectionID).map(\.messageID) == [sent.messageID] })
        #expect(m.messages.conversations.map(\.id) == [r.connectionID])
    }
}
