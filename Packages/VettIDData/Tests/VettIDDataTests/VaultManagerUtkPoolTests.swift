import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The phone's UTK pool (VAULT-MESSAGING §3.5.4) against ``FakeVaultService`` refusing in vettid-vault's order: a
/// refusal before the UTK is spent (`forbidden` to a phone that is no longer the holder) puts it back, so that refusals
/// one after another never drain the pool while the vault still holds a full one for the phone; a refusal after the
/// spend (a wrong PIN) does not.
@MainActor
@Suite(.serialized) struct VaultManagerUtkPoolTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var utks: Int? { m.session?.device.utkCount }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    @Test func forbiddenRefusalsDoNotDrainThePool() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try #require(utks)
        let vaultsBefore = service.outstandingUTKs
        #expect(before > 0)
        service.notHolder = true
        for _ in 0..<(before + 3) {
            let outcome = try await m.ownerChecks.check(pin: pin, password: password)
            guard case .failed(_, code: "forbidden") = outcome else {
                Issue.record("not refused forbidden: \(outcome)")
                return
            }
            #expect(utks == before, "the UTK the vault did not spend is back in the pool")
        }
        #expect(service.outstandingUTKs == vaultsBefore, "nothing spent")
        #expect(service.ownerChecks.isEmpty)
        // Holder again: the check goes through with a UTK of the same pool.
        service.notHolder = false
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
    }

    @Test func aWrongPinSpendsItsUTK() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try #require(utks)
        #expect(try await m.ownerChecks.check(pin: "111111", password: password) == .badPin(checksLeft: 9))
        #expect(utks == before - 1)
    }
}
