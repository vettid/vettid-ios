import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// (VAULT-MESSAGING §6.7.1, 0.90.17) One `user_guid` check (1–128 printable ASCII) for every transfer answer and every
/// stored value. Mirrors vettid-android #404.
extension VaultManagerTransferInTests {
    /// (§6.7.1, 0.90.17) A transfer's `device.paired` without `transfer: true` and a valid `user_guid` (1–128 printable
    /// ASCII) is a malformed answer: the transfer is dropped before anything of it is stored or sent, and the move stopped on
    /// this phone ("The move stopped on this phone").
    @Test(arguments: MalformedTransfer.allCases)
    func aMalformedTransferAnswerDropsTheTransfer(_ form: MalformedTransfer) async throws {
        defer { phone.close() }
        form.apply(service)
        _ = try await m.transferIn(code: try code())
        let seen = service.requestsSeen.count
        let error = await vaultFailure { _ = try await m.awaitTransferIn() }
        #expect(error?.code == VaultManager.codeTransferSessionEnded, "\(String(describing: error))")
        #expect(m.session?.device.deviceID == nil, "the answer is not applied")
        #expect(!deviceHoldsVault && !m.record.value.finishMovePending && m.record.value.userGuid.isEmpty, "nothing stored")
        #expect(!service.requestsSeen.dropFirst(seen).contains("device.features"), "nothing sent")
        #expect(phone.attester.discarded == phone.attester.attested, "the attested key goes")
        #expect(!pendingRecord && m.record.value.transferStartedMs == nil, "the epoch-1 secret and the start go")
        #expect(m.phase != .setup(.finishing))
    }

    /// A malformed answer collected in the settlement window at the deadline: the move stopped ("The move stopped on this
    /// phone"), never "no response".
    @Test func aMalformedAnswerInTheWindowStopsTheMove() async throws {
        defer { phone.close() }
        service.transferWithoutUserGuid = true
        _ = try await scanned()
        phone.clockAhead = 600
        await suspendCollector()
        service.approveTransferIn()
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        let failure = await vaultFailure { _ = try await waiting.value }
        #expect(failure?.code == VaultManager.codeTransferSessionEnded, "\(String(describing: failure))")
        #expect(!deviceHoldsVault && !pendingRecord && m.record.value.transferStartedMs == nil)
        #expect(phone.attester.discarded == phone.attester.attested)
    }

