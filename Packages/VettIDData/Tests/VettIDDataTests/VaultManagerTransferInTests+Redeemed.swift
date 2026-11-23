import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A transfer scanned after a setup code was redeemed (§6.7.1): the transfer's vault is pinned, so no enrollment goes out
/// with the code's `user_guid`, nothing unlocks with it, and a completed transfer ends with its own.
extension VaultManagerTransferInTests {
    /// Enrolling is refused while the transfer waits (``VaultManager/codeTransferWaiting``), and no `vault.enroll` is sent.
    @Test func noEnrollmentWhileATransferWaitsAfterARedeem() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        _ = try await scanned()
        let seen = service.requestsSeen.count
        let error = await vaultFailure { try await m.enroll(pin: pin) { _ in } }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(!service.requestsSeen.dropFirst(seen).contains("vault.enroll"), "\(Array(service.requestsSeen.dropFirst(seen)))")
    }

    /// A completed transfer after a redeem ends with the transfer's `user_guid`, not the code's.
    @Test func aCompletedTransferAfterARedeemHasTheTransfersUserGuid() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        #expect(m.record.value.userGuid == service.userGuid)
        service.transferSendsUserGuid = "user-0002"
        try await transferred()
        #expect(m.record.value.userGuid == "user-0002" && m.userGuidUsable)
    }

    /// A transfer not completed (its start stored, not moved in) leaves no usable `user_guid`, whatever the record's
    /// `setup_complete` says: only the setup's completion, which clears the start, makes it usable.
    @Test func anUnfinishedTransferIsNotUsableWhateverSetupComplete() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try m.record.update(since: m.record.generation) {
            $0.transferStartedMs = 1
            $0.movedIn = false
            $0.setupComplete = true
        }
        #expect(!m.userGuidUsable)
    }

    /// A paired transfer whose take-over never ran stays Locked (the stuck notice) even when the record says the setup is
    /// complete: only the setup's completion, which clears the start, ends the guard.
    @Test func aDamagedPairedRecordStaysLockedWhateverSetupComplete() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        service.approveTransferIn()
        #expect(await eventually { d.deviceID != nil })
        d.mem.withLock { d.st.transferUserGuid = nil }
        try d.save()
        try m.record.update(since: m.record.generation) {
            $0.userGuid = "guid-of-a-setup-code"
            $0.setupComplete = true
        }
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .locked, "\(m.phase)")
        #expect(!m.userGuidUsable)
    }

    /// The unlock on a transfer that is not completed, or on a damaged record, is refused (`no_user_guid`), and no
    /// `vault.unlock` is sent.
    @Test(arguments: [false, true])
    func theUnlockIsRefusedWithoutAUsableUserGuid(damaged: Bool) async throws {
        defer { phone.close() }
        if damaged {
            try await transferred()
            try m.record.update(since: m.record.generation) { $0.userGuid = "a b" }
        } else {
            _ = try await m.redeemSetupCode(.secret(service.secret))
            _ = try await scanned()
        }
        #expect(!m.userGuidUsable)
        let seen = service.requestsSeen.count
        let r = try await m.unlock(pin: pin)
        #expect(r == .failed(.notSupported, code: UnlockAttempt.codeNoUserGuid), "\(r)")
        #expect(!service.requestsSeen.dropFirst(seen).contains("vault.unlock"), "\(Array(service.requestsSeen.dropFirst(seen)))")
    }
}
