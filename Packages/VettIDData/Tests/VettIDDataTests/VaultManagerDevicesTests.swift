import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The devices list end to end (VAULT-MESSAGING §10.3, ANDROID-PLAN 0.1.53 AA1): this phone against ``FakeVaultService``, which
/// answers `device.list` with this phone's entry and a desktop. A lock and a wipe forget the list.
@MainActor
@Suite(.serialized) struct VaultManagerDevicesTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func open() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
    }

    @Test func theListIsReadOverTheSessionAndALockForgetsIt() async throws {
        defer { phone.close() }
        try await open()
        try await m.devices.refresh()
        #expect(m.devices.load == .loaded)
        // This phone is the entry with the session's own device id; the desktop follows it.
        #expect(m.devices.devices.map(\.id).count == 2)
        #expect(m.devices.devices.first?.thisPhone == true && m.devices.devices.last?.isDesktop == true)
        try await m.lock()
        #expect(m.devices.devices.isEmpty && m.devices.load == .notLoaded && m.devices.removed == nil)
    }

    /// A `sync.event` of a kind that changes the list reads it again, in the background; one that does not, does not.
    @Test func aDeviceEventReadsTheListAgain() async throws {
        defer { phone.close() }
        try await open()
        #expect(m.devices.load == .notLoaded)
        try service.deviceEventArrives(kind: "message.read")
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.devices.load == .notLoaded)
        try service.deviceEventArrives(kind: "device.paired", deviceID: "dev-2")
        #expect(await eventually { m.devices.load == .loaded && m.devices.devices.count == 2 })
    }

    /// A removal or an end of access takes the device's asks out of Approvals here (the vault tells the member's other
    /// devices only, §10.1), and ends its session in the renewal book.
    @Test func removingADeviceTakesItsAsksOutOfApprovals() async throws {
        defer { phone.close() }
        try await open()
        try service.deviceAsksSession(deviceID: "dev-2")
        #expect(await eventually { m.approvals.approvals.contains { $0.key.hasPrefix("device:device.session.pending:") } })
        try await m.devices.refresh()
        try await m.devices.remove("dev-2")
        #expect(!m.approvals.approvals.contains { $0.key.hasPrefix("device:") })
        #expect(m.devices.removed?.id == "dev-2")
    }

    /// A hold forgets the list, as a lock does (IOS-PLAN §6.9).
    @Test func theHoldForgetsTheList() async throws {
        defer { phone.close() }
        try await open()
        try await m.devices.refresh()
        #expect(m.devices.load == .loaded)
        m.ownerChecks.onHeldChange(true)
        #expect(m.devices.devices.isEmpty && m.devices.load == .notLoaded)
    }
}
