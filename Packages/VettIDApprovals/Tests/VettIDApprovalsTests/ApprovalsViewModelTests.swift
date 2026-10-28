import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData
import VettIDDataTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Approvals list (ANDROID-PLAN §4 Approvals; VAULT-MESSAGING §10.4.1): loading, empty and failed reads, the
/// connection requests listed with the other approvals, a connection's asks batched, paused connections resumed or
/// removed, the other member's declines, and the re-read after a passed daily check. Mirrors vettid-android
/// `ApprovalsViewModelsTest`'s list part.
@MainActor
@Suite struct ApprovalsViewModelTests {
    let connections = FakeConnections()
    let fake: FakeApprovals

    init() { fake = FakeApprovals(connections: connections) }

    func model(ownerChecks: (any OwnerCheckRepository)? = nil) async -> ApprovalsViewModel {
        let m = ApprovalsViewModel(approvals: fake, connections: connections, ownerChecks: ownerChecks)
        await m.settle()
        return m
    }

    @Test func aReadLoadsThenListsEverythingNewestFirst() async {
        connections.requests = [Samples.incoming(at: Samples.t0.addingTimeInterval(60))]
        fake.listed = [Samples.share(), Samples.device()]
        let m = ApprovalsViewModel(approvals: fake, connections: connections)
        #expect(m.state.loading)
        await m.settle()
        #expect(!m.state.loading && m.state.error == nil && fake.calls == ["refreshApprovals:"])
        #expect(m.state.approvals.first?.key == "connection:p1" && m.state.approvals.count == 3 && !m.state.nothing)
    }

    @Test func nothingWaitingIsTheEmptyState() async {
        let m = await model()
        #expect(m.state.nothing && !m.state.loading && m.state.error == nil && m.state.entries.isEmpty)
    }

    @Test func aFailedReadSaysWhyAndTriesAgain() async {
        fake.fail["refreshApprovals"] = VaultFailure(.network)
        let m = await model()
        #expect(m.state.error == .network && m.state.nothing && !m.state.loading)
        m.refresh()
        #expect(m.state.error == nil)
        await m.settle()
        #expect(m.state.error == nil && fake.calls.count == 2)
    }

    /// §10.4.1: a connection's asks within 10 minutes of the first are one entry; later ones start a new batch; a single
    /// ask, a share question and a connection request stay rows of their own.
    @Test func aConnectionsAsksAreBatched() async {
        let t = Samples.t0
        fake.listed = [
            Samples.auth("a1", at: t), Samples.grant("g1", at: t.addingTimeInterval(120)), Samples.critical("k1", at: t.addingTimeInterval(540)),
            Samples.grant("g2", at: t.addingTimeInterval(700)), Samples.auth("a2", conn: "c2", at: t.addingTimeInterval(30)), Samples.share(),
        ]
        connections.requests = [Samples.incoming(at: t.addingTimeInterval(800))]
        let m = await model()
        let e = m.state.entries
        #expect(e.map(\.key) == ["connection:p1", "grant:g2", "batch:auth:a1", "auth:a2", "share:r1"])
        guard case .batch(let conn, let asks) = e[2] else { Issue.record("no batch"); return }
        #expect(conn == "c1" && asks.map(\.key) == ["auth:a1", "grant:g1", "critical:k1"])
        #expect(e[2].receivedAt == t.addingTimeInterval(540))
        // Exactly 10 minutes after the first starts a new batch.
        let edge = AskBatches.group([Samples.auth("x", at: t), Samples.auth("y", at: t.addingTimeInterval(600))])
        #expect(edge.map(\.key) == ["auth:y", "auth:x"])
    }

    @Test func namesComeFromTheConnections() async {
        connections.connections = [Samples.connection("c1"), Samples.connection("c2", first: nil)]
        let m = await model()
        #expect(m.state.connectionName("c1") == "Sam Lee" && m.state.connectionName("c2") == nil && m.state.connectionName(nil) == nil)
    }

    /// 0.23.0 §10.4.1: a paused connection is listed with "Resume requests" and "Remove connection" (confirmed).
    @Test func aPausedConnectionIsResumedOrRemoved() async {
        connections.connections = [Samples.connection("c1", paused: true), Samples.connection("c2")]
        let m = await model()
        #expect(m.state.paused.map(\.id) == ["c1"] && !m.state.nothing)
        m.resumeAsks("c1")
        #expect(m.state.busy)
        await m.settle()
        #expect(!m.state.busy && connections.calls.contains("asksResume:c1") && m.state.paused.isEmpty)
        connections.connections[0].asks = AskState(paused: true)
        m.askRemove(m.state.paused[0])
        #expect(m.state.confirmRemove?.id == "c1")
        m.askRemove(nil)
        m.remove()
        await m.settle()
        #expect(!connections.calls.contains("remove"))
        m.askRemove(m.state.paused[0])
        m.remove()
        await m.settle()
        #expect(connections.calls.contains("remove") && m.state.confirmRemove == nil && m.state.paused.isEmpty)
    }

    @Test func aFailedResumeSaysWhy() async {
        connections.connections = [Samples.connection("c1", paused: true)]
        connections.fail["asksResume:c1"] = VaultFailure(.network)
        let m = await model()
        m.resumeAsks("c1")
        await m.settle()
        #expect(m.state.error == .network && !m.state.busy && m.state.paused.count == 1)
    }

    @Test func aPeersDeclineShowsUntilDismissed() async {
        connections.peerDeclines = [PeerDecline(requestID: "r1", name: "Ada", outgoing: true, at: Date())]
        let m = await model()
        #expect(m.state.peerDeclines.count == 1 && !m.state.nothing)
        m.dismissPeerDecline("r1")
        #expect(m.state.peerDeclines.isEmpty && connections.calls.contains("dismissPeerDecline"))
    }

    /// A list refused because the daily check was due reads again by itself once a check passes; another failure stays.
    @Test func aPassedCheckReadsARefusedListAgain() async {
        let vault = FakeVaultRepository(.unlocked)
        vault.ownerCheck = OwnerCheckView(state: .due, deadline: nil, hold: false)
        fake.fail["refreshApprovals"] = VaultFailure(.ownerCheckRequired)
        let m = await model(ownerChecks: vault)
        #expect(m.state.error == .ownerCheckRequired)
        vault.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: false)
        // The view model follows the check on a later turn of the main actor.
        for _ in 0..<2000 where !(m.state.error == nil && fake.calls.count == 2) { try? await Task.sleep(for: .milliseconds(10)) }
        await m.settle()
        #expect(m.state.error == nil && fake.calls.count == 2)
        fake.fail["refreshApprovals"] = VaultFailure(.network)
        m.refresh()
        await m.settle()
        vault.ownerCheck = OwnerCheckView(state: .ok, deadline: Date().addingTimeInterval(60), hold: false)
        await m.settle()
        #expect(m.state.error == .network && fake.calls.count == 3)
    }

    /// What a request names is the member's own: the state prints counts only.
    @Test func theStateNamesNoOne() async {
        connections.connections = [Samples.connection("c1", paused: true)]
        connections.requests = [Samples.incoming()]
        let m = await model()
        for text in [String(describing: m.state), String(reflecting: m.state), "\(Mirror(reflecting: m.state).children.count)"] {
            #expect(!text.contains("Ada") && !text.contains("Sam") && !text.contains("042817"))
        }
    }
}

// swiftlint:enable line_length
