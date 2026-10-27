import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// swiftlint:disable line_length

/// A direct transfer on the old phone (VAULT-MESSAGING §6.7.1, §11.14.10) end to end: the code, the approval, and the
/// keys this phone keeps until the new phone has finished the move or for 7 days (owner decisions of 2026-10-15 and
/// 2026-10-16). Against ``FakeVaultService``, which answers as vettid-vault does (a completed approval removes this phone
/// and its session, so its `device.list` goes unanswered).
@MainActor
@Suite(.serialized) struct VaultManagerTransferOutTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    let week: TimeInterval = 7 * 86_400

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
        #expect(await eventually { m.items.load == .loaded })
    }

    /// The code shown, the new phone's pending seen, and the approval with the PIN and the password.
    @discardableResult
    func approve(pin: String? = nil, signer: String? = nil) async throws -> Bool {
        let offer = try await m.transferCreate()
        service.sendTransferPending(transferID: offer.transferID)
        let pending = try await m.awaitTransferPending(transferID: offer.transferID, until: Date().addingTimeInterval(30))
        #expect(pending?.sas == "042817")
        return try await m.transferApprove(transferID: offer.transferID, pin: pin ?? self.pin, password: password, signer: signer)
    }

    func movedAwayNotice() -> Bool { m.movedAway }

    @Test func theCodeIsShownAndAnOpenOneIsReplaced() async throws {
        defer { phone.close() }
        try await setUp()
        let first = try await m.transferCreate()
        #expect(first.link.count > 40 && first.qrPayload.hasPrefix("{") && first.expiresAt > Date())
        // One transfer at a time (`exists`): the code left behind is cancelled first.
        let second = try await m.transferCreate()
        #expect(second.transferID != first.transferID && service.transfersRejected == [first.transferID] && service.transferOffers == 2)
        try await m.transferReject(transferID: second.transferID)
        #expect(service.transfersRejected == [first.transferID, second.transferID])
    }

    @Test func aCodeThatExpiredWithoutAScanHasNoPending() async throws {
        defer { phone.close() }
        try await setUp()
        let offer = try await m.transferCreate()
        #expect(try await m.awaitTransferPending(transferID: offer.transferID, until: Date().addingTimeInterval(-1)) == nil)
        // The wait ends with the time given, not with an error.
        #expect(try await m.awaitTransferPending(transferID: offer.transferID, until: Date().addingTimeInterval(0.3)) == nil)
    }

    @Test func thePendingNamesTheSignerTheVaultNamed() async throws {
        defer { phone.close() }
        try await setUp()
        let offer = try await m.transferCreate()
        service.sendTransferPending(transferID: offer.transferID, signer: "google_play", signerChanged: true)
        let p = try #require(try await m.awaitTransferPending(transferID: offer.transferID, until: Date().addingTimeInterval(30)))
        #expect(p.signer == "google_play" && p.signerChanged && p.currentSigner == nil)
    }

    // MARK: - The approval

    /// Release R: the approval keeps this phone's keys. Its time is stored with the record, the shell is told, and the
    /// phone stays unlocked and signed in.
    @Test func anApprovalOnReleaseRKeepsTheKeysUntilTheNewPhoneHasFinished() async throws {
        defer { phone.close() }
        try await setUp()
        let wiped = try await approve()
        #expect(!wiped && m.phase == .unlocked)
        #expect(service.transferApprovals.map(\.pin) == [pin] && service.transferApprovals.first?.signer == nil)
        let at = try #require(m.record.value.transferApprovedAtMs)
        #expect(abs(Double(at) - Date().timeIntervalSince1970 * 1000) < 5_000)
        #expect(m.record.value.transferKeepMs == nil)
        let since = try #require(m.transferKeptSince)
        #expect(abs(since.timeIntervalSince1970 - Double(at) / 1000) < 1)
        #expect(!m.movedAway)
    }

    /// The signer the member confirmed is sent, and only that.
    @Test func theConfirmedSignerGoesWithTheApproval() async throws {
        defer { phone.close() }
        try await setUp()
        service.transferSignerRequired = "google_play"
        _ = try await approve(signer: "google_play")
        #expect(service.transferApprovals.map(\.signer) == ["google_play"] && m.transferKeptSince != nil)
    }

    /// `signer_unconfirmed`: nothing was counted and nothing is kept; the time stored before the send is removed again.
    @Test func anUnconfirmedSignerKeepsNothing() async throws {
        defer { phone.close() }
        try await setUp()
        service.transferSignerRequired = "google_play"
        let offer = try await m.transferCreate()
        let failure = await vaultFailure { _ = try await m.transferApprove(transferID: offer.transferID, pin: pin, password: password, signer: nil) }
        #expect(failure?.code == "signer_unconfirmed")
        #expect(m.record.value.transferApprovedAtMs == nil && m.transferKeptSince == nil && service.pinFailureCount == 0)
    }

    /// The screen goes while the approval is on its way: the caller is cancelled, and what follows the vault's answer (the
    /// record, the kept state) is still done.
    @Test func aCancelledCallerStillGetsTheKeepRecorded() async throws {
        defer { phone.close() }
        try await setUp()
        let offer = try await m.transferCreate()
        service.holdMessages = true
        let caller = Task { try await m.transferApprove(transferID: offer.transferID, pin: pin, password: password, signer: nil) }
        #expect(await eventually { service.transferApprovals.count == 1 })
        caller.cancel()
        service.holdMessages = false
        _ = try? await caller.value
        #expect(await eventually { m.transferKeptSince != nil })
        #expect(m.record.value.transferApprovedAtMs != nil && m.phase == .unlocked)
    }

    /// A refusal (a wrong PIN) removes the stored time: the transfer was not approved.
    @Test func aRefusedApprovalRemovesTheStoredTime() async throws {
        defer { phone.close() }
        try await setUp()
        let offer = try await m.transferCreate()
        let failure = await vaultFailure { _ = try await m.transferApprove(transferID: offer.transferID, pin: "111111", password: password, signer: nil) }
        #expect(failure?.kind == .badPin)
        #expect(m.record.value.transferApprovedAtMs == nil && m.record.value.transferKeepMs == nil && m.transferKeptSince == nil)
        // It may be tried again.
        #expect(try await m.transferApprove(transferID: offer.transferID, pin: pin, password: password, signer: nil) == false)
        #expect(m.transferKeptSince != nil)
    }

    /// An approval whose answer never came may have reached the vault: the stored time stays, so that the keys are bounded.
    @Test func anApprovalWithoutAnAnswerKeepsTheStoredTime() async throws {
        defer { phone.close() }
        try await setUp()
        let offer = try await m.transferCreate()
        service.loseAnswers(["device.transfer.approve"])
        let failure = await vaultFailure { _ = try await m.transferApprove(transferID: offer.transferID, pin: pin, password: password, signer: nil) }
        #expect(failure?.kind == .noResponse)
        #expect(m.record.value.transferApprovedAtMs != nil)
    }

    /// A vault of a release before R answers `{}`: the transfer is complete, this phone keeps nothing, and its wipe is the
    /// `device.unlinked{transferred}` that follows.
    @Test func anEarlierReleaseKeepsNothing() async throws {
        defer { phone.close() }
        try await setUp()
        service.transferEarlierRelease = true
        _ = try await approve()
        #expect(m.record.value.transferApprovedAtMs == nil && m.transferKeptSince == nil)
        service.unlinkThisPhone(reason: "transferred")
        #expect(await eventually { m.phase == .signedOut })
        #expect(!m.movedAway)
    }

    /// STAGING-TIME-SCALE S10: the keep period is divided by the vault's time scale at the approval and stored with it.
    @Test func aScaledVaultKeepsTheKeysForTheScaledPeriod() async throws {
        let service = try FakeVaultService()
        service.timeScales = .staging
        service.timeScale = 24
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(await eventually { m.items.load == .loaded } && m.timeScale == 24)
        let offer = try await m.transferCreate()
        _ = try await m.transferApprove(transferID: offer.transferID, pin: pin, password: password, signer: nil)
        let keep: Int64 = 7 * 3_600_000
        #expect(m.record.value.transferKeepMs == keep)
        // The approval's timer has asked for its wait: the check's comes after it, not before.
        #expect(await eventually { !phone.keepPauses.lengths.isEmpty })
        // 6 hours later: kept; the timer runs for the hour left.
        phone.freezeClocks()
        phone.clockAhead = 6 * 3_600
        await m.checkKeptTransfer()
        #expect(m.transferKeptSince != nil && m.phase == .unlocked)
        #expect(await eventually { phone.keepPauses.lengths.last.map { abs($0 - 3_600) < 5 } == true })
    }

    // MARK: - The end of the keep

    /// `device.unlinked{transferred}` after the new phone's first unlock: the keys go, and the welcome screen says so.
    @Test func theTransferredNoticeAfterAnApprovalRemovesTheKeysAndSaysSo() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        service.unlinkThisPhone(reason: "transferred")
        #expect(await eventually { m.phase == .signedOut })
        #expect(await eventually { m.movedAway })
        #expect(m.transferKeptSince == nil && m.record.value.transferApprovedAtMs == nil)
        #expect(try !phone.wipeTargets.keysLeft())
        m.acknowledgeMovedAway()
        #expect(!m.movedAway)
    }

    /// The same notice without an approval of this phone's (a recovery's, say): the wipe, with no "moved away" notice.
    @Test func theTransferredNoticeWithoutAnApprovalIsAPlainWipe() async throws {
        defer { phone.close() }
        try await setUp()
        service.unlinkThisPhone(reason: "transferred")
        #expect(await eventually { m.phase == .signedOut })
        #expect(!m.movedAway)
    }

    /// The 7 days are not over: kept, and the timer runs for what is left.
    @Test func beforeSevenDaysTheKeysAreKept() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        // The approval's timer has asked for its wait: the check's comes after it, not before.
        #expect(await eventually { !phone.keepPauses.lengths.isEmpty })
        phone.freezeClocks() // the 600 s left are measured against a clock that stands still
        phone.clockAhead = week - 600
        await m.checkKeptTransfer()
        #expect(m.transferKeptSince != nil && m.phase == .unlocked && service.deviceListsAfterTransfer == 0)
        #expect(await eventually { phone.keepPauses.lengths.last.map { abs($0 - 600) < 5 } == true })
    }

    /// 7 days after the approval the vault answers with a list that does not name this phone as its app: the keys are
    /// removed (owner decision, 2026-10-23: only a definite answer erases).
    @Test func afterSevenDaysTheKeysAreRemoved() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        service.deviceListAnswer = .withoutThisPhone
        phone.clockAhead = week + 60
        await m.checkKeptTransfer()
        #expect(await eventually { m.phase == .signedOut })
        #expect(m.movedAway && !m.keptCheckPending)
        #expect(try !phone.wipeTargets.keysLeft())
    }

    /// 7 days after the approval the vault still lists this phone as its app (the transfer never took effect): the keys
    /// stay, the kept state goes and the member is told.
    @Test func afterSevenDaysAPhoneTheVaultStillListsKeepsItsKeys() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        service.transferTookEffect = false
        phone.clockAhead = week + 60
        await m.checkKeptTransfer()
        #expect(m.movedBack && m.transferKeptSince == nil && m.phase == .unlocked)
        #expect(m.record.value.transferApprovedAtMs == nil && !m.movedAway)
        m.acknowledgeMovedBack()
        #expect(!m.movedBack)
        // Not kept any more: another check does nothing.
        await m.checkKeptTransfer()
        #expect(m.transferKeptSince == nil && !m.movedBack)
    }

    /// Exactly 7 days after the approval is the end (`elapsed >= keep`): the check is made and, the vault listing this phone
    /// no more, the keys are removed.
    @Test func exactlySevenDaysAfterTheApprovalIsTheEnd() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        service.deviceListAnswer = .withoutThisPhone
        phone.clockAhead = week
        await m.checkKeptTransfer()
        #expect(await eventually { m.phase == .signedOut })
    }

    /// A clock set behind the approval never lengthens the keep: the 7 days count from the moment it is noticed, stored.
    @Test func aClockBehindTheApprovalDoesNotExtendTheKeep() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        let approved = try #require(m.record.value.transferApprovedAtMs)
        phone.clockAhead = -3 * 86_400
        await m.checkKeptTransfer()
        let stored = try #require(m.record.value.transferApprovedAtMs)
        #expect(stored < approved - 2 * 86_400 * 1_000 && m.transferKeptSince != nil && m.phase == .unlocked)
        // 6 days 23 hours after the approval by the real time: more than 7 days after the clock was noticed behind.
        service.deviceListAnswer = .withoutThisPhone
        phone.clockAhead = week - 3_600
        await m.checkKeptTransfer()
        #expect(await eventually { m.phase == .signedOut })
    }

    /// The timer fires at the end of the keep while the process lives.
    @Test func theTimerEndsTheKeepByItself() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        #expect(await eventually { !phone.keepPauses.lengths.isEmpty })
        service.deviceListAnswer = .withoutThisPhone
        phone.clockAhead = week + 60
        phone.keepPauses.release()
        #expect(await eventually { m.phase == .signedOut })
        #expect(m.movedAway)
    }

    /// A restart reads the kept transfer again: the shell is told, the 7 days still run.
    @Test func aRestartKeepsTheTransferKept() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        let at = m.record.value.transferApprovedAtMs
        try await phone.restart()
        #expect(m.transferKeptSince == nil)
        try await m.refresh()
        #expect(await eventually { m.transferKeptSince != nil })
        #expect(m.record.value.transferApprovedAtMs == at)
    }

    /// "The move didn't finish": this phone opens the vault with its own keys, so it is the vault's phone again.
    @Test func anUnlockWithItsOwnKeysAfterAnApprovalMakesItTheVaultsPhoneAgain() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        service.transferTookEffect = false
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(m.movedBack && m.transferKeptSince == nil && m.record.value.transferApprovedAtMs == nil)
        m.acknowledgeMovedBack()
        #expect(!m.movedBack)
    }

    /// A refused unlock (a wrong PIN) after the approval is not "the move didn't finish".
    @Test func aRefusedUnlockKeepsTheTransferKept() async throws {
        defer { phone.close() }
        try await setUp()
        _ = try await approve()
        service.transferTookEffect = false
        try await m.lock()
        #expect(try await m.unlock(pin: "111111") != .success)
        #expect(!m.movedBack && m.transferKeptSince != nil && m.record.value.transferApprovedAtMs != nil)
    }
}

// swiftlint:enable line_length
