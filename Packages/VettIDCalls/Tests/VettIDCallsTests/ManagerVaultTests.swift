import Foundation
import Testing
@testable import VettIDCalls
import VettIDData
import VettIDDataTesting
import VettIDVault

/// ``ManagerVault`` over a real vault manager and the fake vault service: what the calls' wiring needs of the app's vault.
@MainActor
@Suite(.serialized) struct ManagerVaultTests {
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

    func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// The lock's hook as the wiring registers it: the vault already counts as locked, the open-vault client refuses, and the call's
    /// hang-up through the gateway still reaches the vault, before it is told to lock.
    @Test func theGatewayEndsACallInTheLocksHookBeforeTheVaultLocks() async throws {
        defer { phone.close() }
        try await openVault()
        let vault = ManagerVault(m)
        var opened: [Bool] = []
        var ended: (any Error)?
        m.onBeforeLock { [m, callId] in
            opened.append(m.phase == .unlocked)
            do { try await vault.gateway.end(callId, reason: CallReason.hangup) } catch { ended = error }
        }
        try await m.lock()
        #expect(opened == [false], "locked from the lock's first line, before the hooks run")
        #expect(ended == nil, "the hang-up is not refused")
        #expect(await waitFor { seen("call.end") == 1 })
        let order = service.requestsSeen
        let hangUp = try #require(order.lastIndex(of: "call.end"))
        let lock = try #require(order.lastIndex(of: "vault.lock"))
        #expect(hangUp < lock, "before the vault is told to lock")
    }

    /// Rule 3: a vault that must first move to a newer release counts as not open for the calls (none starts or rings), and
    /// as open again once nothing newer is listed.
    @Test func aRequiredUpdateCountsAsClosed() async throws {
        defer { phone.close() }
        try await openVault()
        let vault = ManagerVault(m)
        var changes = vault.unlockedChanges().makeAsyncIterator()
        #expect(await changes.next() == true)
        service.listsRelease4 = true
        await m.releaseUpdate.refreshOffer()
        #expect(m.releaseUpdate.required)
        #expect(await changes.next() == false)
        #expect(!vault.isOpen)
        service.listsRelease4 = false
        await m.releaseUpdate.refreshOffer()
        #expect(await changes.next() == true)
        #expect(vault.isOpen)
    }

    @Test func theLockCountsAsClosedAtOnce() async throws {
        defer { phone.close() }
        try await openVault()
        let vault = ManagerVault(m)
        var changes = vault.unlockedChanges().makeAsyncIterator()
        #expect(await changes.next() == true)
        try await m.lock()
        #expect(await changes.next() == false)
        #expect(!vault.updateShowing)
    }
}