    /// The device dropped a malformed `device.paired` and the app ended before anyone waited for it: the next start opens
    /// the transfer screen (``SetupStage/transferWaiting``), with or without a redeemed code, which says "The move stopped on
    /// this phone" once (``TransferInWaiting/stopped``), never a silent drop; the transfer is dropped then, and the phase
    /// goes back as before the move.
    @Test(arguments: [false, true])
    func aDropBeforeTheAppEndedIsToldAtTheNextStart(redeemed: Bool) async throws {
        defer { phone.close() }
        if redeemed { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        service.transferWithoutUserGuid = true
        _ = try await m.transferIn(code: try code())
        service.approveTransferIn()
        #expect(await eventually { m.session?.device.droppedWithoutUserGuid == true }, "dropped as it was handled")
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.transferWaiting), "\(m.phase)")
        #expect(m.moveFlags.book.transferWaiter == nil && m.transferEnd == nil, "left to the transfer screen")
        #expect(try await m.transferInWaiting() == .stopped)
        // The notice stands until the screen has shown it (a screen gone meanwhile leaves it to the welcome screen).
        #expect(m.transferEnd == .stopped)
        #expect(!deviceHoldsVault && m.record.value.transferStartedMs == nil)
        #expect(m.phase == (redeemed ? .setup(.newVault) : .signedOut), "\(m.phase)")
        #expect(try await m.transferInWaiting() == nil, "told once")
    }

    /// The same with the drop's save failing: told once in this process all the same, and the background's wait drops it
    /// later (quietly: the member was told).
    @Test func aStopWhoseDropFailsIsToldOnceAndDroppedLater() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        service.transferWithoutUserGuid = true
        _ = try await m.transferIn(code: try code())
        service.approveTransferIn()
        #expect(await eventually { m.session?.device.droppedWithoutUserGuid == true })
        try await phone.restart()
        try await m.refresh()
        let d = try #require(m.session?.device)
        let pin = d.mem.withLock { d.st.vault }
        phone.deviceSaveFails.on = true
        #expect(try await m.transferInWaiting() == .stopped)
        #expect(m.moveFlags.book.transferWaiter != nil, "the background's wait drops it")
        // Told once even while the stop still shows (here put back in memory, as a device whose drop did not take would
        // keep it).
        d.mem.withLock {
            d.st.vault = pin
            d.st.transferNoUserGuid = true
        }
        try await m.refresh()
        #expect(m.phase == .setup(.transferWaiting))
        #expect(try await m.transferInWaiting() == nil, "told once")
        d.mem.withLock {
            d.st.vault = nil
            d.st.transferNoUserGuid = nil
        }
        phone.deviceSaveFails.on = false
        phone.clockAhead = 661
        phone.deadlinePauses.holding = false
        phone.deadlinePauses.release()
        #expect(await eventually(within: .seconds(60)) { m.record.value.transferStartedMs == nil }, "\(m.phase)")
        #expect(m.transferEnd == .stopped, "the screen's notice, not another")
    }

    /// An untold stop pinned with no start stored: no start is adopted and nothing waits for it, so that the background
    /// never tells it before the transfer screen does.
    @Test func anUntoldStopWithoutItsStartIsLeftToTheScreen() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        service.transferWithoutUserGuid = true
        _ = try await m.transferIn(code: try code())
        service.approveTransferIn()
        #expect(await eventually { m.session?.device.droppedWithoutUserGuid == true })
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = nil }
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.transferWaiting), "\(m.phase)")
        #expect(m.record.value.transferStartedMs == nil && m.moveFlags.book.transferWaiter == nil)
        #expect(try await m.transferInWaiting() == .stopped)
        #expect(m.phase == .setup(.newVault), "\(m.phase)")
    }

    /// A transfer scanned after a setup code was redeemed, then abandoned: the redeemed code is kept (no new code needed),
    /// and while the transfer was under way its `user_guid` was not usable. A completed transfer writes its own.
    @Test func anAbandonedTransferKeepsARedeemedCode() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        let guid = m.record.value.userGuid
        #expect(!guid.isEmpty)
        _ = try await m.transferIn(code: try code())
        #expect(!m.userGuidUsable, "not the transfer's while it is under way")
        try await m.abandonTransferIn()
        #expect(m.record.value.userGuid == guid && m.record.value.transferStartedMs == nil)
        try await m.refresh()
        #expect(m.phase == .setup(.newVault), "\(m.phase)")
    }

    /// A moved phone whose take-over could not clear its start: the setup's completion clears it, and the phone stays usable
    /// (never the stuck notice on a working phone).
    @Test func aMovedPhoneWhoseStartStayedIsUsable() async throws {
        defer { phone.close() }
        try await transferred()
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = 1 } // as if the take-over's clear failed
        #expect(m.userGuidUsable, "moved in: usable before the setup's completion too")
        try await m.refresh()
        #expect(m.phase != .locked, "\(m.phase)")
        try await m.finishSetup()
        #expect(m.record.value.transferStartedMs == nil && m.userGuidUsable)
    }

    /// A stored `user_guid` that fails the check (a damaged record) is no `user_guid`: Finish the move and the release update
    /// refuse before their lock (`no_user_guid`), and nothing is locked or sent.
    @Test func aStoredMalformedUserGuidIsRefusedBeforeAnyLock() async throws {
        defer { phone.close() }
        try await transferred()
        try m.record.update(since: m.record.generation) { $0.userGuid = "a b" }
        #expect(!m.userGuidUsable)
        let seen = service.requestsSeen.count
        let r = try await m.finishMove(pin: pin)
        #expect(r == .failed(.notSupported, code: UnlockAttempt.codeNoUserGuid))
        #expect(try await m.lockForUnlock() == false, "\"Lock and unlock now\" locks nothing")
        let rel = { (n: UInt64, status: String) in
            ReleaseView(number: n, pcr0: String(repeating: "ab", count: 48), status: status, endsAt: nil, notes: "")
        }
        let offer = ReleaseUpdateOffer(current: rel(3, "deprecated"), target: rel(4, "active"))
        let (unlocks, locks) = (service.unlocks.count, service.memberLocks)
        #expect(m.releaseUpdate.start(pin: pin, offer: offer, generation: nil))
        await m.releaseUpdate.settle()
        #expect(service.unlocks.count == unlocks && service.memberLocks == locks, "no unlock or lock posted")
        let sent = service.requestsSeen.dropFirst(seen)
        #expect(!sent.contains("vault.lock") && !sent.contains("vault.unlock"), "\(Array(sent))")
        #expect(m.releaseUpdate.progress?.failureCode == UnlockAttempt.codeNoUserGuid)
    }

    /// (§6.7.1) A paired transfer whose record has no valid `user_guid` (a damaged one) is never completed, and the start goes
    /// on, Locked: the unlock screen then says this phone cannot open the vault (recover or erase), never "can't connect" at
    /// every start, nor "create a credential".
    @Test func aDamagedPairedRecordGoesToTheStuckNotice() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        service.approveTransferIn()
        #expect(await eventually { d.deviceID != nil })
        // The record damaged: the paired device's kept user_guid gone (nothing else runs on it now); the record holds a
        // valid one that is not the transfer's (as an earlier setup code's would be).
        d.mem.withLock { d.st.transferUserGuid = nil }
        try d.save()
        try m.record.update(since: m.record.generation) { $0.userGuid = "guid-of-a-setup-code" }
        try await phone.restart()
        let sent = service.requestsSeen.count
        let (unlocks, locks) = (service.unlocks.count, service.memberLocks)
        try await m.refresh()
        // Locked: the unlock screen's stuck notice (no PIN), whatever the vault's status (here "unlocked").
        #expect(m.phase == .locked, "\(m.phase)")
        #expect(!m.userGuidUsable && !m.record.value.movedIn, "the record's user_guid is not the transfer's")
        try await m.refresh()
        #expect(m.phase == .locked, "the same at every start")
        #expect(service.unlocks.count == unlocks && service.memberLocks == locks, "no unlock or lock posted")
        let later = Array(service.requestsSeen.dropFirst(sent))
        #expect(!later.contains("vault.unlock") && !later.contains("vault.lock") && !later.contains("credential.get"), "\(later)")
        #expect(!later.contains("vault.status"), "the guard comes before any status read: \(later)")
    }
}

/// The malformed forms of a transfer's `device.paired` (§6.7.1).
enum MalformedTransfer: CaseIterable, CustomTestStringConvertible {
    case noUserGuid, empty, tooLong, space, nonASCII, control, unflagged

    var testDescription: String { "\(self)" }

    func apply(_ s: FakeVaultService) {
        switch self {
        case .noUserGuid: s.transferWithoutUserGuid = true
        case .empty: s.transferSendsUserGuid = ""
        case .tooLong: s.transferSendsUserGuid = String(repeating: "a", count: 129)
        case .space: s.transferSendsUserGuid = "user 0001"
        case .nonASCII: s.transferSendsUserGuid = "usér-0001"
        case .control: s.transferSendsUserGuid = "user-\u{1}"
        case .unflagged: s.transferUnflagged = true
        }
    }
}
