import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The end of a kept transfer (VAULT-MESSAGING §11.14.10; owner decisions of 2026-10-16 and 2026-10-23): 7 days after the
/// approval a check of the vault over this phone's own session decides whether the keys go. Only an answered list that does
/// not name this phone as the vault's `app` erases (besides `device.unlinked{transferred}`); no answer (silence, the vault
/// locked, `lock_pending`, a refusal or an error, a cancellation, the background, a halt) keeps the keys, says so
/// (``VaultManager/keptCheckPending``) and is checked again. Each branch against ``FakeVaultService``, which answers nothing
/// to an old phone whose approval took effect.
@MainActor
@Suite(.serialized) final class VaultManagerKeptEndTests {
    let service: FakeVaultService
    /// The limit of the check is long; the tests of a vault's silence call ``shortLimit()`` first.
    var phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    let week: TimeInterval = 7 * 86_400

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    /// This phone waits 800 ms for the list (instead of 20 s): for the tests in which the vault never answers.
    func shortLimit() throws { phone = try TestVaultPhone(service: service, keptEndCheck: .milliseconds(800)) }

    var m: VaultManager { phone.manager }

    /// Approved, and the 7 days over by this phone's clock.
    func aged() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(await eventually { m.items.load == .loaded })
        let offer = try await m.transferCreate()
        _ = try await m.transferApprove(transferID: offer.transferID, pin: pin, password: password, signer: nil)
        #expect(m.transferKeptSince != nil)
        phone.clockAhead = week + 60
    }

    func listRequests() -> Int { service.requestsSeen.filter { $0 == "device.list" }.count }

    func expectErased() async throws {
        #expect(await eventually { m.phase == .signedOut })
        #expect(m.movedAway)
        #expect(try !phone.wipeTargets.keysLeft())
    }

    func expectKept() {
        #expect(m.phase != .signedOut && !m.movedAway && m.record.value.transferApprovedAtMs != nil)
    }

    // MARK: - What erases

    @Test func anAnsweredListWithoutThisPhoneErases() async throws {
        defer { phone.close() }
        try await aged()
        service.deviceListAnswer = .withoutThisPhone
        await m.checkKeptTransfer()
        try await expectErased()
    }

    @Test func anAnsweredListThatNamesThisPhoneAsADesktopErases() async throws {
        defer { phone.close() }
        try await aged()
        service.deviceListAnswer = .thisPhoneAsDesktop
        await m.checkKeptTransfer()
        try await expectErased()
    }

    /// `device.unlinked{transferred}` (the new phone has finished the move) erases whatever the check says.
    @Test func theTransferredNoticeErases() async throws {
        defer { phone.close() }
        try await aged()
        service.unlinkThisPhone(reason: "transferred")
        try await expectErased()
    }

    // MARK: - What does not: no definite answer (owner decision, 2026-10-23)

    /// A refusal is not the vault's list: kept, pending, checked again at the next foreground.
    @Test func aRefusalOfTheVaultKeepsTheKeysAndIsCheckedAgain() async throws {
        defer { phone.close() }
        try await aged()
        service.deviceListAnswer = .refused("forbidden")
        await m.checkKeptTransfer()
        expectKept()
        #expect(m.keptCheckPending)
        // The vault now gives a definite answer that does not name this phone: erased at the next foreground.
        service.deviceListAnswer = .withoutThisPhone
        m.onForeground()
        try await expectErased()
        #expect(!m.keptCheckPending)
    }

    /// No answer within the limit: kept, a plain notice, and checked again at each foreground until the vault answers.
    @Test func noAnswerKeepsTheKeysAndIsCheckedAgainAtTheNextForeground() async throws {
        try shortLimit()
        defer { phone.close() }
        try await aged()
        await m.checkKeptTransfer()
        expectKept()
        #expect(m.keptCheckPending && m.phase == .unlocked && service.deviceListsAfterTransfer == 1)
        m.onForeground()
        #expect(await eventually { service.deviceListsAfterTransfer == 2 })
        // Still no answer: still kept. Then the vault lists this phone as its app.
        try await Task.sleep(for: .milliseconds(1_200))
        expectKept()
        #expect(m.keptCheckPending)
        service.transferTookEffect = false
        m.onForeground()
        #expect(await eventually { m.movedBack })
        #expect(!m.keptCheckPending && m.record.value.transferApprovedAtMs == nil)
    }

    /// The vault locked on day 7 never answers: kept (not erased), and pending.
    @Test func aLockedVaultKeepsTheKeys() async throws {
        try shortLimit()
        defer { phone.close() }
        try await aged()
        try await m.lock()
        await m.checkKeptTransfer()
        try await Task.sleep(for: .milliseconds(1_200))
        expectKept()
        #expect(m.keptCheckPending)
    }

    // MARK: - What does not (F1, F2, F3, F4)

    /// The app went to the background during the wait: the wait's clock ran while it was suspended, so its limit proves
    /// nothing. Nothing is erased; the return to the foreground makes the check again.
    @Test func aCheckTheBackgroundInterruptedNeverErasesAndIsMadeAgainInTheForeground() async throws {
        try shortLimit()
        defer { phone.close() }
        try await aged()
        let check = Task { await m.checkKeptTransfer() }
        #expect(await eventually { service.deviceListsAfterTransfer == 1 })
        await m.onBackground(budget: .milliseconds(10))
        await check.value
        // Longer than the limit (800 ms in the tests): the timer would have won.
        try await Task.sleep(for: .milliseconds(1_200))
        expectKept()
        #expect(m.phase == .unlocked && !m.movedBack)
        // Back in the foreground the vault lists this phone (the approval never took effect): the check is made again.
        service.transferTookEffect = false
        // The session was dropped with the background; on a loaded machine the 800 ms of the short limit may not be enough
        // to open it again, in which case the next foreground makes the check again.
        for _ in 0..<5 {
            m.onForeground()
            if await eventually(within: .seconds(8), { m.movedBack }) { break }
        }
        #expect(m.movedBack)
        #expect(m.record.value.transferApprovedAtMs == nil && m.phase != .signedOut)
    }

    /// A check made while the app is in the background is not made at all.
    @Test func aCheckInTheBackgroundIsNotMade() async throws {
        defer { phone.close() }
        try await aged()
        await m.onBackground(budget: .milliseconds(10))
        let lists = listRequests()
        await m.checkKeptTransfer()
        try await Task.sleep(for: .milliseconds(300))
        expectKept()
        #expect(listRequests() == lists && service.deviceListsAfterTransfer == 0)
    }

    /// A halted manager (the process going away) never erases.
    @Test func aHaltedManagerNeverErases() async throws {
        try shortLimit()
        defer { phone.close() }
        try await aged()
        let check = Task { await m.checkKeptTransfer() }
        #expect(await eventually { service.deviceListsAfterTransfer == 1 })
        await m.halt()
        await check.value
        try await Task.sleep(for: .milliseconds(1_200))
        expectKept()
        #expect(try phone.wipeTargets.keysLeft())
    }

    /// A cancelled task is not "no answer".
    @Test func aCancelledCheckNeverErases() async throws {
        try shortLimit()
        defer { phone.close() }
        try await aged()
        let check = Task { await m.checkKeptTransfer() }
        #expect(await eventually { service.deviceListsAfterTransfer == 1 })
        check.cancel()
        await check.value
        try await Task.sleep(for: .milliseconds(1_200))
        expectKept()
        #expect(m.phase == .unlocked && m.keptCheckPending)
    }

    /// `lock_pending` (a lock of this phone not confirmed yet) is "not checked": nothing is sent, nothing erased, and no timer
    /// repeats it: the check is made again at the next start and foreground (VAULT-MESSAGING §11.14.10).
    @Test func aLockPendingMeansTheCheckIsMadeLater() async throws {
        defer { phone.close() }
        try await aged()
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        let lists = listRequests()
        let pauses = phone.keepPauses.lengths.count
        await m.checkKeptTransfer()
        expectKept()
        #expect(listRequests() == lists && service.deviceListsAfterTransfer == 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(phone.keepPauses.lengths.count == pauses, "no timer repeats the check")
    }

    /// The record's generation is noted before the question and read again after it (VAULT-MESSAGING §11.14.10 "Recording the
    /// check"): a lock during the check changed it, so nothing is acted on or recorded; the next foreground checks again and
    /// records it.
    @Test func aLockDuringTheCheckRecordsNothingAndTheNextCheckDoes() async throws {
        defer { phone.close() }
        try await aged()
        service.transferTookEffect = false
        service.holdMessages = true
        let lists = listRequests()
        let check = Task { await m.checkKeptTransfer() }
        #expect(await eventually { listRequests() == lists + 1 })
        // What a lock of this phone does to the record while the answer is awaited (``VaultManager/lock()``).
        let generation = m.record.generation
        m.record.bumpGeneration()
        #expect(m.record.generation != generation)
        service.holdMessages = false
        await check.value
        expectKept()
        #expect(!m.movedBack && m.keptCheckPending && m.record.value.transferApprovedAtMs != nil)
        m.onForeground()
        #expect(await eventually { m.movedBack })
        #expect(m.record.value.transferApprovedAtMs == nil && !m.keptCheckPending)
    }

    /// The transfer record's own generation: a change of the record during the check (here the keep ended meanwhile, as "The
    /// move didn't finish" does) means nothing is recorded.
    @Test func aChangeOfTheTransferRecordDuringTheCheckRecordsNothing() async throws {
        defer { phone.close() }
        try await aged()
        service.transferTookEffect = false
        service.holdMessages = true
        let lists = listRequests()
        let check = Task { await m.checkKeptTransfer() }
        #expect(await eventually { listRequests() == lists + 1 })
        _ = try m.record.update(since: m.record.generation) { $0.transferGen += 1 }
        service.holdMessages = false
        await check.value
        expectKept()
        #expect(!m.movedBack && m.record.value.transferApprovedAtMs != nil)
    }

    /// A conditional write that fails records nothing (the record is closed, its generation unchanged): the keep stays.
    @Test func aFailedWriteRecordsNothing() async throws {
        defer { phone.close() }
        try await aged()
        service.transferTookEffect = false
        service.holdMessages = true
        let lists = listRequests()
        let check = Task { await m.checkKeptTransfer() }
        #expect(await eventually { listRequests() == lists + 1 })
        m.record.markEraseFailed() // closed: the conditional write fails, the generation is unchanged
        service.holdMessages = false
        await check.value
        #expect(!m.movedBack && m.record.value.transferApprovedAtMs != nil)
    }

    /// `token_revoked` (the relay refuses a removed phone's deposits) is no answer: one `device.list` per start or
    /// foreground, never an erasure.
    @Test func aTokenRevokedIsNoAnswerAndGetsOneListPerForeground() async throws {
        defer { phone.close() }
        try await aged()
        service.revokesVaultDeposits = true
        let before = service.revokedDeposits
        await m.checkKeptTransfer()
        expectKept()
        #expect(m.keptCheckPending && service.revokedDeposits == before + 1)
        m.onForeground()
        #expect(await eventually { service.revokedDeposits == before + 2 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(service.revokedDeposits == before + 2 && m.phase != .signedOut && !m.movedAway)
    }

    /// A definite answer is only the response to this check's own request: another `re` is no answer, even a list that does
    /// not hold this phone.
    @Test func aResponseWithAnotherReIsNoAnswer() async throws {
        try shortLimit()
        defer { phone.close() }
        try await aged()
        let check = Task { await m.checkKeptTransfer() }
        #expect(await eventually { service.deviceListsAfterTransfer == 1 })
        service.sendStrayDeviceList()
        await check.value
        try await Task.sleep(for: .milliseconds(500))
        expectKept()
        #expect(m.keptCheckPending && m.phase == .unlocked)
    }

    /// The notice is sealed by the vault at delivery, with its own clock: 20 days after the approval, past the 16-day rule for
    /// a notice sealed at the approval, it still opens (§11.14.10, release L).
    @Test func aNoticeSealedAtDeliveryTwentyDaysLaterIsAccepted() async throws {
        defer { phone.close() }
        service.stampsOnVaultClock = true
        try await aged()
        let twenty: TimeInterval = 20 * 86_400
        service.advanceVaultClock(twenty)
        phone.clockAhead = twenty
        service.unlinkThisPhone(reason: "transferred")
        try await expectErased()
    }

    /// No answer after this phone's own lock (it closed the vault): kept.
    @Test func noAnswerAfterThisPhonesOwnLockIsNotAnErasure() async throws {
        try shortLimit()
        defer { phone.close() }
        try await aged()
        let check = Task { await m.checkKeptTransfer() }
        #expect(await eventually { service.deviceListsAfterTransfer == 1 })
        try await m.lock()
        await check.value
        try await Task.sleep(for: .milliseconds(1_200))
        expectKept()
    }

    /// The end of the keep is being decided: a second call while it runs does nothing (one request, one verdict).
    @Test func theCheckIsNotReenteredWhileItRuns() async throws {
        try shortLimit()
        defer { phone.close() }
        try await aged()
        let first = Task { await m.endKeptTransfer() }
        #expect(await eventually { service.deviceListsAfterTransfer == 1 })
        #expect(m.keptEnding)
        await m.endKeptTransfer()
        #expect(service.deviceListsAfterTransfer == 1)
        await first.value
        #expect(!m.keptEnding)
        expectKept()
        #expect(service.deviceListsAfterTransfer == 1)
    }

    /// The return to the foreground checks the kept transfer (after the deletion check, which returns first).
    @Test func theReturnToTheForegroundChecksTheKeptTransfer() async throws {
        defer { phone.close() }
        try await aged()
        service.transferTookEffect = false
        m.onForeground()
        #expect(await eventually { m.movedBack })
    }

    // MARK: - F5

    private func unlinked(_ reason: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: "device.unlinked", ts: Date(), body: Array(#"{"reason":"\#(reason)"}"#.utf8)))
    }

    /// `wipeMovedAway` is only ever set: another `device.unlinked` does not clear it mid-wipe.
    @Test func theMovedAwayMarkIsOnlyEverSet() async throws {
        defer { phone.close() }
        try await aged()
        m.markMovedAway(unlinked("replaced"))
        #expect(!m.wipeMovedAway)
        m.markMovedAway(unlinked("transferred"))
        #expect(m.wipeMovedAway)
        m.markMovedAway(unlinked("replaced"))
        m.markMovedAway(unlinked("vault_deleted"))
        #expect(m.wipeMovedAway)
    }
}
