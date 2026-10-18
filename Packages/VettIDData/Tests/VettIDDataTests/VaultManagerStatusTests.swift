import Foundation
import Testing
import VettIDAltChan
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// Settings → Vault status and Settings → Attestation from the vault manager (IOS-PLAN §8 I1.8): the member API's status,
/// the vault's own `vault.status` while it is open, and the iPhone's attestation. Mirrors vettid-android's
/// `VaultStatusViewModel` tests at the manager's level.
@MainActor
@Suite(.serialized) struct VaultManagerStatusTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// The open vault: the member API's state and release, the release this phone last unlocked into, and the vault's
    /// own counts, confirmation and recovery. No signer on an iPhone (IOS-PLAN ID15).
    @Test func theOpenVaultsStatus() async throws {
        defer { phone.close() }
        try await setUp()
        let o = try await m.overview()
        #expect(o.vaultID == service.vaultID)
        #expect(o.state == "unlocked")
        #expect(o.release == ReleaseInfoView(number: 3, status: "active", endsAt: nil, newestActive: nil, notice: nil))
        #expect(o.lastRelease == 3)
        #expect(o.provisional == false && o.devices == 1 && o.connections == 0)
        #expect(o.recovery == RecoveryStatusView(state: "armed", used: 0, counterUnavailable: false))
        #expect(o.recoveryOffered)
        #expect(o.signer == nil)
    }

    /// A locked vault is not asked for its own status: only the member API's is shown.
    @Test func aLockedVaultShowsTheMemberApisStatusOnly() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        service.status("locked")
        let o = try await m.overview()
        #expect(o.vaultID == service.vaultID && o.state == "locked")
        #expect(o.provisional == nil && o.devices == nil && o.connections == nil && o.recovery == nil)
        #expect(o.lastRelease == 3)
    }

    /// The vault refusing its own status is the screen's failure (only the network or no answer leaves the rows unknown).
    @Test func aRefusalOfTheVaultsOwnStatusIsTheScreensFailure() async throws {
        defer { phone.close() }
        try await setUp()
        service.failNext("vault.status")
        let refused = await vaultFailure { _ = try await m.overview() }
        // `retry` is the vault's answer, not the network: shown as the screen's failure, as vettid-android does.
        #expect(refused?.kind == .retry)
        let o = try await m.overview()
        #expect(o.devices == 1)
    }

    /// The vault's own status that gets no answer in time leaves its rows unknown; the screen still loads with the
    /// member API's.
    @Test func noAnswerFromTheVaultLeavesItsRowsUnknown() async throws {
        defer { phone.close() }
        try await setUp()
        service.holdMessages = true
        let o = try await m.overview()
        service.holdMessages = false
        #expect(o.vaultID == service.vaultID && o.state == "unlocked" && o.lastRelease == 3)
        #expect(o.provisional == nil && o.devices == nil && o.connections == nil && o.recovery == nil)
    }

    /// The iPhone's attestation: the vault accepted its App Attest key once paired; the enclave release it last verified.
    @Test func theIPhonesAttestation() async throws {
        defer { phone.close() }
        let before = try await m.attestationInfo()
        #expect(before.appAttest == AppAttestInfo(accepted: false) && !before.keyPresent)
        #expect(before.lastRelease == 0 && before.lastReleaseFingerprint == nil && before.environment == "test")
        try await setUp()
        let after = try await m.attestationInfo()
        #expect(after.appAttest == AppAttestInfo(accepted: true) && after.keyPresent)
        #expect(after.lastRelease == 3 && after.lastReleaseFingerprint == "a3a3 a3a3 a3a3 a3a3")
        // Android's device fields stay empty on an iPhone.
        #expect(after.keyLevel == nil && after.verifiedBoot == nil && after.attestationVersion == nil && !after.strongBoxAvailable)
    }

    /// After this phone was erased the vault no longer holds its App Attest key as this phone's: not accepted.
    @Test func anErasedPhoneIsNotAccepted() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(try await m.attestationInfo().appAttest?.accepted == true)
        try await m.eraseThisPhone()
        let after = try await m.attestationInfo()
        #expect(after.appAttest == AppAttestInfo(accepted: false) && after.lastRelease == 0)
    }

    /// The Android shape is unchanged: no App Attest part unless one is given.
    @Test func theAndroidShapeHasNoAppAttestPart() {
        let a = AttestationInfo(
            environment: "PRODUCTION", keyPresent: true, keyLevel: "TEE", strongBoxAvailable: false, attestationVersion: 300,
            verifiedBoot: "Verified", deviceLocked: true, bootKeyFingerprint: nil, lastRelease: 3, lastReleaseFingerprint: nil
        )
        #expect(a.appAttest == nil)
    }

    @Test func theRecoveryCounterAndTheFingerprint() throws {
        let json = #"{"state":"armed","attempts":{"used":2,"of":10},"counter":"unavailable"}"#
        let r = try VaultJSON.decode(RecoveryStatus.self, Array(json.utf8))
        #expect(VaultManager.recoveryView(r) == RecoveryStatusView(state: "armed", used: 2, counterUnavailable: true))
        let none = try VaultJSON.decode(RecoveryStatus.self, Array("{}".utf8))
        #expect(VaultManager.recoveryView(none) == RecoveryStatusView(state: "unknown", used: nil, counterUnavailable: false))
        #expect(VaultManager.fingerprint("") == nil)
        #expect(VaultManager.fingerprint("0123456789abcdef0123") == "0123 4567 89ab cdef")
        #expect(VaultManager.fingerprint("abcdef") == "abcd ef")
    }
}
