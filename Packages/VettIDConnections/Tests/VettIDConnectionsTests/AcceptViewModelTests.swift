import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDConnections

/// Accepting an invitation (VAULT-MESSAGING §6.4, 0.10.2–0.10.5): a pasted, scanned or opened link, the handshake, the
/// safety code, both approvals, a decline on either side, `exists`, and every refusal. Mirrors vettid-android
/// `ConnectionsViewModelsTest`'s accept and scan parts.
@MainActor
@Suite struct AcceptViewModelTests {
    let fake = FakeConnections()

    func model(input: String? = nil, opened: Bool = false) async -> AcceptViewModel {
        let m = AcceptViewModel(connections: fake, requests: fake, input: input, opened: opened)
        await m.settle()
        return m
    }

    func waiting() async -> AcceptViewModel {
        let m = await model(input: Samples.link())
        #expect(m.state.step == .waiting)
        return m
    }

    @Test func aPastedLinkIsSentOnlyWhenTheMemberConnects() async {
        let m = await model()
        #expect(m.state.step == .input && !m.state.fromLink)
        m.accept()
        #expect(!fake.calls.contains("acceptInvite"))
        let link = Samples.link()
        m.setInput("  \(link)\n")
        m.accept()
        #expect(m.state.step == .accepting)
        await m.settle()
        #expect(fake.lastText == "  \(link)\n")
        #expect(m.state.step == .waiting && m.state.connectionID == "conn-new" && m.state.name == "Inviter")
        #expect(fake.calls.contains("refreshRequests"))
    }

    @Test func aScannedCodeIsSentAtOnceAndAnOpenedLinkWaitsForTheMember() async {
        let link = Samples.link()
        let scanned = await model(input: link)
        #expect(fake.calls.filter { $0 == "acceptInvite" }.count == 1 && scanned.state.step == .waiting)
        let opened = await model(input: link, opened: true)
        #expect(opened.state.step == .input && opened.state.fromLink && opened.state.input == link)
        #expect(fake.calls.filter { $0 == "acceptInvite" }.count == 1)
        opened.accept()
        await opened.settle()
        #expect(fake.calls.filter { $0 == "acceptInvite" }.count == 2 && opened.state.step == .waiting)
    }

    /// One invitation is sent once: a second "Connect" while the first is under way, or after it, sends nothing.
    @Test func acceptingTwiceSendsOnce() async {
        let m = await model()
        m.setInput(Samples.link())
        m.accept()
        m.accept()
        await m.settle()
        m.accept()
        await m.settle()
        #expect(fake.calls.filter { $0 == "acceptInvite" }.count == 1 && m.state.step == .waiting)
    }

    @Test func refusalsAreSaidAndTheTextStays() async {
        let cases: [(String, FailureKind)] = [
            ("not a link", .inviteInvalid),
            (Samples.link(exp: Date().addingTimeInterval(-1)), .inviteExpired),
            (Samples.link(.desktop), .inviteNotConnection),
        ]
        for (text, kind) in cases {
            let m = await model()
            m.setInput(text)
            m.accept()
            await m.settle()
            #expect(m.state.step == .input && m.state.error == kind && m.state.input == text)
            m.setInput(text + " ")
            #expect(m.state.error == nil)
        }
    }

    @Test func theVaultsRefusalsAreSaid() async {
        // `blocked`, `claim_unavailable` (the claim was used, or is gone), a limit, the network.
        for kind in [FailureKind.blocked, .inviteUnavailable, .limit, .network, .connectionUnavailable] {
            fake.fail["acceptInvite"] = VaultFailure(kind)
            let m = await model(input: Samples.link())
            #expect(m.state.step == .input && m.state.error == kind)
        }
    }

    @Test func anExistingConnectionIsSaidAndNothingIsAsked() async {
        fake.acceptResult = AcceptedConnection(connectionID: "conn-1", exists: true)
        fake.connections = [Samples.active("conn-1", first: "Grace", last: "Hopper")]
        let m = await model(input: Samples.link())
        #expect(m.state.step == .exists && m.state.connectionID == "conn-1" && m.state.connectionName == "Grace Hopper")
        #expect(!fake.calls.contains("refreshRequests"))
    }

