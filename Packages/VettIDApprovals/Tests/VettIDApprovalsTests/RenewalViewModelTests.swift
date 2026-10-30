import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData
import VettIDDataTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// A renewal request (VAULT-MESSAGING 0.78.0 §6.8 step 3; owner decision 2026-10-29: decline-only): a session request from a
/// device whose session has not expired, known from the device list read when the screen opens. "Deny and end access now"
/// asks the confirmation and sends the end alone; a failure leaves the request open with Try again; the hold closes the
/// confirmation and ends nothing. Mirrors vettid-android `RenewalTest`.
@MainActor
@Suite struct RenewalViewModelTests {
    let connections = FakeConnections()
    let fake: FakeApprovals
    let now = Date()

    init() { fake = FakeApprovals(connections: connections) }

    static func session(_ id: String = "s1", device: String? = "dev1", name: String? = "Laptop", role: String = "desktop", exp: Date? = nil) -> PendingApproval {
        .device(DeviceRequest(type: "device.session.pending", id: id, deviceName: name, role: role, requestType: nil, receivedAt: Date(), exp: exp, deviceID: device))
    }

    let key = "device:device.session.pending:s1"

    func model(_ sessions: [String: Date]? = [:]) async -> ApprovalDetailViewModel {
        fake.listed = [Self.session()]
        fake.sessionsGate = { [fake] in if let sessions { fake.deviceSessions = sessions } }
        let m = ApprovalDetailViewModel(key: key, approvals: fake, connections: connections)
        await m.settle()
        return m
    }

    @Test func aLiveSessionMakesARenewal() async {
        let until = now.addingTimeInterval(1_800)
        let m = await model(["dev1": until])
        #expect(fake.calls.contains("readDeviceSessions:"))
        #expect(m.state.renewalUntil(at: now) == until && m.state.sessionEnd == until)
        #expect(!m.state.canApprove(at: now), "session requests stay decline-only")
    }

    /// No session, another request kind, a failed read, or a session that passes while shown: a first request.
    @Test func otherwiseItIsAFirstRequest() async {
        #expect(await model(["other": now.addingTimeInterval(1_800)]).state.renewalUntil(at: now) == nil)
        let passing = await model(["dev1": now.addingTimeInterval(30)])
        #expect(passing.state.renewalUntil(at: now) != nil && passing.state.renewalUntil(at: now.addingTimeInterval(31)) == nil)
        fake.fail["readDeviceSessions"] = VaultFailure(.network)
        fake.deviceSessions = ["dev1": now.addingTimeInterval(1_800)]
        let failed = await model(nil)
        #expect(failed.state.renewalUntil(at: now) == nil, "a failed read is never trusted to say there is a session")
        fake.listed = [Samples.device()]
        let approval = ApprovalDetailViewModel(key: Samples.device().key, approvals: fake, connections: connections)
        await approval.settle()
        #expect(approval.state.sessionEnd == nil)
    }

    /// A later read (after a `sync.event` `device.session`) makes it a renewal after all.
    @Test func aLaterReadCounts() async {
        fake.fail["readDeviceSessions"] = VaultFailure(.network)
        let m = await model(nil)
        #expect(m.state.renewalUntil(at: now) == nil)
        fake.sessionsRead(["dev1": now.addingTimeInterval(1_800)])
        #expect(m.state.renewalUntil(at: now) != nil)
    }

