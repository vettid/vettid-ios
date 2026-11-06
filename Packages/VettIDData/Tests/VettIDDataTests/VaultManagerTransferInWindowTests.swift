import Foundation
import Testing
import VettIDRelay
@testable import VettIDData
import VettIDDataTesting
import VettIDTesting
@testable import VettIDVault

/// The settlement window of a transfer to this phone (VAULT-MESSAGING 0.85.2 §11.14.10 rule 5, owner decisions a and a/a
/// of 2026-11-05): the window of collects past the deadline, its ends, and a background or a suspension during it.
extension VaultManagerTransferInTests {
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

    /// Back in the foreground during the window, its end moves out to now + V (within the cap): a suspended app's collects
    /// were cut, and their leases may still run. 50 s in, 60 s are left.
    @Test func aReturnToTheForegroundMovesTheEndOut() async throws {
        defer { phone.close() }
        try await windowOnFrozenClocks()
        try await advance(50)
        // A return to the foreground alone (no background before it) changes nothing, over a few rounds of the window.
        m.onForeground()
        try await Task.sleep(for: .milliseconds(300))
        #expect(phone.windowPauses.lengths == [90])
        await m.onBackground(budget: .seconds(1))
        m.onForeground()
        #expect(await eventually { phone.windowPauses.lengths == [90, 60] }, "\(phone.windowPauses.lengths)")
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
        let device = try #require(m.session?.device)
        service.leasesCollected = 0.3
        await m.onBackground(budget: .seconds(1))
        m.onForeground()
        service.approveTransferIn()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        #expect(m.transferEnd == nil)
        // One device per transfer: the session after the move is the transfer's own, taken back, not a second device.
        #expect(m.session?.device === device)
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

    /// A window that started with the app in the background (the deadline came after it went) decides nothing until the
    /// app is back, then moves its end out to now + V: its timer may have ended while the app was suspended.
    @Test func aWindowStartedInTheBackgroundRunsAgainInTheForeground() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        await m.onBackground(budget: .seconds(1))
        try await m.refresh()
        #expect(await eventually { phone.windowPauses.lengths == [90] }, "the window runs")
        phone.freezeClocks()
        try await advance(90)
        phone.windowPauses.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(m.record.value.transferStartedMs != nil, "nothing decided in the background")
        m.onForeground()
        #expect(await eventually { phone.windowPauses.lengths == [90, 60] }, "\(phone.windowPauses.lengths)")
        phone.windowPauses.release()
    }

