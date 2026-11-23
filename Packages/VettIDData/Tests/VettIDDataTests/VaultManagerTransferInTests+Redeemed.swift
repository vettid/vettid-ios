import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A transfer scanned after a setup code was redeemed (§6.7.1): the transfer's vault is pinned, so no enrollment goes out
/// with the code's `user_guid`, nothing unlocks with it, and a completed transfer ends with its own.
extension VaultManagerTransferInTests {
    /// Enrolling is refused while the transfer waits (``VaultManager/codeTransferWaiting``): no `vault.enroll` is posted and
    /// the record is unchanged. With [coldStart] the app was restarted and enrolls before any refresh, so the refusal comes
    /// after the session's opening has read the record.
    @Test(arguments: [false, true])
    func noEnrollmentWhileATransferWaitsAfterARedeem(coldStart: Bool) async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        _ = try await scanned()
        let before = m.record.value
        if coldStart { try await phone.restart() }
        let enrolls = service.enrolls.count
        let error = await vaultFailure { try await m.enroll(pin: pin) { _ in } }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(service.enrolls.count == enrolls, "no vault.enroll posted")
        // Read back from the file after a restart, as stored before it.
        #expect(m.record.value == before, "nothing written")
    }

    /// A transfer started while the enrollment awaits the enclave (before its post): the post is refused with
    /// `transfer_waiting`, nothing posted, and the enrollment's start isn't marked.
    @Test func aTransferStartedDuringTheEnrollmentRefusesItsPost() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        service.holdEnclaveReads()
        let enrolling = Task { try await m.enroll(pin: pin) { _ in } }
        #expect(await eventually { service.heldEnclaveReads > 0 })
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = 1 } // as a scan's start writes it
        service.releaseEnclaveReads()
        let error = await vaultFailure { try await enrolling.value }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(service.enrolls.isEmpty, "no vault.enroll posted")
        #expect(m.record.value.enrollStartedMs == nil)
    }

    /// The device pinned to a transfer's vault with no start stored (a redeem racing a scan wipes it): still refused.
    @Test func aPinnedTransferWithoutItsStartRefusesTheEnrollment() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        _ = try await scanned()
        #expect(m.session?.device.hasVault == true && m.session?.device.vaultID == nil)
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = nil }
        let enrolls = service.enrolls.count
        let error = await vaultFailure { try await m.enroll(pin: pin) { _ in } }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(service.enrolls.count == enrolls)
    }

    /// A stored start that nothing pinned refuses the enrollment only until the background's wait clears it.
    @Test func aLeftoverStartIsWaitedForAndThenNoLongerRefuses() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = 1 }
        let error = await vaultFailure { try await m.enroll(pin: pin) { _ in } }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(await eventually { m.record.value.transferStartedMs == nil }, "the wait cleared the start")
        try await m.enroll(pin: pin) { _ in }
        #expect(service.enrolls.count == 1)
    }

    /// The start's write leaves nothing of an earlier transfer or setup: the start alone says a transfer is under way.
    @Test func theStartClearsAnEarlierMoveAndSetup() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try m.record.update(since: m.record.generation) {
            $0.movedIn = true
            $0.setupComplete = true
            $0.finishMovePending = true
        }
        _ = try await scanned()
        let r = m.record.value
        #expect(r.transferStartedMs != nil && !r.movedIn && !r.setupComplete && !r.finishMovePending)
        #expect(!m.userGuidUsable)
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
        let unlocks = service.unlocks.count
        let r = try await m.unlock(pin: pin)
        #expect(r == .failed(.notSupported, code: UnlockAttempt.codeNoUserGuid), "\(r)")
        #expect(service.unlocks.count == unlocks, "no vault.unlock posted")
    }
}
