import Foundation
import Testing
import VettIDRelay
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The new phone's deadline and the end of a transfer (VAULT-MESSAGING §11.14.10 rule 5, owner decision 2026-10-23); the
/// deadline's wait and the 30 s limit of the collect are pauses the test releases (``TestVaultPhone/deadlinePauses``).
extension VaultManagerTransferInTests {
    /// Waits until the transfer's wait for the deadline has begun (its pause is asked for).
    func deadlineWaiting(_ n: Int = 1) async -> Bool {
        await eventually { phone.deadlinePauses.lengths.count >= n }
    }

    /// A `device.paired` at 10 minutes 30 seconds is accepted.
    @Test func anApprovalAtTenMinutesThirtyIsAccepted() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 630
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        #expect(phone.deadlinePauses.lengths.first.map { $0 > 20 && $0 <= 30 } == true)
        service.approveTransferIn()
        #expect(try await waiting.value)
        #expect(m.finishMovePending && m.record.value.transferStartedMs == nil)
    }

    /// Nothing is dropped before the 11 minutes.
    @Test func nothingIsDroppedBeforeElevenMinutes() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 600
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        #expect(deviceHoldsVault && pendingRecord && m.record.value.transferStartedMs != nil && phone.attester.discarded.isEmpty)
        service.approveTransferIn()
        #expect(try await waiting.value)
    }

    /// At the deadline a waiting `device.paired` is applied (the collector is not running: one collect finds it).
    @Test func atTheDeadlineAWaitingPairedIsApplied() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 600
        m.session?.device.stop()
        service.approveTransferIn()
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        #expect(try await waiting.value)
        #expect(m.finishMovePending && deviceHoldsVault && m.record.value.userGuid == service.userGuid)
    }

    /// Nothing waits at the deadline: dropped, the key discarded, the epoch-1 secret deleted, and a new code is offered.
    @Test func atTheDeadlineNothingWaitsAndTheTransferIsDropped() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 600
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        let failure = await vaultFailure { _ = try await waiting.value }
        #expect(failure?.kind == .noResponse)
        #expect(!deviceHoldsVault && !pendingRecord && m.record.value.transferStartedMs == nil)
        #expect(phone.attester.discarded == phone.attester.attested)
    }

    /// The mailbox gone (`mailbox_unknown`) at the deadline: the session ended, reported as ended (not as a drop), and the
    /// keys go: no reason to keep them longer.
    @Test func aGoneMailboxEndsTheSessionEvenWithAnApprovalWaiting() async throws {
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
        let failure = await vaultFailure { _ = try await waiting.value }
        #expect(failure?.code == VaultManager.codeTransferSessionEnded && !deviceHoldsVault && !pendingRecord)
    }

    /// No user action extends the deadline: asking again, or leaving and coming back, keeps the stored moment.
    @Test func noUserActionExtendsTheDeadline() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let started = m.record.value.transferStartedMs
        let first = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        first.cancel()
        _ = try? await first.value
        phone.clockAhead = 600
        let second = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting(2))
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        let failure = await vaultFailure { _ = try await second.value }
        #expect(failure?.kind == .noResponse && started != nil)
    }

    /// M4: a failure of the wait before the deadline collects nothing and drops nothing: the transfer is kept.
    @Test func aFailureBeforeTheDeadlineKeepsTheTransfer() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        await d.halt()
        let failure = await vaultFailure { _ = try await waiting.value }
        #expect(failure != nil || phone.attester.discarded.isEmpty)
        #expect(m.record.value.transferStartedMs != nil && deviceHoldsVault && pendingRecord && phone.attester.discarded.isEmpty)
        #expect(phone.collectPauses.lengths.isEmpty)
    }

    /// H1: abandoning once the transfer is paired (the approval came while the SAS was compared) completes it; the
    /// phone's secret and its attested key stay.
    @Test func abandoningAPairedTransferKeepsTheSecretAndCompletes() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        service.approveTransferIn()
        #expect(await eventually { d.deviceID != nil })
        try await m.abandonTransferIn()
        #expect(pendingRecord && phone.attester.discarded.isEmpty && deviceHoldsVault)
        #expect(m.finishMovePending && m.phase == .setup(.finishing))
        #expect(try await m.finishMove(pin: pin) == .success)
        #expect(hasCurrentRecord)
    }

    /// H2: a `device.paired` that was acked is applied as it is handled: a restart without anything awaiting it loses nothing.
    @Test func anAckedPairedIsNotLostAtARestart() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        service.approveTransferIn()
        #expect(await eventually { d.deviceID != nil })
        try await phone.restart()
        phone.clockAhead = 700
        try await m.refresh()
        #expect(m.finishMovePending && m.movedIn && m.phase == .setup(.finishing))
        #expect(m.record.value.userGuid == service.userGuid && phone.attester.discarded.isEmpty)
    }

    /// M2 and the deadline race: a start's resume and a refresh at once complete the take-over once.
    @Test func theDeadlineRaceCompletesTheTakeOverOnce() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        service.approveTransferIn()
        phone.clockAhead = 700
        let first = Task { try await m.refresh() }
        let second = Task { try await m.refresh() }
        try await first.value
        try await second.value
        _ = await eventually(within: .seconds(30)) { m.finishMovePending && m.phase == .setup(.finishing) }
        #expect(m.finishMovePending && m.phase == .setup(.finishing) && phone.attester.discarded.isEmpty)
        #expect(service.requestsSeen.filter { $0 == "credential.get" }.count == 1)
    }

    /// M3: a start before the deadline waits for the rest of it in the background (the welcome screen stays; enrollment is
    /// refused meanwhile), and the approval then completes the transfer.
    @Test func aStartBeforeTheDeadlineKeepsWaiting() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .signedOut && m.moveFlags.book.transferWaiter != nil)
        #expect(await vaultFailure { _ = try await m.redeemSetupCode(.secret(service.secret)) } != nil)
        service.approveTransferIn()
        #expect(await eventually { m.phase == .setup(.finishing) })
        #expect(m.finishMovePending && m.record.value.transferStartedMs == nil)
    }

    /// M3: ... and drops it at the deadline when nothing came.
    @Test func aStartBeforeTheDeadlineDropsItAtTheDeadline() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        #expect(await deadlineWaiting())
        phone.clockAhead = 661
        phone.deadlinePauses.release()
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil && !pendingRecord })
        #expect(phone.attester.discarded == phone.attester.attested)
    }
}