    /// The window's device applied the pairing while a newer session exists (opened from the same stored state): the
    /// newer device is halted (it would save its stale state back), the session is loaded again, and the move completes.
    @Test func aPairingOnTheWindowsDeviceReloadsANewerSession() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.windowPauses.holding = true
        phone.clockAhead = 700
        try await m.refresh()
        #expect(await eventually { !phone.windowPauses.lengths.isEmpty }, "the window runs")
        // A newer session beside the window's, the transfer's own still held: its device does not collect. The window's
        // collector stops with its long poll perhaps held at the relay: what that takes is leased, as a relay does, and
        // reappears.
        service.leasesCollected = 0.3
        let windowDevice = try #require(m.session?.device)
        m.stopCollecting()
        let held = m.moveFlags.book.transferSession
        m.moveFlags.book.transferSession = nil
        let newer = try await m.openSession().device
        m.moveFlags.book.transferSession = held
        newer.stop()
        service.approveTransferIn()
        #expect(await eventually(within: .seconds(30)) { m.finishMovePending && m.record.value.transferStartedMs == nil })
        #expect(newer.ended, "the newer device is halted")
        // Loaded again: a device of its own (neither the newer one nor the window's, which is halted), knowing the pairing.
        let now = try #require(m.session?.device)
        #expect(now !== newer && now !== windowDevice && !now.ended && now.deviceID != nil)
        phone.windowPauses.release()
    }

    /// A new code from minute 10 with nothing waiting for the transfer (the screen went): refused, and the transfer is then
    /// waited for, so that its end lets a new code in.
    @Test func aRefusedCodeStartsTheWaitForTheTransfer() async throws {
        defer { phone.close() }
        _ = try await scanned()
        #expect(m.moveFlags.book.transferWaiter == nil)
        phone.clockAhead = 610
        let attempt = Attempt()
        let task = Task { @MainActor in attempt.failure = await vaultFailure { _ = try await m.transferIn(code: try code()) } }
        #expect(await eventually(within: .seconds(5)) { attempt.failure != nil }, "refused at once")
        task.cancel()
        #expect(attempt.failure?.code == VaultManager.codeTransferWaiting && m.moveFlags.book.transferWaiter != nil)
    }

    /// A start that no transfer pinned (killed before the handshake was saved): the next start clears it, and a new code is
    /// not refused for it.
    @Test func aStartThatNothingPinnedIsClearedAtTheNextStart() async throws {
        defer { phone.close() }
        try m.record.update(since: m.record.generation) {
            $0.transferIn = true
            $0.transferStartedMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
        try await phone.restart()
        phone.clockAhead = 610
        try await m.refresh()
        #expect(await eventually { m.record.value.transferStartedMs == nil }, "the stale start goes")
        #expect(!m.abandonClosed)
    }

    /// What a transfer started in a task of its own ended with.
    @MainActor
    final class Attempt {
        var failure: VaultFailure?
    }

    /// A refresh while a scan is being made (its claim fetched, its handshake not saved yet) is no restart: the start and,
    /// once the scan goes on, its epoch-1 record stay.
    @Test func aRefreshWhileTheScanIsMadeKeepsItsStart() async throws {
        defer { phone.close() }
        let gate = FakeHTTPServer.Gate()
        service.holdsClaim = gate
        service.holdsTransferApproval = true
        let link = try code()
        let scan = Task { try await m.transferIn(code: link) }
        #expect(await eventually { gate.waiting > 0 && m.record.value.transferStartedMs != nil }, "held at the claim")
        try await m.refresh()
        #expect(m.record.value.transferStartedMs != nil, "the start is kept")
        gate.open()
        let sas = try await scan.value
        #expect(!sas.isEmpty && m.record.value.transferStartedMs != nil && pendingRecord)
    }

    /// A pairing that a long poll holds out at the relay when the phone is wiped is not acted on: nothing is confirmed or
    /// taken over, and the transfer ends as its session did.
    @Test func aPairingHeldOutAtTheWipeIsNotApplied() async throws {
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
        let gate = FakeHTTPServer.Gate()
        service.holdsCollectAnswers = gate
        // It answers after the wipe began and before the device is forgotten: when the wipe deletes the mailbox.
        service.opensHeldCollectsAtMailboxDelete = true
        service.approveTransferIn()
        #expect(await eventually { gate.waiting > 0 }, "a long poll holds the pairing")
        let confirmed = phone.attester.confirmed
        try await m.eraseThisPhone()
        gate.open()
        let attempt = Attempt()
        let task = Task { @MainActor in attempt.failure = await vaultFailure { _ = try await waiting.value } }
        #expect(await eventually(within: .seconds(10)) { attempt.failure != nil }, "the window ended")
        task.cancel()
        #expect(attempt.failure?.code == VaultManager.codeTransferSessionEnded, "\(String(describing: attempt.failure))")
        #expect(phone.attester.confirmed == confirmed && !service.requestsSeen.contains("credential.get"))
        #expect(m.phase == .signedOut && !m.finishMovePending)
        phone.windowPauses.release()
    }

    /// A scan in this process does not use up its one resume: a later refresh still resumes the transfer it left (it is
    /// then waited for in the background).
    @Test func aRefreshAfterAScanStillResumes() async throws {
        defer { phone.close() }
        _ = try await scanned()
        #expect(m.moveFlags.book.transferWaiter == nil, "nothing waits for it yet (no screen here)")
        try await m.refresh()
        #expect(m.moveFlags.book.transferWaiter != nil, "the refresh resumed it")
    }
}
