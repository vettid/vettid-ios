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
        #expect(m.state.endFailure == nil, "the session ended: nothing left to retry")
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
}

// swiftlint:enable line_length