/// A take-over that failed, and what a waiting move says to enrollment.
extension VaultManagerTransferInTests {
    /// A paired transfer whose take-over failed (the network): the retried wait does not wait for the consumed
    /// `device.paired`; it takes over again and completes.
    @Test func aFailedTakeOverIsRetriedWithoutWaitingForThePairedAgain() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        service.refuse("credential.get", with: "forbidden", times: 1)
        service.approveTransferIn()
        #expect(await eventually { d.deviceID != nil })
        _ = await vaultFailure { _ = try await m.awaitTransferIn() }
        #expect(m.record.value.transferStartedMs != nil)
        #expect(try await m.awaitTransferIn())
        #expect(m.finishMovePending && m.record.value.transferStartedMs == nil && m.phase == .setup(.finishing))
        #expect(phone.deadlinePauses.lengths.isEmpty || m.phase == .setup(.finishing))
    }

    /// ... and an evaluation of a paired transfer whose take-over is still to do retries it, never "create a credential".
    @Test func aPairedTransferWithoutItsTakeOverIsNeverNeedsCredential() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let d = try #require(m.session?.device)
        service.refuse("credential.get", with: "forbidden", times: 1)
        service.approveTransferIn()
        #expect(await eventually { d.deviceID != nil })
        try await phone.restart()
        _ = try? await m.refresh()
        #expect(m.phase != .setup(.needsCredential) && m.record.value.transferStartedMs != nil)
        try await m.refresh()
        #expect(m.phase == .setup(.finishing) && m.finishMovePending && m.record.value.transferStartedMs == nil)
    }

    /// Enrollment while a move is under way is refused with its own code.
    @Test func enrollmentWhileAMoveWaitsIsRefusedAsAMoveUnderWay() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        try await m.refresh()
        let refusal = await vaultFailure { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        #expect(refusal?.kind == .enrollmentStarted && refusal?.code == VaultManager.codeTransferWaiting)
    }

    // MARK: - The window of collects before the drop (§11.14.10 rule 5, owner decision 2026-11-05)

    /// A start past the deadline does not wait for the window: the welcome screen shows, the transfer stays pinned, and a
    /// `device.paired` that comes during the window is applied.
    @Test func aStartPastTheDeadlineDoesNotWaitForTheWindow() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(m.record.value.transferStartedMs != nil && !m.finishMovePending, "still waiting, not dropped")
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        service.approveTransferIn()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        // The relay's visibility timeout (60 s), the long-poll cap and a margin.
        #expect(phone.windowPauses.lengths == [90] && VaultManager.settleWindow(visibility: 60) == 90)
        // No collect of the window is bounded below the transport's own long-poll timeout: none is ever cut while out.
        let bounds = phone.collectPauses.lengths
        #expect(!bounds.isEmpty && bounds.allSatisfy { $0 >= 70 }, "\(bounds)")
        phone.windowPauses.release()
    }

    /// A collect that fails during the window is tried again, and the `device.paired` it then brings is applied.
    @Test func aFailedCollectInTheWindowIsTriedAgain() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        // Only the window collects: a failure is its own to retry. The stopped collector's long poll may be held at the
        // relay: what it takes is leased, as a relay does, and reappears.
        service.leasesCollected = 0.3
        m.session?.device.stop()
        service.failNextCollects(RelayClient.defaultAttempts + 1)
        service.approveTransferIn()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        #expect(service.collectFailuresLeft == 0, "the window met the failure, and tried again")
        phone.windowPauses.release()
    }

    /// The window ends without a `device.paired`: dropped, the key discarded and the epoch-1 secret deleted.
    @Test func theWindowEndsWithNothingAndTheTransferIsDropped() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty })
        #expect(m.record.value.transferStartedMs != nil, "kept while the window runs")
        #expect(m.transferEnd == nil, "not told while the window runs")
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil })
        #expect(!deviceHoldsVault && !pendingRecord && !m.finishMovePending)
        // Nobody is on the transfer screen: the welcome screen says the move didn't finish, until it is seen.
        #expect(await eventually(within: .seconds(30)) { m.transferEnd == .timedOut })
        m.acknowledgeTransferEnd()
        #expect(m.transferEnd == nil)
    }

    /// No abandon during the window (§11.14.10 rule 5): it is refused, and the transfer waits for the window's end.
    @Test func noAbandonDuringTheWindow() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty })
        let refused = await vaultFailure { try await m.abandonTransferIn() }
        #expect(refused?.code == VaultManager.codeTransferWaiting)
        #expect(m.record.value.transferStartedMs != nil && deviceHoldsVault && pendingRecord, "kept for the window")
        phone.windowPauses.release()
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil })
    }

    /// Nor from the end of the vault's 10 minutes, before the deadline: an approval may just have reached the vault.
    @Test func noAbandonFromTheVaultsTenMinutes() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 610
        let refused = await vaultFailure { try await m.abandonTransferIn() }
        #expect(refused?.code == VaultManager.codeTransferWaiting)
        #expect(m.record.value.transferStartedMs != nil && deviceHoldsVault && pendingRecord)
    }

    /// A new code during the window is refused (one window at a time): the old window's drop must never take a new
    /// transfer's keys with it.
    @Test func aNewCodeDuringTheWindowIsRefused() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty })
        phone.clockAhead = 0
        // Refused at once, before anything is sent (a transfer that went on would wait for its `hs.resp`).
        let attempt = Attempt()
        let task = Task { @MainActor in attempt.failure = await vaultFailure { _ = try await m.transferIn(code: try code()) } }
        #expect(await eventually(within: .seconds(5)) { attempt.failure != nil }, "refused at once")
        task.cancel()
        let refused = attempt.failure
        #expect(refused?.kind == .enrollmentStarted && refused?.code == VaultManager.codeTransferWaiting)
        #expect(service.transferInits.count == 1, "nothing sent for the new code")
        phone.windowPauses.release()
    }

    /// A session that ends during the window (`mailbox_unknown`) is reported as ended, never as dropped, also on the
    /// welcome screen.
    @Test func anEndedSessionInTheWindowIsReportedAsEnded() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        service.refusesCollect = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually(within: .seconds(30)) { m.transferEnd == .stopped })
        #expect(m.record.value.transferStartedMs == nil && !deviceHoldsVault, "its dead handshake goes")
        phone.windowPauses.release()
    }

    /// Back in the foreground during the window, a full window runs again: a suspended app's collects were cut, and their
    /// leases may still run.
    @Test func aReturnToTheForegroundRunsAFullWindowAgain() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { phone.windowPauses.lengths == [90] })
        // A return to the foreground alone (no background before it) changes nothing, over a few rounds of the window.
        m.onForeground()
        try await Task.sleep(for: .milliseconds(300))
        #expect(phone.windowPauses.lengths == [90])
        await m.onBackground(budget: .seconds(1))
        m.onForeground()
        #expect(await eventually { phone.windowPauses.lengths == [90, 90] }, "\(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }

    /// A background and a return to the foreground before the deadline (the session ends with the background) lose nothing:
    /// an approval waiting is applied at the deadline.
    @Test func aBackgroundBeforeTheDeadlineKeepsTheMove() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.clockAhead = 300
        try await m.refresh()
        #expect(await deadlineWaiting())
        // The background stops the collector while its long poll may be held at the relay: what it takes is leased, as a
        // relay does, and reappears within the window.
        service.leasesCollected = 0.3
        phone.windowPauses.holding = true
        await m.onBackground(budget: .seconds(1))
        m.onForeground()
        service.approveTransferIn()
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        #expect(m.transferEnd == nil)
        phone.windowPauses.release()
    }

    /// The same during the window.
    @Test func aBackgroundDuringTheWindowKeepsTheMove() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        service.leasesCollected = 0.3
        await m.onBackground(budget: .seconds(1))
        m.onForeground()
        service.approveTransferIn()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        #expect(m.transferEnd == nil)
        phone.windowPauses.release()
    }

    /// A wipe during the window ends the transfer's session: reported as ended (the screen's "The move stopped on this
    /// phone"), never as timed out.
    @Test func aWipeDuringTheWindowEndsAsStopped() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 600
        m.session?.device.stop()
        phone.windowPauses.holding = true
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        try await m.eraseThisPhone()
        let attempt = Attempt()
        let task = Task { @MainActor in attempt.failure = await vaultFailure { _ = try await waiting.value } }
        #expect(await eventually(within: .seconds(10)) { attempt.failure != nil }, "the window ended")
        task.cancel()
        waiting.cancel()
        #expect(attempt.failure?.code == VaultManager.codeTransferSessionEnded, "\(String(describing: attempt.failure))")
        phone.windowPauses.release()
    }

    /// No new code from the end of the vault's 10 minutes, after the screen that waited went: it would abandon the
    /// transfer waiting (§11.14.10 rule 5).
    @Test func aNewCodeFromTheVaultsTenMinutesIsRefused() async throws {
        defer { phone.close() }
        _ = try await scanned()
        m.waitForTransferInBackground()
        phone.clockAhead = 610
        let attempt = Attempt()
        let task = Task { @MainActor in attempt.failure = await vaultFailure { _ = try await m.transferIn(code: try code()) } }
        #expect(await eventually(within: .seconds(5)) { attempt.failure != nil }, "refused at once")
        task.cancel()
        #expect(attempt.failure?.code == VaultManager.codeTransferWaiting && service.transferInits.count == 1)
        #expect(m.moveFlags.book.transferWaiter != nil, "the background wait goes on")
    }

    /// An abandon from the end of the vault's 10 minutes is refused also without a session (a background ended it), and
    /// the transfer is then waited for in the background.
    @Test func anAbandonWithoutASessionIsRefusedToo() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 610
        await m.onBackground(budget: .seconds(1))
        #expect(m.session == nil)
        let refused = await vaultFailure { try await m.abandonTransferIn() }
        #expect(refused?.code == VaultManager.codeTransferWaiting)
        #expect(m.moveFlags.book.transferWaiter != nil && m.record.value.transferStartedMs != nil)
    }

    /// A rejection during the window drops at once, without waiting for its end.
    @Test func aRejectionInTheWindowDropsAtOnce() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty })
        service.rejectTransferIn()
        #expect(await eventually(within: .seconds(30)) { m.record.value.transferStartedMs == nil })
        #expect(!deviceHoldsVault && !m.finishMovePending)
        // The welcome screen says the move was declined.
        #expect(await eventually(within: .seconds(30)) { m.transferEnd == .declined })
        phone.windowPauses.release()
    }

    /// A rejection that comes during the running app's window ends as a rejection, not as a drop at the deadline.
    @Test func aRejectionInTheRunningAppsWindowIsARejection() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 600
        m.session?.device.stop()
        phone.windowPauses.holding = true
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        service.rejectTransferIn()
        let failure = await vaultFailure { _ = try await waiting.value }
        #expect(failure?.kind == .rejected && !deviceHoldsVault && !pendingRecord)
        phone.windowPauses.release()
    }

    /// The window is the manager's: the screen that waited going away does not cut it, and an approval that comes later in
    /// it is still applied.
    @Test func aScreenThatGoesAwayDoesNotCutTheWindow() async throws {
        defer { phone.close() }
        _ = try await scanned()
        phone.clockAhead = 600
        m.session?.device.stop()
        phone.windowPauses.holding = true
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        waiting.cancel()
        service.approveTransferIn()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        phone.windowPauses.release()
    }

    /// The process ending during the window decides nothing: the transfer stays for the next process, which runs its own
    /// window, and no notice is set.
    @Test func theProcessEndingDuringTheWindowKeepsTheTransfer() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        let old = m
        try await phone.restart()
        #expect(old.transferEnd == nil, "nothing told")
        // The next process starts its own window, the transfer still there.
        try await m.refresh()
        #expect(m.record.value.transferStartedMs != nil, "kept for the next process")
        #expect(deviceHoldsVault, "the pinned vault kept")
        #expect(pendingRecord, "the epoch-1 secret kept")
        phone.windowPauses.release()
    }

    /// What a transfer started in a task of its own ended with.
    @MainActor
    final class Attempt {
        var failure: VaultFailure?
    }
}
