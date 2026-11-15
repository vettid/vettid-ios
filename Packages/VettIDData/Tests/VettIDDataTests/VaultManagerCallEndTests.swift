import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The hang-up of a live call before the member's lock (vettid-android `sendCallEnd`): the phone is locked from the first line of
/// the lock (`beginLock`), before the hooks run, so the call logic's `call.end` must not depend on the phase or on the open-vault
/// guard: it goes through the session in use while a lock is pending (``LockTimeUse/callEnd``), and before the vault is told to lock.
@MainActor
@Suite(.serialized) struct VaultManagerCallEndTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let callId = "01JB2Z6V9K3M4N5P6Q7R8S9T50"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func openVault() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    func seen(_ type: String) -> Int { service.requestsSeen.filter { $0 == type }.count }

    /// The hook of the lock, as the calls register it: while it runs the phone is locked, the client for the open vault refuses
    /// (`callApi`), and the hang-up still goes, before `vault.lock`.
    @Test func theHangUpGoesInTheLockHookBeforeTheVaultIsToldToLock() async throws {
        defer { phone.close() }
        try await openVault()
        var apiRefused = false
        var ended: (any Error)?
        m.onBeforeLock { [m, callId] in
            apiRefused = (try? m.callApi()) == nil
            do { try await m.sendCallEnd(callId: callId, reason: CallReason.hangup) } catch { ended = error }
        }
        let before = seen("call.end")
        try await m.lock()
        #expect(apiRefused, "the phone is locked from the first line: the open-vault client refuses")
        #expect(ended == nil)
        #expect(await eventually { seen("call.end") == before + 1 }, "the hang-up reached the vault")
        let order = service.requestsSeen
        let hangUp = try #require(order.lastIndex(of: "call.end"))
        let lock = try #require(order.lastIndex(of: "vault.lock"))
        #expect(hangUp < lock, "before the vault is told to lock")
    }

    /// Without a session there is nothing to send through (a sign-out, a deleted vault): refused, never a crash or a wait.
    @Test func withNoSessionTheHangUpIsRefused() async throws {
        defer { phone.close() }
        let failure = await vaultFailure { try await m.sendCallEnd(callId: callId, reason: CallReason.hangup) }
        #expect(failure?.code == "session_dropped")
        #expect(seen("call.end") == 0)
    }

    /// A reason the vault does not know is refused before anything is sent.
    @Test func anUnknownReasonIsRefused() async throws {
        defer { phone.close() }
        try await openVault()
        await #expect(throws: (any Error).self) { try await m.sendCallEnd(callId: callId, reason: "bye") }
        #expect(seen("call.end") == 0)
    }
}
