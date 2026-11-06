import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// The lasting notice of a relay key the relay refused (VAULT-MESSAGING 0.84.0 §3.4 "What the member sees", §10.2): it
/// follows the `relay` field of the latest `vault.status`. Mirrors vettid-android's `OwnerCheckManager.relayRefused` tests
/// (PR 301): memory only, cleared at a lock and a wipe, one re-read after a refused status.
@MainActor
@Suite(.serialized) struct VaultManagerRelayTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// The field decodes: `"refused"` is the notice; absent, another string and another type are not.
    @Test func theRelayFieldDecodesLeniently() throws {
        func info(_ relay: String) throws -> VaultStatusInfo {
            try VaultJSON.decode(VaultStatusInfo.self, Array(#"{"vault_id":"v"\#(relay)}"#.utf8))
        }
        #expect(try info(#","relay":"refused""#).relayRefused)
        #expect(try !info("").relayRefused)
        #expect(try !info(#","relay":"ok""#).relayRefused)
        #expect(try !info(#","relay":null"#).relayRefused)
        #expect(try !info(#","relay":{"state":"refused"}"#).relayRefused)
        #expect(try !info(#","relay":7"#).relayRefused)
    }

    /// Shown with the field, lasting while it is present, gone when a later status has none.
    @Test func theNoticeFollowsTheLatestStatus() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(!m.relayRefused)
        service.relayStatus = "refused"
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.relayRefused)
        _ = try await m.overview()
        #expect(m.relayRefused, "it lasts while the field is present")
        service.relayStatus = nil
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(!m.relayRefused)
        // The settings screen's own read decides as well.
        service.relayStatus = "refused"
        _ = try await m.overview()
        #expect(m.relayRefused)
        service.relayStatus = "other"
        _ = try await m.overview()
        #expect(!m.relayRefused, "an unknown value counts as absent")
    }

    /// A refused status is read once more, a minute later (here 5 ms), once per unlock.
    @Test func aRefusedStatusIsReadOnceMore() async throws {
        defer { phone.close() }
        try await setUp()
        let before = statusReads
        service.relayStatus = "refused"
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(await eventually { statusReads >= before + 2 }, "the re-read")
        try await Task.sleep(for: .milliseconds(100))
        let after = statusReads
        try await m.ownerChecks.refreshOwnerCheck()
        try await Task.sleep(for: .milliseconds(100))
        #expect(statusReads == after + 1, "only one re-read")
        #expect(m.relayRefused)
    }

    /// A locked app shows no relay notice; the notice is not kept on the phone, so a restart shows nothing until a status.
    @Test func theNoticeIsClearedAtLockAndNotKeptAcrossARestart() async throws {
        defer { phone.close() }
        try await setUp()
        service.relayStatus = "refused"
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.relayRefused)
        try await m.lock()
        #expect(!m.relayRefused)
        try await m.unlock(pin: pin)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.relayRefused)
        try await phone.restart()
        #expect(!m.relayRefused)
    }

    /// The new keys end it: the rotation reads the status again, and the notice goes.
    @Test func aRotationTakesTheNoticeAway() async throws {
        defer { phone.close() }
        try await setUp()
        service.relayStatus = "refused"
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.relayRefused)
        // The vault stops sending the field once the new keys are in force.
        service.relayStatus = nil
        try await m.rotate(password: password)
        #expect(!m.relayRefused)
    }
}

extension VaultManagerRelayTests {
    /// How many `vault.status` the vault received.
    var statusReads: Int { service.requestsSeen.filter { $0 == "vault.status" }.count }
}
