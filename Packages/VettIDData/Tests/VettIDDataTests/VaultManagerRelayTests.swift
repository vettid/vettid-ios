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

    /// The unlock's post-open read comes before the vault's relay attempt: a refusal after it is shown when its
    /// `identity.rotation_failed` item arrives, with no manual read.
    @Test func aRotationFailedItemReadsTheStatusAgain() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(!m.relayRefused)
        service.relayStatus = "refused"
        _ = try service.feedItemArrives("identity.rotation_failed", priority: "high")
        #expect(await eventually { m.relayRefused }, "the item made the app read the status")
    }

    private func status(_ relay: String?) throws -> VaultStatusInfo {
        let member = relay.map { #","relay":"\#($0)""# } ?? ""
        return try VaultJSON.decode(VaultStatusInfo.self, Array(#"{"vault_id":"v"\#(member)}"#.utf8))
    }

    /// The latest answer decides, not the last to arrive: a read sent before the rotation's whose refused answer arrives
    /// after the rotation's own read is dropped.
    @Test func anOlderReadArrivingLateIsDropped() async throws {
        defer { phone.close() }
        try await setUp()
        let rec = m.record.generation
        let sentBeforeRotation = m.beginStatusRead()
        let sentAfter = m.beginStatusRead()
        m.heard(status: try status(nil), since: rec, stamp: sentAfter)
        m.heard(status: try status("refused"), since: rec, stamp: sentBeforeRotation)
        #expect(!m.relayRefused, "the older answer does not bring the notice back")
        m.heard(status: try status("refused"), since: rec, stamp: m.beginStatusRead())
        #expect(m.relayRefused)
    }

    /// A read in flight at a lock lands after a quick re-unlock: it is dropped.
    @Test func aReadInFlightAtALockIsDropped() async throws {
        defer { phone.close() }
        try await setUp()
        let rec = m.record.generation
        let inFlight = m.beginStatusRead()
        try await m.lock()
        try await m.unlock(pin: pin)
        #expect(m.phase == .unlocked)
        m.heard(status: try status("refused"), since: rec, stamp: inFlight)
        #expect(!m.relayRefused)
    }
}

extension VaultManagerRelayTests {
    /// How many `vault.status` the vault received.
    var statusReads: Int { service.requestsSeen.filter { $0 == "vault.status" }.count }
}
