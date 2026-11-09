import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A transfer scan never reuses the epoch-1 secret of an earlier attempt (VAULT-MESSAGING §6.7.1, §11.14.10 rule 5 and its
/// failure row "drops … and cannot use them"): the vault of an earlier code never learns the secret this phone presents
/// to the vault of the next. After each way an attempt ends, and with what an end can leave behind, the next scan's
/// `hs.init` carries another secret and only its own record is pending.
extension VaultManagerTransferInTests {
    /// A scan after an earlier attempt: its `hs.init` carries a secret of its own, and only its record and key are kept.
    func expectFreshSecondScan() async throws {
        phone.clockAhead = 0
        service.refusesCollect = false
        service.transferIgnoresInit = false
        service.transferRevokesFin = false
        service.holdsTransferApproval = true
        let first = try #require(service.transferInits.first?.unlockSecret)
        let sas = try await m.transferIn(code: try code())
        #expect(!sas.isEmpty)
        #expect(service.transferInits.count == 2)
        let second = try #require(service.transferInits.last?.unlockSecret)
        #expect(second != first, "the second scan sends the first scan's secret")
        let pendings = try m.phoneSecrets.records().pendings
        #expect(pendings.count == 1 && phone.phoneKeys.count == 1, "only the second key's record remains")
        #expect(m.record.value.transferEpochID == pendings.first?.keyID)
    }

    // MARK: - After each kind of drop

    @Test func afterACancelOrAnAbandonTheNextScanHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await m.abandonTransferIn()
        try await expectFreshSecondScan()
    }

    @Test func afterTheHsInitTimeoutTheNextScanHasAFreshSecret() async throws {
        defer { phone.close() }
        service.transferIgnoresInit = true
        let qr = try code()
        let task = Task { try await m.transferIn(code: qr) }
        #expect(await eventually { phone.transferPauses.lengths == [60] })
        phone.transferPauses.release()
        #expect(await vaultFailure { _ = try await task.value }?.code == MoveCodes.hsUnanswered)
        try await expectFreshSecondScan()
    }

    @Test func afterAFinRefusedForGoodTheNextScanHasAFreshSecret() async throws {
        defer { phone.close() }
        service.holdsTransferApproval = true
        service.transferRevokesFin = true
        let failure = await vaultFailure { _ = try await m.transferIn(code: try code()) }
        #expect(failure?.code == "pairing_not_completed")
        try await expectFreshSecondScan()
    }

    @Test func afterARejectionTheNextScanHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let waiting = Task { try await m.awaitTransferIn() }
        try await Task.sleep(for: .milliseconds(100))
        service.rejectTransferIn()
        #expect(await vaultFailure { _ = try await waiting.value }?.kind == .rejected)
        try await expectFreshSecondScan()
    }

    @Test func afterTheDeadlineDropTheNextScanHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 600
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        #expect(await vaultFailure { _ = try await waiting.value }?.kind == .noResponse)
        try await expectFreshSecondScan()
    }

    @Test func afterTheWindowDropTheNextScanHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil && !pendingRecord })
        try await expectFreshSecondScan()
    }

    @Test func afterAGoneMailboxTheNextScanHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 600
        m.session?.device.stop()
        service.approveTransferIn()
        service.refusesCollect = true
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        #expect(await vaultFailure { _ = try await waiting.value }?.code == VaultManager.codeTransferSessionEnded)
        // The collector was stopped above (as a background stops it); the return to the foreground starts it again, so the
        // next scan's `hs.resp` is collected.
        m.onForeground()
        try await expectFreshSecondScan()
    }

    // MARK: - A new scan over an open transfer

    @Test func aNewScanBeforeTheDeadlineOverAnOpenTransferHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        #expect(pendingRecord && deviceHoldsVault)
        try await expectFreshSecondScan()
    }

    /// The app killed after the `hs.init`, and the waiter of the transfer running when the next code is scanned.
    @Test func aNewScanAfterARestartWithTheWaiterRunningHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        #expect(m.moveFlags.book.transferWaiter != nil && pendingRecord)
        try await expectFreshSecondScan()
        #expect(m.record.value.transferStartedMs != nil, "the second scan's start is stored")
    }

    /// The background waiter failed (its error is swallowed) and left the transfer open, stored as it was; the next session
    /// (after a return to the foreground) loads it again, and its scan does not reuse the record.
    @Test func aNewScanAfterAFailedBackgroundWaiterHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        #expect(await deadlineWaiting())
        let d = try #require(m.session?.device)
        await d.halt()
        #expect(await eventually(within: .seconds(30)) { m.moveFlags.book.transferWaiter == nil })
        #expect(pendingRecord, "the failed waiter left its record")
        await m.onBackground(budget: .seconds(1))
        m.onForeground()
        try await expectFreshSecondScan()
        #expect(m.session?.device !== d)
    }

    /// An abandon after a background has no session and drops nothing: its record is still there for the next scan to find.
    @Test func aNewScanAfterAnAbandonWithNoSessionHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        await m.onBackground(budget: .seconds(1))
        #expect(m.session == nil)
        try await m.abandonTransferIn()
        #expect(pendingRecord, "nothing was dropped without a session")
        m.onForeground()
        try await expectFreshSecondScan()
    }

    // MARK: - What a drop does when a write fails

    /// The device's own save fails after its memory state was dropped: its file may still hold the open handshake, which a
    /// relaunch reloads, so its record stays. The next scan still drops it and has a secret of its own.
    @Test func anAbandonWhoseDeviceSaveFailsKeepsTheRecordAndTheNextScanIsFresh() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let id = try #require(m.record.value.transferEpochID)
        phone.deviceSaveFails.on = true
        try? await m.abandonTransferIn()
        phone.deviceSaveFails.on = false
        #expect(pendingRecord && m.record.value.transferEpochID == id)
        try await expectFreshSecondScan()
    }

    /// A scan over an open transfer whose drop cannot be saved stops before anything changes: the device file may still
    /// hold that handshake, so its record, its start and its id stay, and no second `hs.init` goes out.
    @Test func aScanOverAnOpenTransferWhoseDropCannotBeSavedChangesNothing() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let id = try #require(m.record.value.transferEpochID)
        let started = try #require(m.record.value.transferStartedMs)
        let qr = try code()
        phone.deviceSaveFails.on = true
        let failure = await vaultFailure { _ = try await m.transferIn(code: qr) }
        phone.deviceSaveFails.on = false
        #expect(failure?.code == VaultManager.codeTransferNotDropped)
        #expect(service.transferInits.count == 1, "no second hs.init")
        #expect(pendingRecord && m.record.value.transferEpochID == id && m.record.value.transferStartedMs == started)
        try await expectFreshSecondScan()
    }

    /// ... and so does a scan after an abandon whose save failed, while saves still fail: the transfer is gone from memory
    /// but still stored, and is dropped (and saved) before the next scan, or the scan stops.
    @Test func aScanWhileTheSavesStillFailAfterAFailedAbandonChangesNothing() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let id = try #require(m.record.value.transferEpochID)
        let started = try #require(m.record.value.transferStartedMs)
        phone.deviceSaveFails.on = true
        try? await m.abandonTransferIn()
        #expect(!deviceHoldsVault, "the device dropped its transfer in memory")
        let failure = await vaultFailure { _ = try await m.transferIn(code: try code()) }
        phone.deviceSaveFails.on = false
        #expect(failure?.code == VaultManager.codeTransferNotDropped)
        #expect(service.transferInits.count == 1, "no second hs.init")
        #expect(pendingRecord && m.record.value.transferEpochID == id && m.record.value.transferStartedMs == started)
        try await expectFreshSecondScan()
    }

    /// A paired transfer is never dropped, with or without a failing save: its pending record is this phone's secret.
    @Test func aPairedTransferKeepsItsRecordWhateverFails() async throws {
        defer { phone.close() }
        _ = try await scanned()
        service.approveTransferIn()
        let d = try #require(m.session?.device)
        _ = try await d.awaitTransfer(timeout: 5)
        #expect(d.deviceID != nil)
        phone.deviceSaveFails.on = true
        try? await m.abandonTransferIn()
        phone.deviceSaveFails.on = false
        #expect(pendingRecord)
    }

    /// Only the records write fails, so the device drops its transfer: the record is deleted first, and only once it is gone
    /// are the stored start and the record's id cleared. Until then they stay, and a later drop retries it.
    @Test func aRecordThatCouldNotBeDeletedKeepsTheStartAndIsRetried() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let id = try #require(m.record.value.transferEpochID)
        phone.phoneSecretsWriteFails.on = true
        try? await m.abandonTransferIn()
        phone.phoneSecretsWriteFails.on = false
        #expect(!deviceHoldsVault, "the device dropped its transfer")
        #expect(m.record.value.transferEpochID == id && m.record.value.transferStartedMs != nil)
        #expect(pendingRecord)
        try await m.abandonTransferIn()
        #expect(!pendingRecord && m.record.value.transferEpochID == nil && m.record.value.transferStartedMs == nil)
    }

    /// ... and a scan before that retry does not reuse it either.
    @Test func aNewScanAfterARecordThatCouldNotBeDeletedHasAFreshSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.phoneSecretsWriteFails.on = true
        try? await m.abandonTransferIn()
        phone.phoneSecretsWriteFails.on = false
        #expect(pendingRecord)
        try await expectFreshSecondScan()
    }

    /// Where the earlier records cannot be dropped (only the records write fails), the scan fails at that drop and nothing
    /// is sent: the earlier record is still there, and no second `hs.init` went out.
    @Test func aScanThatCannotDropTheEarlierRecordsSendsNothing() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let qr = try code()
        phone.phoneSecretsWriteFails.on = true
        let failure = await vaultFailure { _ = try await m.transferIn(code: qr) }
        phone.phoneSecretsWriteFails.on = false
        #expect(failure?.code == "phone_locked")
        #expect(service.transferInits.count == 1, "no second hs.init")
        #expect(pendingRecord, "the earlier record was not dropped")
    }

    /// The new record cannot be stored with the transfer: the scan fails, nothing is returned to send, and the record and
    /// its key are dropped at once (no later drop would find them).
    @Test func aSecretWhoseRecordIsNotNotedIsDroppedAndNotSent() async throws {
        defer { phone.close() }
        struct NotNoted: Error {}
        let fresh = FreshTransferSecret(secrets: m.phoneSecrets, policy: m.config.trust.timeScales, path: TransferPath())
        var thrown: (any Error)?
        do {
            _ = try await fresh.make([Capabilities.recoveryR], 1) { _ in throw NotNoted() }
        } catch {
            thrown = error
        }
        #expect(thrown is NotNoted, "the note's failure is thrown, and no secret is returned")
        #expect(!pendingRecord && phone.phoneKeys.count == 0)
    }
}
