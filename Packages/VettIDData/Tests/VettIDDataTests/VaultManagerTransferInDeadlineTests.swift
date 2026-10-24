import Foundation
import Testing
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

    /// A collect that fails drops at once: no reason to keep the keys longer.
    @Test func aFailedCollectDropsEvenWithAnApprovalWaiting() async throws {
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
        #expect(failure?.kind == .noResponse && !deviceHoldsVault && !pendingRecord)
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
        #expect(await eventually { m.record.value.transferStartedMs == nil && !pendingRecord })
        #expect(phone.attester.discarded == phone.attester.attested)
    }
}
