import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// Desktops' and agents' access sessions for a renewal request (VAULT-MESSAGING 0.78.0 §6.8 step 3): read from
/// `device.list`, followed by `sync.event` `device.session`, ended with `device.session.end` alone, and dropped with the
/// vault. Mirrors the data side of vettid-android `RenewalTest`.
@MainActor
@Suite struct DeviceSessionsTests {
    let ops = FakeApprovalOps()
    let connOps = FakeConnectionOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)

    func manager(held: @escaping @MainActor () -> Bool = { false }) -> ApprovalsManager {
        let ops = ops, connOps = connOps, now = now
        let c = ConnectionsManager(ops: { connOps }, now: { now })
        return ApprovalsManager(connections: c, ops: { ops }, now: { now }, held: held)
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    func at(_ minutes: Double) -> String { Timestamps.formatMillis(now.addingTimeInterval(minutes * 60)) }

    @Test func theListSaysEachSessionsEnd() async throws {
        ops.devices = [("d1", at(30)), ("d2", nil)]
        let m = manager()
        #expect(!m.deviceSessionsKnown && m.deviceSessionReads == 0)
        try await m.readDeviceSessions()
        #expect(m.deviceSessionsKnown && m.deviceSessionReads == 1)
        #expect(m.deviceSessions == ["d1": now.addingTimeInterval(1_800)])
    }

    /// A read that fails changes nothing: nothing is known, so no request is a renewal.
    @Test func aFailedReadKnowsNothing() async {
        ops.errors["deviceList"] = FakeApprovalOps.error("retry")
        let m = manager()
        await #expect(throws: VaultFailure.self) { try await m.readDeviceSessions() }
        #expect(!m.deviceSessionsKnown && m.deviceSessionReads == 0 && m.deviceSessions.isEmpty)
    }

    /// `sync.event` `device.session` sets the device's session's end, or removes it, and reads the list again once a
    /// screen asked for it (a read that failed learns the rest).
    @Test func aSessionEventUpdatesTheDeviceAndReadsAgain() async throws {
        ops.devices = [("d1", at(30))]
        let m = manager()
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"d1","expires_at":"\#(at(60))"}"#))
        #expect(m.deviceSessions == ["d1": now.addingTimeInterval(3_600)])
        #expect(!ops.calls.contains("deviceList"), "no screen asked: no read")
        try await m.readDeviceSessions()
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"d1"}"#))
        #expect(m.deviceSessions["d1"] == nil)
        #expect(await eventually { ops.calls.filter { $0 == "deviceList" }.count == 2 })
    }

    /// Ending access sends `device.session.end` alone, never a deny, and the device's asks leave with it.
    @Test func endingAccessSendsTheEndAloneAndDropsTheAsks() async throws {
        ops.devices = [("d1", at(30))]
        let m = manager()
        try await m.readDeviceSessions()
        m.onEvent(event("device.session.pending", #"{"request_id":"s1","device_id":"d1","name":"Laptop","exp":"\#(at(10))"}"#))
        #expect(m.approvals.map(\.key) == ["device:device.session.pending:s1"])
        try await m.endDeviceAccess("d1")
        #expect(ops.calls.contains("sessionEnd:d1") && !ops.calls.contains { $0.hasPrefix("sessionDeny") })
        #expect(m.approvals.isEmpty && m.deviceSessions["d1"] == nil)
    }

    /// A failed end leaves the request open and the session as it was, and reads the list again.
    @Test func aFailedEndLeavesTheRequestOpen() async throws {
        ops.devices = [("d1", at(30))]
        let m = manager()
        try await m.readDeviceSessions()
        m.onEvent(event("device.session.pending", #"{"request_id":"s1","device_id":"d1","exp":"\#(at(10))"}"#))
        ops.errors["sessionEnd"] = FakeApprovalOps.error("retry")
        await #expect(throws: VaultFailure.self) { try await m.endDeviceAccess("d1") }
        #expect(m.approvals.count == 1 && m.deviceSessions["d1"] != nil)
        #expect(await eventually { ops.calls.filter { $0 == "deviceList" }.count == 2 })
    }

    /// A lock or a hold drops what was read: nothing is known until it is read again, and a read on its way when the vault
    /// was dropped is not published.
    @Test func theSessionsGoWithTheVault() async throws {
        ops.devices = [("d1", at(30))]
        let m = manager()
        try await m.readDeviceSessions()
        m.forgetOpenVault()
        #expect(!m.deviceSessionsKnown && m.deviceSessions.isEmpty)
        let gate = TestDeferred<Void>()
        ops.devicesGate = gate
        let read = Task { try await m.readDeviceSessions() }
        #expect(await eventually { ops.calls.filter { $0 == "deviceList" }.count == 2 })
        m.forgetOpenVault()
        gate.complete(())
        try await read.value
        #expect(!m.deviceSessionsKnown && m.deviceSessions.isEmpty)
    }

    /// What an event says of the device's session holds even when a list merged after it already judged its request.
    @Test func anOlderEventStillUpdatesTheSession() async throws {
        ops.pendingSupported = true
        ops.pendingTs = now.addingTimeInterval(60)
        let m = manager()
        try await m.refreshApprovals()
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"d1","expires_at":"\#(at(30))"}"#))
        #expect(m.deviceSessions["d1"] == now.addingTimeInterval(1_800))
    }

    /// A screen that asked keeps asking across a hold: the read of the lists when it lifts reads the sessions too.
    @Test func theListsReadAfterAHoldReadTheSessions() async throws {
        ops.devices = [("d1", at(30))]
        let m = manager()
        try await m.refreshApprovals()
        #expect(!ops.calls.contains("deviceList"), "no screen asked: not read")
        try await m.readDeviceSessions()
        m.forgetOpenVault()
        try await m.refreshApprovals()
        #expect(await eventually { m.deviceSessionsKnown && m.deviceSessions["d1"] != nil })
    }

    /// An event that comes while a read is on its way is newer than what the read answers.
    @Test func anEventDuringAReadWins() async throws {
        ops.devices = [("d1", at(30))]
        let m = manager()
        let gate = TestDeferred<Void>()
        ops.devicesGate = gate
        let read = Task { try await m.readDeviceSessions() }
        #expect(await eventually { ops.calls.contains("deviceList") })
        ops.devices = []
        m.onEvent(event("sync.event", #"{"kind":"device.session","device_id":"d1"}"#))
        gate.complete(())
        try await read.value
        #expect(m.deviceSessionsKnown && m.deviceSessions["d1"] == nil, "the stale answer does not bring the session back")
        #expect(await eventually { m.deviceSessionReads == 2 } && m.deviceSessions["d1"] == nil)
    }

    /// An answer to a read begun before one already applied is dropped.
    @Test func anOlderReadIsDropped() async throws {
        ops.devices = [("d1", at(30))]
        let m = manager()
        let gate = TestDeferred<Void>()
        ops.devicesGate = gate
        let older = Task { try await m.readDeviceSessions() }
        #expect(await eventually { ops.calls.contains("deviceList") })
        ops.devicesGate = nil
        ops.devices = [("d1", at(90))]
        try await m.readDeviceSessions()
        #expect(m.deviceSessions["d1"] == now.addingTimeInterval(5_400))
        ops.devices = [("d1", at(30))]
        gate.complete(())
        try await older.value
        #expect(m.deviceSessions["d1"] == now.addingTimeInterval(5_400) && m.deviceSessionReads == 1)
    }

    @Test func theHoldIsAskedOfTheVault() {
        var held = false
        let m = manager { held }
        #expect(!m.vaultHeld)
        held = true
        #expect(m.vaultHeld)
    }
}
