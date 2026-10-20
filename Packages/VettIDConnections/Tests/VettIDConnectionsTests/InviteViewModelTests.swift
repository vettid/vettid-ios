import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDConnections

/// Inviting a connection (VAULT-MESSAGING §6.4, §10.4): the lifetimes, the invitation and its expiry, the request with its
/// safety code, both approvals, a decline, a block, the other member's decline, and every failure. Mirrors
/// vettid-android `ConnectionsViewModelsTest`'s invite part.
@MainActor
@Suite struct InviteViewModelTests {
    let fake = FakeConnections()

    func model(now: @escaping @Sendable () -> Date = { Date() }) async -> InviteViewModel {
        let m = InviteViewModel(connections: fake, requests: fake, now: now)
        await m.settle()
        return m
    }

    func showing() async -> InviteViewModel {
        let m = await model()
        m.create()
        await m.settle()
        return m
    }

    @Test func theLifetimesAreTheRelaysAndTenMinutesComeFirst() async {
        fake.ttls = [.tenMinutes, .oneHour]
        let m = await model()
        #expect(m.state.step == .choose && m.state.ttl == .tenMinutes)
        #expect(m.state.ttls == [.tenMinutes, .oneHour])
        m.setTtl(.oneHour)
        #expect(m.state.ttl == .oneHour && m.state.ttl.remote)
    }

    @Test func withoutTheRelaysLimitsTenMinutesAreOffered() async {
        fake.fail["inviteTtls"] = VaultFailure(.network)
        let m = await model()
        #expect(m.state.ttls == [.tenMinutes])
    }

    @Test func anInvitationShowsItsCodeUntilItExpires() async {
        let m = await showing()
        #expect(fake.calls.contains("createInvite"))
        #expect(m.state.step == .showing && m.state.invite?.inviteID == Samples.inviteID && m.state.invite?.remote == false)
        let exp = fake.invite.exp
        m.tick(exp.addingTimeInterval(-1))
        #expect(m.state.step == .showing)
        m.tick(exp)
        #expect(m.state.step == .expired)
        // "New invitation": from the start, the lifetimes and the choice kept.
        m.again()
        #expect(m.state.step == .choose && m.state.invite == nil && m.state.ttls == InviteTtl.allCases)
    }

    @Test func aRemoteInvitationIsALink() async {
        let m = await model()
        m.setTtl(.sevenDays)
        m.create()
        await m.settle()
        #expect(m.state.invite?.remote == true)
    }

    @Test func aFailedCreationSaysWhyAndStays() async {
        for kind in [FailureKind.network, .limit, .rateLimited] {
            fake.fail["createInvite"] = VaultFailure(kind)
            let m = await model()
            m.create()
            #expect(m.state.busy)
            await m.settle()
            #expect(m.state.step == .choose && !m.state.busy && m.state.error == kind)
        }
    }

    @Test func theRequestForThisInvitationBringsTheSafetyCode() async {
        let m = await showing()
        fake.requests = [Samples.incoming("other", invite: "another-invite")]
        await m.settle()
        #expect(m.state.step == .showing)
        fake.requests = [Samples.incoming()]
        await m.settle()
        #expect(m.state.step == .request && m.state.request?.sas == "042817" && !m.state.autoApproved)
        #expect(m.state.request?.name == "Ada Lovelace")
    }

    @Test func anInPersonRequestApprovedByTheVaultStillShowsTheCode() async {
        let m = await showing()
        fake.requests = [Samples.incoming(state: .approved)]
        await m.settle()
        #expect(m.state.step == .connecting && m.state.autoApproved && m.state.request?.sas == "042817")
    }