    @Test func theSafetyCodeComesWithTheHandshakeThenBothApprove() async {
        let m = await waiting()
        fake.requests = [Samples.outgoing(sas: nil, state: .waiting)]
        await m.settle()
        #expect(m.state.step == .waiting && m.state.sas == nil)
        fake.requests = [Samples.outgoing(remote: true)]
        await m.settle()
        #expect(m.state.step == .compare && m.state.sas == "042817" && m.state.remote)
        m.approve()
        await m.settle()
        #expect(fake.calls.contains("approveOutgoing") && m.state.step == .approved && !m.state.busy)
        // The request read again as pending (an older list) does not take the approval back.
        fake.requests = [Samples.outgoing(state: .pending)]
        await m.settle()
        #expect(m.state.step == .approved)
        fake.connections = [Samples.active("conn-new")]
        await m.settle()
        #expect(m.state.step == .connected && m.state.connectionName == "Ada Lovelace")
    }

    @Test func aCodeKnownBeforeTheAnswerIsShownAtOnce() async {
        fake.requests = [Samples.outgoing()]
        let m = await model(input: Samples.link())
        #expect(m.state.step == .compare && m.state.sas == "042817")
    }

    @Test func approvedElsewhereIsApproved() async {
        let m = await waiting()
        fake.requests = [Samples.outgoing(state: .approved)]
        await m.settle()
        #expect(m.state.step == .approved)
    }

    @Test func aFailedApprovalSaysWhy() async {
        let m = await waiting()
        fake.requests = [Samples.outgoing()]
        await m.settle()
        fake.fail["approveOutgoing"] = VaultFailure(.notFound)
        m.approve()
        await m.settle()
        #expect(m.state.step == .compare && m.state.error == .notFound && !m.state.busy)
    }

    @Test func declineEndsTheRequest() async {
        let m = await waiting()
        fake.requests = [Samples.outgoing()]
        await m.settle()
        fake.fail["declineOutgoing"] = VaultFailure(.network)
        m.decline()
        await m.settle()
        #expect(m.state.step == .compare && m.state.error == .network)
        m.decline()
        await m.settle()
        #expect(fake.calls.contains("declineOutgoing") && m.state.step == .ended && m.state.end == .declined)
    }

    @Test func aRequestThatEndsSaysHow() async {
        for end in [RequestEnd.expired, .failed, .declined, .gone] {
            let m = await waiting()
            fake.requests = []
            fake.requestEnds = ["conn-new": end]
            await m.settle()
            #expect(m.state.step == .ended && m.state.end == end)
            fake.requestEnds = [:]
        }
    }

    @Test func theInvitersDeclineIsToldOnce() async {
        let m = await waiting()
        fake.requests = [Samples.outgoing()]
        await m.settle()
        fake.peerDeclines = [PeerDecline(requestID: "conn-new", name: "Inviter", outgoing: true, at: Date())]
        fake.requests = []
        fake.requestEnds = ["conn-new": .peerDeclined]
        await m.settle()
        #expect(m.state.step == .ended && m.state.end == .peerDeclined)
        #expect(fake.calls.contains("dismissPeerDecline") && fake.peerDeclines.isEmpty)
    }

    @Test func theStateNeverPrintsTheLink() async {
        let link = Samples.link()
        let m = await model(input: link, opened: true)
        for text in [m.state.description, String(reflecting: m.state), "\(m.state)", "\(AcceptInput(link: link))"] {
            #expect(!text.contains(link))
        }
        #expect(Mirror(reflecting: m.state).children.isEmpty && Mirror(reflecting: AcceptInput(link: link)).children.isEmpty)
    }
}

/// The scanner checks what the camera read before anything is sent (§6.4). Mirrors vettid-android `ScanViewModel`'s tests.
@MainActor
@Suite struct ScanViewModelTests {
    @Test func onlyAConnectionInvitationOpensTheAcceptScreen() {
        let m = ScanViewModel()
        m.onScanned("hello")
        #expect(m.state.problem == .inviteInvalid && m.state.link == nil)
        m.onScanned(Samples.link(exp: Date().addingTimeInterval(-60)))
        #expect(m.state.problem == .inviteExpired)
        m.onScanned(Samples.link(.app))
        #expect(m.state.problem == .inviteNotConnection)
        let link = Samples.link()
        m.onScanned("https://relay.vettid.org/connect#\(link)")
        #expect(m.state.link == link && m.state.problem == nil)
        // Taken once: later reads are ignored until the accept screen took it over.
        m.onScanned("hello")
        #expect(m.state.link == link && m.state.problem == nil)
        #expect(!m.state.description.contains(link))
        m.consumed()
        #expect(m.state == ScanState())
    }

    @Test func theClockDecidesExpiry() {
        let exp = Date(timeIntervalSince1970: 1_791_115_800)
        let link = Samples.link(exp: exp)
        let before = ScanViewModel { exp.addingTimeInterval(-1) }
        before.onScanned(link)
        #expect(before.state.link == link)
        let after = ScanViewModel { exp }
        after.onScanned(link)
        #expect(after.state.problem == .inviteExpired)
    }
}
