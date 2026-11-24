import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A transfer to this phone that is not finished opens the transfer screen again (``SetupStage/transferWaiting``), with or
/// without a redeemed setup code, and the screen takes it up (``VaultManager/transferInWaiting()``). Mirrors vettid-android
/// `TransferInResume.decide`'s `WAIT` and `DEADLINE`, and `StoppedMove.tells`.
extension VaultManagerTransferInTests {
    /// After a restart with a transfer waiting for the old phone: the move's phase, not the new vault's nor the welcome
    /// screen, and the screen gets the comparison code and the stored start back.
    @Test(arguments: [false, true])
    func aRestartWithATransferWaitingReopensTheMove(redeemed: Bool) async throws {
        defer { phone.close() }
        if redeemed { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        let sas = try await scanned()
        let started = try #require(m.transferStartedAt)
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.transferWaiting), "\(m.phase)")
        #expect(m.moveFlags.book.transferWaiter != nil, "waited for in the background meanwhile")
        let found = try await m.transferInWaiting()
        #expect(found == .waiting(sas: sas, startedAt: started), "\(String(describing: found))")
        #expect(m.moveFlags.book.transferWaiter == nil, "the screen's wait takes the background's place")
        #expect(deviceHoldsVault && pendingRecord && m.record.value.transferStartedMs != nil, "nothing dropped")
    }

    /// The screen then waits for the approval itself, and the move completes.
    @Test func theScreenTakesTheWaitOverAndTheMoveCompletes() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        #expect(try await m.transferInWaiting() != nil)
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        service.approveTransferIn()
        #expect(try await waiting.value)
        #expect(m.phase == .setup(.finishing) && m.finishMovePending && m.record.value.userGuid == service.userGuid)
    }

    /// Before any restart too: a refresh while the screen waits says the move waits.
    @Test func aRefreshWhileTheTransferWaitsSaysSo() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        _ = try await scanned()
        try await m.refresh()
        #expect(m.phase == .setup(.transferWaiting), "\(m.phase)")
    }

    /// The device pinned to a transfer's vault with no start stored (a redeem racing a scan wipes it), after a restart: the
    /// move's phase too, a start is written for it and it is waited for, so that its deadline ends it and the phone goes back
    /// to its new vault (never stuck on the move).
    @Test func aPinWithoutItsStartIsTheMovesPhaseAndEnds() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        _ = try await scanned()
        try m.record.update(since: m.record.generation) { $0.transferStartedMs = nil }
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.transferWaiting), "\(m.phase)")
        #expect(m.record.value.transferStartedMs != nil, "a start written for the pin")
        #expect(m.moveFlags.book.transferWaiter != nil, "waited for in the background")
        #expect(await deadlineWaiting())
        phone.clockAhead = 661
        phone.deadlinePauses.release()
        #expect(await eventually(within: .seconds(30)) { m.phase == .setup(.newVault) }, "\(m.phase)")
        #expect(!deviceHoldsVault && m.record.value.transferStartedMs == nil)
    }

    /// The transfer the screen took up, abandoned: the phone goes back to its redeemed code's new vault, or to the welcome
    /// screen, as before the move.
    @Test(arguments: [false, true])
    func anAbandonedTransferGoesBackAsBefore(redeemed: Bool) async throws {
        defer { phone.close() }
        if redeemed { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        #expect(try await m.transferInWaiting() != nil)
        try await m.abandonTransferIn()
        #expect(m.phase == (redeemed ? .setup(.newVault) : .signedOut), "\(m.phase)")
        #expect(!deviceHoldsVault && m.record.value.transferStartedMs == nil)
    }

    /// A transfer dropped at its deadline (nothing came in the window) while the screen waited: the phase goes back as before.
    @Test(arguments: [false, true])
    func aTransferDroppedAtItsDeadlineGoesBackAsBefore(redeemed: Bool) async throws {
        defer { phone.close() }
        if redeemed { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        #expect(try await m.transferInWaiting() != nil)
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 661
        phone.deadlinePauses.release()
        let failure = await vaultFailure { _ = try await waiting.value }
        #expect(failure?.code == VaultManager.codeTransferDeadline, "\(String(describing: failure))")
        #expect(m.phase == (redeemed ? .setup(.newVault) : .signedOut), "\(m.phase)")
    }

    /// ... and the same when the background's wait drops it (the screen never took it up).
    @Test(arguments: [false, true])
    func aTransferDroppedInTheBackgroundGoesBackAsBefore(redeemed: Bool) async throws {
        defer { phone.close() }
        if redeemed { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.transferWaiting))
        #expect(await deadlineWaiting())
        phone.clockAhead = 661
        phone.deadlinePauses.release()
        #expect(await eventually(within: .seconds(30)) { m.phase == (redeemed ? .setup(.newVault) : .signedOut) }, "\(m.phase)")
        #expect(m.record.value.transferStartedMs == nil && !pendingRecord)
    }

    /// Nothing is taken up while the phase says no transfer waits (no session is opened for it).
    @Test func nothingIsTakenUpWithoutAWaitingPhase() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.refresh()
        #expect(m.phase == .setup(.newVault))
        #expect(try await m.transferInWaiting() == nil)
    }
}

/// The texts of a refusal while a move to this phone is under way.
@Suite struct TransferWaitingTextTests {
    @Test func aRefusalForAMoveUnderWaySaysSo() {
        let text = FailureKind.enrollmentStarted.message(code: VaultManager.codeTransferWaiting, timeScale: 1)
        #expect(text == "A move from your old phone to this phone is still under way. Wait until it ends, then try again.")
        #expect(text != FailureKind.enrollmentStarted.message)
        // Any other code, and any other kind with that code, keeps its own text.
        let general = FailureKind.enrollmentStarted.message
        #expect(FailureKind.enrollmentStarted.message(code: VaultManager.codeEnrollmentStarted, timeScale: 1) == general)
        #expect(FailureKind.enrollmentStarted.message(code: nil, timeScale: 1) == FailureKind.enrollmentStarted.message)
        #expect(FailureKind.busy.message(code: VaultManager.codeTransferWaiting, timeScale: 1) == FailureKind.busy.message)
    }
}
