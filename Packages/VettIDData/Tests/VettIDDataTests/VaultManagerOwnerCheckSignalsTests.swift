import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDRelay

/// What the device reports reaches the owner check through ``VaultManager`` (VAULT-MESSAGING 0.73.0 §3.6.5): an operation
/// that counts as a failed check (§3.6.4) spends the estimate of tries left, and the relay connection coming back is a
/// reconnect, on which a probably locked vault is read again.
@MainActor
@Suite(.serialized) struct VaultManagerOwnerCheckSignalsTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var checks: OwnerCheckManager { phone.manager.ownerChecks }

    /// Setup code to the open app, and the vault's count read.
    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
        try await checks.refreshOwnerCheck()
        #expect(checks.estimate == OwnerCheckView.maxFailures)
    }

    @Test func aPinChangeAnsweredBadPinSpendsTheEstimate() async throws {
        defer { phone.close() }
        try await setUp()
        service.refuse("pin.change", with: "bad_pin", times: 1)
        _ = await vaultFailure { try await m.changePin(pin: "111111", newPin: "518293", password: password) }
        #expect(await eventually { checks.estimate == OwnerCheckView.maxFailures - 1 })
        await settle()
        #expect(checks.estimate == OwnerCheckView.maxFailures - 1, "counted once")
    }

    /// Only `bad_pin` and `bad_password` count among the answers.
    @Test func aPinChangeRefusedOtherwiseLeavesTheEstimate() async throws {
        defer { phone.close() }
        try await setUp()
        service.refuse("pin.change", with: "forbidden", times: 1)
        _ = await vaultFailure { try await m.changePin(pin: pin, newPin: "518293", password: password) }
        // A bad PIN after it spends one: had the refusal counted, two would be gone.
        service.refuse("pin.change", with: "bad_pin", times: 1)
        _ = await vaultFailure { try await m.changePin(pin: "111111", newPin: "518293", password: password) }
        #expect(await eventually { checks.estimate == OwnerCheckView.maxFailures - 1 })
        await settle()
        #expect(checks.estimate == OwnerCheckView.maxFailures - 1)
    }

    @Test func theRelayComingBackIsAReconnect() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(checks.relayReconnects == 0)
        // The relay client tries each call again itself: one more failure than its attempts fails a collect round.
        service.failNextCollects(RelayClient.defaultAttempts + 1)
        // The collection fails, then comes back, and the request's answer with it.
        try await checks.refreshOwnerCheck()
        #expect(await eventually { checks.relayReconnects == 1 })
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