    @Test func bothApprovalsMakeTheConnection() async {
        fake.connections = [Samples.active("old")]
        let m = await showing()
        fake.requests = [Samples.incoming()]
        await m.settle()
        m.approve()
        await m.settle()
        #expect(fake.calls.contains("approveConnection"))
        #expect(m.state.step == .connecting && !m.state.busy)
        // An existing connection changing is not this one.
        fake.connections = [Samples.active("old", first: "Grace")]
        await m.settle()
        #expect(m.state.step == .connecting)
        fake.connections = [Samples.active("old"), Samples.active("conn-1")]
        await m.settle()
        #expect(m.state.step == .connected && m.state.connectionID == "conn-1" && m.state.connectionName == "Ada Lovelace")
    }

    @Test func aConnectionWithoutNamesYetHasNoName() async {
        let m = await showing()
        fake.requests = [Samples.incoming()]
        await m.settle()
        fake.connections = [Samples.active("conn-1", first: nil, last: nil)]
        await m.settle()
        #expect(m.state.step == .connected && m.state.connectionName == nil)
    }

    @Test func aFailedApprovalSaysWhyAndKeepsTheCode() async {
        let m = await showing()
        fake.requests = [Samples.incoming()]
        await m.settle()
        fake.fail["approveConnection"] = VaultFailure(.notFound)
        m.approve()
        await m.settle()
        #expect(m.state.step == .request && m.state.error == .notFound && !m.state.busy)
    }

    @Test func declineEndsTheFlow() async {
        let m = await showing()
        fake.requests = [Samples.incoming()]
        await m.settle()
        m.decline()
        await m.settle()
        #expect(fake.calls.contains("declineConnection"))
        #expect(m.state.step == .choose && m.state.request == nil)
    }

    @Test func blockIsConfirmedFirst() async {
        let m = await showing()
        fake.requests = [Samples.incoming()]
        await m.settle()
        m.askBlock(true)
        #expect(m.state.confirmBlock)
        m.askBlock(false)
        #expect(!m.state.confirmBlock && !fake.calls.contains("blockConnectionRequest"))
        m.askBlock(true)
        m.block()
        #expect(!m.state.confirmBlock)
        await m.settle()
        #expect(fake.calls.contains("blockConnectionRequest") && m.state.step == .choose)
    }

    @Test func aFailedDecisionSaysWhy() async {
        let m = await showing()
        fake.requests = [Samples.incoming()]
        await m.settle()
        fake.fail["declineConnection"] = VaultFailure(.network)
        m.decline()
        await m.settle()
        #expect(m.state.step == .request && m.state.error == .network)
        fake.fail["blockConnectionRequest"] = VaultFailure(.limit)
        m.block()
        await m.settle()
        #expect(m.state.step == .request && m.state.error == .limit)
    }

    @Test func cancellingTheInvitationGoesBackToTheStart() async {
        let m = await showing()
        fake.fail["cancelInvite"] = VaultFailure(.network)
        m.cancelInvite()
        await m.settle()
        #expect(m.state.step == .showing && m.state.error == .network)
        m.cancelInvite()
        await m.settle()
        #expect(m.state.step == .choose && m.state.invite == nil && m.state.error == nil)
    }

    @Test func theOtherMembersDeclineIsToldOnce() async {
        let m = await showing()
        fake.requests = [Samples.incoming()]
        await m.settle()
        m.approve()
        await m.settle()
        fake.requests = []
        fake.peerDeclines = [
            PeerDecline(requestID: "pend-1", name: "Ada L.", outgoing: true, at: Date()),
        ]
        await m.settle()
        // An outgoing decline is another request's.
        #expect(m.state.step == .connecting)
        fake.peerDeclines = [PeerDecline(requestID: "pend-1", name: nil, outgoing: false, at: Date())]
        await m.settle()
        #expect(m.state.step == .declined && m.state.declinedName == "Ada Lovelace")
        #expect(fake.calls.contains("dismissPeerDecline") && fake.peerDeclines.isEmpty)
    }

    @Test func theStateNeverPrintsTheInvitation() async {
        let m = await showing()
        for text in [m.state.description, String(reflecting: m.state), "\(m.state)"] {
            #expect(!text.contains(fake.invite.link) && !text.contains(Samples.inviteID))
        }
        #expect(Mirror(reflecting: m.state).children.isEmpty)
    }
}
