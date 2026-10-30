import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData
import VettIDDataTesting

/// A request withdrawn by its challenger while its screen shows (VAULT-MESSAGING 0.80.0 §10.4; ANDROID-PLAN 0.1.101): the
/// screen stays and says so; a decision in flight answered `not_found` says withdrawn only once the flag was seen, waiting a
/// moment for it, else that the request left; a flag that comes later still turns the screen; the mute is offered, and on
/// a service confirmed first. Mirrors ANDROID-PLAN 0.1.101's tests.
@MainActor
@Suite struct WithdrawnDecisionTests {
    let connections = FakeConnections()
    let fake: FakeApprovals

    init() { fake = FakeApprovals(connections: connections) }

    func model(_ key: String = "auth:a1", wait: Duration = .milliseconds(400)) async -> ApprovalDetailViewModel {
        let m = ApprovalDetailViewModel(key: key, approvals: fake, connections: connections)
        m.withdrawnWait = wait
        await m.settle()
        return m
    }

    @Test func aWithdrawnRequestKeepsItsScreenAndSaysSo() async {
        connections.connections = [Samples.connection("c1")]
        fake.listed = [Samples.auth("a1", purpose: .signin)]
        let m = await model()
        m.setPassword("pw")
        fake.withdraw("auth:a1")
        #expect(m.state.withdrawn && !m.state.gone && !m.state.notHeld && m.state.approval != nil && m.state.error == nil)
        #expect(m.state.connectionName == "Sam Lee")
    }

    /// Without the flag the request closes as before: "Already decided".
    @Test func anUnflaggedCloseIsGoneAsBefore() async {
        fake.listed = [Samples.auth("a1")]
        let m = await model()
        fake.listed = []
        #expect(m.state.gone && !m.state.withdrawn)
    }

    /// An approve in flight answered `not_found`: withdrawn when the flag came during the wait, else gone; progress meanwhile.
    @Test func aDecisionAnsweredNotFoundWaitsForTheFlag() async throws {
        fake.listed = [Samples.auth("a1"), Samples.auth("a2")]
        fake.fail["approveAuthentication"] = VaultFailure(.notFound)
        let m = await model("auth:a1")
        m.setPassword("pw")
        m.approve()
        try await Task.sleep(for: .milliseconds(100))
        #expect(m.state.busy && !m.state.gone, "progress while it waits")
        fake.withdrawn.insert("auth:a1")
        await m.settle()
        #expect(m.state.withdrawn && !m.state.gone && !m.state.busy && m.state.error == nil)

        fake.fail["approveAuthentication"] = VaultFailure(.notFound)
        let n = await model("auth:a2", wait: .milliseconds(150))
        n.setPassword("pw")
        n.approve()
        await n.settle()
        #expect(n.state.gone && !n.state.withdrawn, "no flag: the request left")
        // The flag arrives after that while the screen is open: it turns to withdrawn.
        fake.withdrawn.insert("auth:a2")
        #expect(n.state.withdrawn && !n.state.gone)
    }

    /// A request decided here closes its screen even if a flag for it comes later.
    @Test func aRequestDecidedHereIsNotWithdrawn() async {
        fake.listed = [Samples.auth("a1")]
        let m = await model()
        m.setPassword("pw")
        m.approve()
        await m.settle()
        fake.withdrawn.insert("auth:a1")
        #expect(m.state.done && !m.state.withdrawn)
    }

    /// The notice offers the existing mute: a person's at once, a service's after its confirmation.
    @Test func theMuteIsOfferedAndConfirmedOnAService() async {
        var service = Samples.connection("c1")
        service.isService = true
        connections.connections = [service, Samples.connection("c2")]
        fake.listed = [Samples.auth("a1", conn: "c1"), Samples.auth("a2", conn: "c2")]
        let s = await model("auth:a1")
        fake.withdraw("auth:a1")
        #expect(s.state.connectionIsService && !s.state.asksMuted)
        s.askMute(true)
        #expect(s.state.confirmMute && !connections.calls.contains { $0.hasPrefix("asksMute") })
        s.askMute(false)
        #expect(!s.state.confirmMute)
        s.askMute(true)
        s.mute()
        await s.settle()
        #expect(connections.calls.contains("asksMute:c1:true") && s.state.asksMuted && !s.state.confirmMute)

        let p = await model("auth:a2")
        fake.withdraw("auth:a2")
        p.askMute(true)
        await p.settle()
        #expect(!p.state.connectionIsService && connections.calls.contains("asksMute:c2:true") && p.state.asksMuted)
    }

    /// A mute that fails says why, and the notice stays.
    @Test func aFailedMuteSaysSo() async {
        connections.connections = [Samples.connection("c1")]
        connections.fail["asksMute:c1:true"] = VaultFailure(.network)
        fake.listed = [Samples.auth("a1")]
        let m = await model()
        fake.withdraw("auth:a1")
        m.askMute(true)
        await m.settle()
        #expect(m.state.withdrawn && !m.state.asksMuted && m.state.muteError == .network && !m.state.muting)
    }

    /// The notice stays while the mute is on its way: no decision, no "Already decided" (the mute is not the decision's
    /// progress).
    @Test func theNoticeStaysWhileTheMuteIsOnItsWay() async {
        connections.connections = [Samples.connection("c1")]
        fake.listed = [Samples.auth("a1")]
        let m = await model()
        fake.withdraw("auth:a1")
        m.mute()
        #expect(m.state.muting && m.state.withdrawn && !m.state.gone && !m.state.busy)
        await m.settle()
        #expect(m.state.withdrawn && m.state.asksMuted && !m.state.muting)
    }

    /// Once withdrawn, a decision's failure (a wrong password, a backoff) is no longer said: only the notice.
    @Test func aDecisionsFailureGoesOnceWithdrawn() async {
        fake.listed = [Samples.auth("a1")]
        fake.fail["approveAuthentication"] = VaultFailure(.badPassword)
        let m = await model()
        m.setPassword("pw")
        m.approve()
        await m.settle()
        #expect(m.state.error == .badPassword)
        fake.withdraw("auth:a1")
        #expect(m.state.withdrawn && m.state.error == nil && m.state.retryUntil == nil)
    }

    /// A connection not yet known (the connections not read) may be a service: its mute is confirmed too.
    @Test func anUnknownConnectionsMuteIsConfirmed() async {
        fake.listed = [Samples.auth("a1", conn: "c9")]
        let m = await model()
        fake.withdraw("auth:a1")
        m.askMute(true)
        #expect(!m.state.connectionKnown && m.state.confirmMute && !connections.calls.contains { $0.hasPrefix("asksMute") })
    }

    /// "Not me" in flight answered `not_found` waits for the flag as an approve does.
    @Test func aDenyAnsweredNotFoundWaitsForTheFlag() async throws {
        fake.listed = [Samples.auth("a1", purpose: .signin)]
        fake.fail["denyAuthentication"] = VaultFailure(.notFound)
        let m = await model()
        m.deny()
        try await Task.sleep(for: .milliseconds(100))
        #expect(m.state.busy && !m.state.gone)
        fake.withdrawn.insert("auth:a1")
        await m.settle()
        #expect(m.state.withdrawn && !m.state.busy && !m.state.gone)
    }
}
