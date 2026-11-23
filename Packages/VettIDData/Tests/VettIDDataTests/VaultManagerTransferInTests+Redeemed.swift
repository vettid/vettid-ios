import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDTesting
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
        #expect(await eventually { m.moveFlags.book.transferWaiter == nil }, "the wait ended")
        #expect(m.transferEnd == nil, "no \"timed out\" notice for a start the member already left")
        try await m.enroll(pin: pin) { _ in }
        #expect(service.enrolls.count == 1)
    }

    /// A transfer scanned while a setup code's redeem awaits the member API: the redeem is refused once its answer is in
    /// (`transfer_waiting`), and the transfer's start and pinned vault stay.
    @Test func aRedeemRacingAScanKeepsTheTransfersStart() async throws {
        defer { phone.close() }
        service.holdRedeems()
        let redeeming = Task { try await m.redeemSetupCode(.secret(service.secret)) }
        #expect(await eventually { service.heldRedeems > 0 })
        // A scan refuses while a redeem is under way; let it through, to show the redeem's last check holds alone.
        m.moveFlags.book.redeeming -= 1
        _ = try await scanned()
        m.moveFlags.book.redeeming += 1
        let started = m.record.value.transferStartedMs
        #expect(started != nil)
        service.releaseRedeems()
        let error = await vaultFailure { _ = try await redeeming.value }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(m.record.value.transferStartedMs == started, "the start kept")
        #expect(m.session?.device.hasVault == true && m.record.value.userGuid.isEmpty, "the transfer pinned, the code's guid not written")
    }

    /// The same with the scan held between its start's write and its pin (at the claim fetch): the stored start alone
    /// refuses the redeem.
    @Test func aRedeemRacingAScanBeforeItsPinKeepsTheStart() async throws {
        defer { phone.close() }
        service.holdRedeems()
        let redeeming = Task { try await m.redeemSetupCode(.secret(service.secret)) }
        #expect(await eventually { service.heldRedeems > 0 })
        let gate = FakeHTTPServer.Gate()
        service.holdsClaim = gate
        service.holdsTransferApproval = true
        let link = try code()
        m.moveFlags.book.redeeming -= 1 // as above: the scan let through
        let scan = Task { try await m.transferIn(code: link) }
        #expect(await eventually { gate.waiting > 0 && m.record.value.transferStartedMs != nil }, "held at the claim")
        m.moveFlags.book.redeeming += 1
        #expect(m.session?.device.hasVault != true, "not pinned yet")
        service.releaseRedeems()
        let error = await vaultFailure { _ = try await redeeming.value }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(m.record.value.transferStartedMs != nil, "the start kept")
        gate.open()
        _ = try? await scan.value
    }

    /// The scan first: a redeem while the scan is being made (held at its claim, its start stored, nothing pinned yet) is
    /// refused before anything is forgotten and before the code is spent; the scan goes on with its own device.
    @Test func aRedeemWhileAScanIsMadeIsRefusedBeforeSpendingTheCode() async throws {
        defer { phone.close() }
        let gate = FakeHTTPServer.Gate()
        service.holdsClaim = gate
        service.holdsTransferApproval = true
        let link = try code()
        let scan = Task { try await m.transferIn(code: link) }
        #expect(await eventually { gate.waiting > 0 && m.record.value.transferStartedMs != nil }, "held at the claim")
        let error = await vaultFailure { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(!service.api.requests.contains { $0.path == "/api/vault/enroll/redeem" }, "the code isn't spent")
        gate.open()
        let sas = try await scan.value
        #expect(!sas.isEmpty && m.session?.device.hasVault == true && pendingRecord, "the scan's device and keys kept")
    }

    /// A leftover start with no device stored (nothing pinned) is cleared by the redeem at once, as a resume clears it,
    /// and the redeem goes through.
    @Test func aLeftoverStartWithNoDeviceIsClearedByTheRedeem() async throws {
        defer { phone.close() }
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = 1 }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        #expect(m.phase == .setup(.newVault) && m.record.value.transferStartedMs == nil)
        #expect(m.moveFlags.book.transferWaiter == nil && m.transferEnd == nil, "nothing waited for")
    }

    /// The scan side: a scan while a redeem awaits the member API is refused (`transfer_waiting`), before it writes a
    /// start or makes a device; the redeem then goes through.
    @Test func aScanWhileARedeemIsUnderWayIsRefused() async throws {
        defer { phone.close() }
        service.holdRedeems()
        let redeeming = Task { try await m.redeemSetupCode(.secret(service.secret)) }
        #expect(await eventually { service.heldRedeems > 0 })
        let error = await vaultFailure { _ = try await m.transferIn(code: try code()) }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(m.record.value.transferStartedMs == nil && m.session?.device.hasVault != true)
        service.releaseRedeems()
        _ = try await redeeming.value
        #expect(m.phase == .setup(.newVault))
    }

    /// A redeem while a scan is still opening its session (held at the relay's register, before it writes its start) is
    /// refused by the scan being made alone.
    @Test func aRedeemWhileAScanOpensItsSessionIsRefused() async throws {
        defer { phone.close() }
        service.holdRegisters()
        service.holdsTransferApproval = true
        let link = try code()
        let scan = Task { try await m.transferIn(code: link) }
        #expect(await eventually { service.heldRegisters > 0 }, "held at the register")
        #expect(m.record.value.transferStartedMs == nil, "no start written yet")
        let error = await vaultFailure { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        #expect(error?.code == VaultManager.codeTransferWaiting, "\(String(describing: error))")
        #expect(!service.api.requests.contains { $0.path == "/api/vault/enroll/redeem" }, "the code isn't spent")
        service.releaseRegisters()
        _ = try? await scan.value
    }

    /// The redeem's check after its answer refuses on the pinned device alone, when the stored start is gone (the pin's
    /// own refusal, ``VaultManager/startOverRefusal(_:)``).
    @Test func theRedeemsLastCheckRefusesOnThePinAlone() async throws {
        defer { phone.close() }
        service.holdRedeems()
        let redeeming = Task { try await m.redeemSetupCode(.secret(service.secret)) }
        #expect(await eventually { service.heldRedeems > 0 })
        m.moveFlags.book.redeeming -= 1 // let a scan through, as one begun just before the redeem could be
        _ = try await scanned()
        m.moveFlags.book.redeeming += 1
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = nil }
        service.releaseRedeems()
        let error = await vaultFailure { _ = try await redeeming.value }
        #expect(error?.kind == .enrollmentStarted, "\(String(describing: error))")
        #expect(m.session?.device.hasVault == true && m.record.value.userGuid.isEmpty, "nothing wiped")
    }

    /// A pinned transfer on the current session's device, while the device given is an earlier, unpinned one (a scan
    /// replaced the session): still refused.
    @Test func aPinOnTheCurrentSessionsDeviceRefuses() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.refresh()
        let earlier = try #require(m.session?.device)
        try await m.dropSession(forget: false)
        _ = try await scanned()
        #expect(m.session?.device !== earlier && earlier.hasVault != true)
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = nil }
        m.moveFlags.book.startingIn += 1 // no start written, no waiter: the refusal alone
        defer { m.moveFlags.book.startingIn -= 1 }
        #expect(m.transferWaitingRefusal(earlier)?.code == VaultManager.codeTransferWaiting)
    }

    /// Pinned with no start stored (an older race wiped it): the refusal writes a start now, so the transfer's deadline
    /// and settlement window apply, and waits for it; the transfer isn't dropped.
    @Test func aPinnedTransferWithoutItsStartGetsOneAndIsWaitedFor() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        _ = try await scanned()
        try m.record.update(since: m.record.generation) {
            $0.transferStartedMs = nil
            $0.transferIn = false
        }
        let before = m.nowMs
        _ = await vaultFailure { try await m.enroll(pin: pin) { _ in } }
        #expect((m.record.value.transferStartedMs ?? 0) >= before, "a start written now")
        #expect(m.record.value.transferIn, "with the transfer's flag")
        #expect(m.moveFlags.book.transferWaiter != nil, "waited for")
        #expect(m.session?.device.hasVault == true, "not dropped")
    }

    /// While a scan is writing its own start, the refusal starts no waiter and writes nothing: the scan waits itself.
    @Test func noWaiterWhileAScanIsStarting() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        _ = try await scanned()
        m.moveFlags.book.transferWaiter?.cancel()
        m.moveFlags.book.transferWaiter = nil
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = nil }
        let d = try #require(m.session?.device)
        m.moveFlags.book.startingIn += 1
        defer { m.moveFlags.book.startingIn -= 1 }
        #expect(m.transferWaitingRefusal(d)?.code == VaultManager.codeTransferWaiting)
        #expect(m.moveFlags.book.transferWaiter == nil && m.record.value.transferStartedMs == nil)
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

    /// A completed transfer after a redeem ends with the transfer's `user_guid`, not the code's. (A regression test of
    /// vettid-ios#319's behaviour.)
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
    /// `vault.unlock` is sent. (A regression test of vettid-ios#319's behaviour.)
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