    /// "Deny and end access now" asks first; the end goes alone and the screen closes.
    @Test func endingAccessIsConfirmedThenSentAlone() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        m.askEndAccess()
        #expect(m.state.confirmEnd && !fake.calls.contains("endDeviceAccess:dev1"))
        m.dismissEndAccess()
        #expect(!m.state.confirmEnd)
        m.askEndAccess()
        m.endAccess()
        await m.settle()
        #expect(fake.calls.contains("endDeviceAccess:dev1") && !fake.calls.contains { $0.hasPrefix("declineDeviceRequest") })
        #expect(m.state.done)
    }

    /// A failure is said, the request stays open, and Try again asks the confirmation again; it clears once the list says the
    /// session ended.
    @Test func aFailedEndStaysOpenWithTryAgain() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        fake.fail["endDeviceAccess"] = VaultFailure(.network)
        m.askEndAccess()
        m.endAccess()
        await m.settle()
        #expect(m.state.endFailure == .network && !m.state.done && m.state.approval != nil && !m.state.gone)
        m.askEndAccess()
        #expect(m.state.confirmEnd && m.state.endFailure == nil)
        m.dismissEndAccess()
        fake.fail["endDeviceAccess"] = VaultFailure(.network)
        m.askEndAccess()
        m.endAccess()
        await m.settle()
        #expect(m.state.endFailure == .network)
        fake.sessionsRead([:])
        #expect(await eventually { m.state.endFailure == nil }, "the session ended: nothing left to retry")
    }

    /// The hold: a confirmation open closes and ends nothing; a failure stays said while nothing is known.
    @Test func theHoldEndsNothing() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        m.askEndAccess()
        fake.vaultHeld = true
        fake.forgetOpenVault()
        #expect(!m.state.confirmEnd && m.state.held)
        m.endAccess()
        await m.settle()
        #expect(!fake.calls.contains("endDeviceAccess:dev1"))
        m.askEndAccess()
        #expect(!m.state.confirmEnd, "nothing is asked while held")
    }

    @Test func aFailureOutlivesTheHold() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        fake.fail["endDeviceAccess"] = VaultFailure(.network)
        m.askEndAccess()
        m.endAccess()
        await m.settle()
        fake.vaultHeld = true
        fake.forgetOpenVault()
        #expect(m.state.endFailure == .network, "kept while nothing is known")
    }

    /// A confirmation open when the request leaves (decided elsewhere) stays and still ends access.
    @Test func anOpenConfirmationOutlivesTheRequest() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        m.askEndAccess()
        fake.listed = []
        #expect(m.state.gone && m.state.confirmEnd)
        m.endAccess()
        await m.settle()
        #expect(fake.calls.contains("endDeviceAccess:dev1") && m.state.done)
    }

    func failedEnd(_ m: ApprovalDetailViewModel) async {
        fake.fail["endDeviceAccess"] = VaultFailure(.network)
        m.askEndAccess()
        m.endAccess()
        await m.settle()
    }

    /// What a hold does, and its lift: the request and the sessions drop, then come back with the next reads.
    func holdAndLift(sessions: [String: Date]) async {
        fake.vaultHeld = true
        fake.forgetOpenVault()
        // A hold lasts at least until the owner check passes: the screen's followers see it before it lifts.
        try? await Task.sleep(for: .milliseconds(200))
        fake.vaultHeld = false
        fake.listed = [Self.session()]
        fake.sessionsRead(sessions)
    }

    /// After a hold lifts, the request is a renewal again; a session still live keeps a failure, with Try again.
    @Test func aLiveSessionAfterTheHoldKeepsTheFailure() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        await failedEnd(m)
        await holdAndLift(sessions: ["dev1": now.addingTimeInterval(1_800)])
        #expect(await eventually { m.state.renewalUntil(at: now) != nil && m.state.endFailure == .network })
        m.askEndAccess()
        #expect(m.state.confirmEnd, "Try again asks again")
    }

    @Test func aSessionThatEndedDuringTheHoldClearsTheFailureWhenItLifts() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        await failedEnd(m)
        await holdAndLift(sessions: [:])
        #expect(await eventually { m.state.endFailure == nil && m.state.renewalUntil(at: now) == nil })
    }

    /// A failure recorded after the session already ended stays: only a change from live to ended clears it.
    @Test func aFailureRecordedAfterTheSessionPassedIsStillShown() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        m.askEndAccess()
        fake.sessionEvent("dev1", expiresAt: nil)
        #expect(await eventually { m.state.renewalUntil(at: now) == nil })
        fake.fail["endDeviceAccess"] = VaultFailure(.network)
        m.endAccess()
        await m.settle()
        #expect(m.state.endFailure == .network)
        fake.sessionsRead(["other": now.addingTimeInterval(60)])
        fake.sessionEvent("other", expiresAt: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(m.state.endFailure == .network)
    }

    /// A due check (a forget without a hold) leaves an open confirmation open.
    @Test func aDueCheckKeepsTheConfirmation() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        m.askEndAccess()
        fake.forgetOpenVault()
        for _ in 0..<20 { await Task.yield() }
        #expect(m.state.confirmEnd)
    }

    /// A hold closes the confirmation for good: it does not come back when the hold lifts.
    @Test func theHoldClosesTheConfirmationForGood() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        m.askEndAccess()
        await holdAndLift(sessions: ["dev1": now.addingTimeInterval(1_800)])
        for _ in 0..<20 { await Task.yield() }
        #expect(!m.state.confirmEnd)
    }

    /// The session ends elsewhere (`sync.event device.session`): an open screen reads as a first request.
    @Test func aSyncedEndMakesAFirstRequest() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        fake.sessionEvent("dev1", expiresAt: nil)
        #expect(m.state.renewalUntil(at: now) == nil && m.state.sessionEnd == nil)
    }

    @Test func cancellingTheConfirmationSendsNothing() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        m.askEndAccess()
        m.dismissEndAccess()
        m.endAccess()
        await m.settle()
        #expect(!fake.calls.contains { $0.hasPrefix("endDeviceAccess") } && !m.state.done)
    }

    /// Ending access from the screen of a request that left keeps that screen while it is sent; ended from the request, the
    /// screen never reads as gone before it closes.
    @Test func theScreenStaysWhileAccessIsEnded() async {
        var open: (@MainActor () -> Void)?
        fake.endGate = { await withCheckedContinuation { c in open = { c.resume() } } }
        let left = await model(["dev1": now.addingTimeInterval(1_800)])
        left.askEndAccess()
        fake.listed = []
        left.endAccess()
        #expect(await eventually { open != nil })
        #expect(left.state.gone && left.state.busy)
        open?()
        await left.settle()
        #expect(left.state.done)
        open = nil
        let shown = await model(["dev1": now.addingTimeInterval(1_800)])
        shown.askEndAccess()
        shown.endAccess()
        #expect(await eventually { open != nil })
        #expect(!shown.state.gone)
        open?()
        await shown.settle()
        #expect(shown.state.done && !shown.state.gone)
    }

    /// A failed end on the screen of a request that left: said, with Try again only while the session is live.
    @Test func aFailedEndOnTheGoneScreen() async {
        let m = await model(["dev1": now.addingTimeInterval(1_800)])
        m.askEndAccess()
        fake.listed = []
        fake.fail["endDeviceAccess"] = VaultFailure(.network)
        m.endAccess()
        await m.settle()
        #expect(m.state.gone && m.state.endFailure == .network && m.state.renewalUntil(at: now) != nil)
        m.askEndAccess()
        #expect(m.state.confirmEnd, "Try again while the session is live")
        m.dismissEndAccess()
        fake.sessionEvent("dev1", expiresAt: nil)
        #expect(await eventually { m.state.renewalUntil(at: now) == nil })
        m.askEndAccess()
        #expect(!m.state.confirmEnd, "nothing to retry once the session ended")
    }

    /// A failed end after the session passed by the clock (no event said so): the read the failure brings does not clear it.
    @Test func aFailureAfterTheSessionPassedByTheClockStays() async throws {
        let end = Date().addingTimeInterval(1)
        let m = await model(["dev1": end])
        m.askEndAccess()
        try await Task.sleep(for: .milliseconds(1_200))
        fake.fail["endDeviceAccess"] = VaultFailure(.network)
        fake.sessionsAfterFailedEnd = ["dev1": end]
        m.endAccess()
        await m.settle()
        for _ in 0..<20 { await Task.yield() }
        #expect(m.state.endFailure == .network)
    }

    /// A screen opened before its request is held (from the feed, before the list answered) follows the request from when
    /// it arrives: it asks, reads, and becomes a renewal.
    @Test func aRequestHeldAfterTheScreenOpenedBecomesARenewal() async {
        fake.sessionsGate = { [fake, now] in fake.deviceSessions = ["dev1": now.addingTimeInterval(1_800)] }
        let m = ApprovalDetailViewModel(key: key, approvals: fake, connections: connections)
        await m.settle()
        #expect(m.state.approval == nil && fake.sessionAskers == 0 && !fake.calls.contains("readDeviceSessions:"))
        fake.listed = [Self.session()]
        #expect(await eventually { fake.calls.contains("readDeviceSessions:") })
        await m.settle()
        #expect(await eventually { m.state.renewalUntil(at: now) != nil })
        #expect(fake.sessionAskers == 1)
    }

    /// The screen asks for the sessions while it is open, and gives the ask back when it goes.
    @Test func theScreenAsksWhileOpen() async {
        var m: ApprovalDetailViewModel? = await model(["dev1": now.addingTimeInterval(1_800)])
        #expect(fake.sessionAskers == 1)
        m = nil
        #expect(await eventually { fake.sessionAskers == 0 }, "\(String(describing: m))")
    }

    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

// swiftlint:enable line_length
