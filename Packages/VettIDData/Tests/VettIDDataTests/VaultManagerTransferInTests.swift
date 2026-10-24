import Foundation
import Observation
import Testing
import VettIDAltChan
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// swiftlint:disable line_length

/// A direct transfer on the new phone (VAULT-MESSAGING §6.7.1, §11.14.10) end to end: the code, the attested `hs.init`
/// with the app key and the unlock secret, the SAS, the old phone's approval, the credential, and "Finish the move".
/// Against ``FakeVaultService`` as the vault the transfer moves.
@MainActor
@Suite(.serialized) struct VaultManagerTransferInTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    /// An epoch-1 record of the transfer waits for the vault's first answer.
    var pendingRecord: Bool { (try? m.phoneSecrets.hasPending()) ?? false }
    var hasCurrentRecord: Bool { ((try? m.phoneSecrets.current()) ?? nil) != nil }
    var deviceHoldsVault: Bool { m.session?.device.hasVault ?? false }

    func code() throws -> String { try service.armTransferTarget(pin: pin, password: password) }

    /// The code scanned and the SAS shown; the approval waits for the test.
    func scanned() async throws -> String {
        service.holdsTransferApproval = true
        let sas = try await m.transferIn(code: try code())
        #expect(!sas.isEmpty)
        return sas
    }

    // MARK: - The code and the hs.init

    @Test func theHsInitCarriesTheAttestationTheAppKeyAndTheUnlockSecret() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let seen = try #require(service.transferInits.first)
        // §6.2, §6.7.1: the attestation over the challenge, this phone's app key, release R's unlock secret.
        #expect(seen.platform == "ios" && seen.keyID == phone.attester.attested.last)
        let appKey = try phone.appKeys.getOrCreate().spki()
        #expect(seen.apiKey == appKey && seen.unlockSecret?.count == 32)
        #expect(seen.ctx == service.transferInits.first?.ctx && !seen.ctx.isEmpty)
        // The account record and the phone's epoch-1 record (key_vault "") are made before anything is approved.
        #expect(m.record.value.transferIn && m.usesPhoneSecret && pendingRecord)
        #expect(m.record.value.capabilities.contains(Capabilities.recoveryR))
    }

    @Test func aCodeThatIsNotATransferCodeSendsNothing() async throws {
        defer { phone.close() }
        let wrong = await vaultFailure { _ = try await m.transferIn(code: "hello there") }
        #expect(wrong?.kind == .inviteInvalid && wrong?.code == VaultManager.codeNotTransfer)
        // A connection invitation is valid, but not a transfer's.
        let connection = try InviteQr(kind: .connection, relay: service.vaultRelay.baseURL, claimID: "abcdefghijklmnopqrstuvwxyz", hash: [UInt8](repeating: 1, count: 32), key: [UInt8](repeating: 2, count: 32), exp: UInt64(Date().timeIntervalSince1970) + 600).link()
        #expect(await vaultFailure { _ = try await m.transferIn(code: connection) }?.kind == .inviteInvalid)
        // An expired one, by this phone's clock.
        let qr = try code()
        phone.clockAhead = 3_600
        #expect(await vaultFailure { _ = try await m.transferIn(code: qr) }?.kind == .inviteExpired)
        #expect(service.transferInits.isEmpty && !m.record.value.transferIn)
    }

    @Test func aReleaseBeforeRIsRefusedBeforeAnythingIsSent() async throws {
        defer { phone.close() }
        service.capabilities = []
        let qr = try code()
        #expect(await vaultFailure { _ = try await m.transferIn(code: qr) }?.kind == .releaseTooOld)
        #expect(service.transferInits.isEmpty && !pendingRecord)
    }

    @Test func aTimeScaleThisBuildDoesNotAcceptIsRefusedBeforeAnythingIsSent() async throws {
        defer { phone.close() }
        service.timeScale = 24
        let qr = try code()
        #expect(await vaultFailure { _ = try await m.transferIn(code: qr) }?.kind == .timeScale)
        #expect(service.transferInits.isEmpty && !pendingRecord)
    }

    @Test func aPhoneThatHoldsAVaultRefusesATransfer() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        let qr = try code()
        #expect(await vaultFailure { _ = try await m.transferIn(code: qr) }?.kind == .vaultExists)
    }

    // MARK: - hs.resp (§6.7.1 step 2)

    /// A dropped `hs.init` is never answered: after 60 s the transfer is dropped and the member is told why it may be.
    @Test func noHsRespWithin60SecondsDropsTheTransfer() async throws {
        defer { phone.close() }
        service.transferIgnoresInit = true
        let qr = try code()
        let task = Task { try await m.transferIn(code: qr) }
        #expect(await eventually { phone.transferPauses.lengths == [60] })
        phone.transferPauses.release()
        let failure = await vaultFailure { _ = try await task.value }
        #expect(failure?.kind == .noResponse && failure?.code == MoveCodes.hsUnanswered)
        // Dropped: the vault, the attested key and the epoch-1 record are gone.
        let d = try #require(m.session?.device)
        #expect(!d.hasVault && d.altState.transferAttestKeyID == nil)
        #expect(phone.attester.discarded == phone.attester.attested)
        #expect(!pendingRecord && !m.usesPhoneSecret)
    }

    /// A cancelled task stops waiting for the SAS (the 60 s wait included).
    @Test func theWaitForTheSasHonoursCancellation() async throws {
        defer { phone.close() }
        service.transferIgnoresInit = true
        let qr = try code()
        let task = Task { try await m.transferIn(code: qr) }
        #expect(await eventually { phone.transferPauses.lengths == [60] })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("no error")
        } catch is CancellationError {
            // The wait ended with the task.
        }
        try await m.abandonTransferIn()
        #expect(!deviceHoldsVault && !pendingRecord)
    }

    // MARK: - The approval and the take-over

    @Test func theApprovalGivesThePhoneTheVaultAndTheMoveToFinish() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let waiting = Task { try await m.awaitTransferIn() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(m.phase != .setup(.finishing))
        service.approveTransferIn()
        #expect(try await waiting.value)
        let local = m.record.value
        #expect(local.userGuid == service.userGuid && local.vaultID == service.vaultID)
        #expect(local.finishMovePending && local.movedIn && local.enrollConfirmed && m.finishMovePending && m.movedIn)
        #expect(m.phase == .setup(.finishing) && m.usesPhoneSecret && m.session?.device.credentialVersion != nil)
        #expect(m.session?.device.altState.transferAttestKeyID == nil)
        // The key the vault bound is confirmed (IOS-PLAN §6.2).
        #expect(phone.attester.confirmed == phone.attester.attested)
        #expect(service.transferPaired)
    }

    // MARK: - The deadline (VAULT-MESSAGING §11.14.10 rule 5, owner decision 2026-10-23)

    /// The 11 minutes are one deadline counted from the start of the `hs.init`, stored with the transfer.
    @Test func theDeadlineIsStoredAndSurvivesARestart() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let started = try #require(m.record.value.transferStartedMs)
        #expect(abs(Double(started) - Date().timeIntervalSince1970 * 1000) < 10_000)
        try await phone.restart()
        #expect(m.record.value.transferStartedMs == nil || m.record.value.transferStartedMs == started)
        try await m.refresh()
        #expect(m.record.value.transferStartedMs == started)
    }

    /// A paired transfer completes at any later start, whatever its age: the app was killed between `device.paired` and the
    /// take-over.
    @Test func aPairedTransferCompletesAtALaterStart() async throws {
        defer { phone.close() }
        _ = try await scanned()
        service.approveTransferIn()
        let d = try #require(m.session?.device)
        _ = try await d.awaitTransfer(timeout: 5)
        #expect(d.deviceID != nil && !m.finishMovePending)
        try await phone.restart()
        phone.clockAhead = 86_400
        try await m.refresh()
        #expect(m.finishMovePending && m.movedIn && m.record.value.transferStartedMs == nil)
        #expect(m.record.value.userGuid == service.userGuid && m.phase == .setup(.finishing))
        #expect(m.session?.device.credentialVersion != nil && m.session?.device.transferUserGuid == nil)
    }

    /// Killed before the deadline, started after it: one collect at the start, then applied (a `device.paired` waits)...
    @Test func killedBeforeTheDeadlineAndStartedAfterItAWaitingPairedIsApplied() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        service.approveTransferIn()
        phone.clockAhead = 700
        try await m.refresh()
        #expect(m.finishMovePending && m.record.value.transferStartedMs == nil && m.phase == .setup(.finishing))
    }

    /// ... or dropped, when nothing waits.
    @Test func killedBeforeTheDeadlineAndStartedAfterItNothingWaitsDrops() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await phone.restart()
        phone.clockAhead = 700
        try await m.refresh()
        #expect(!deviceHoldsVault && !pendingRecord && m.record.value.transferStartedMs == nil)
        #expect(phone.attester.discarded == phone.attester.attested && !m.finishMovePending)
    }

    @Test func aRejectionDropsTheTransferAndTheKey() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let waiting = Task { try await m.awaitTransferIn() }
        try await Task.sleep(for: .milliseconds(100))
        service.rejectTransferIn()
        let failure = await vaultFailure { _ = try await waiting.value }
        #expect(failure?.kind == .rejected)
        #expect(!deviceHoldsVault && !m.record.value.finishMovePending && !m.movedIn)
        #expect(phone.attester.discarded == phone.attester.attested && !pendingRecord)
    }

    @Test func abandoningBeforeTheApprovalDropsEverything() async throws {
        defer { phone.close() }
        _ = try await scanned()
        try await m.abandonTransferIn()
        #expect(!deviceHoldsVault && !pendingRecord)
        #expect(phone.attester.discarded == phone.attester.attested && !m.usesPhoneSecret)
    }

    /// A vault release before 0.17.0 sends no `user_guid`: complete, but this phone cannot unlock the vault.
    @Test func aTransferWithoutUserGuidCompletesAndSaysItCannotUnlock() async throws {
        defer { phone.close() }
        service.transferWithoutUserGuid = true
        _ = try await m.transferIn(code: try code())
        #expect(try await m.awaitTransferIn() == false)
        #expect(m.record.value.userGuid.isEmpty && m.record.value.finishMovePending && m.phase == .setup(.finishing))
        let r = try await m.finishMove(pin: pin)
        #expect(r == .failed(.notSupported, code: UnlockAttempt.codeNoUserGuid))
    }

    // MARK: - Finish the move

    func transferred() async throws {
        _ = try await m.transferIn(code: try code())
        #expect(try await m.awaitTransferIn())
    }

    @Test func finishTheMoveOpensTheVaultFromStorageWithThePhonesOwnSecret() async throws {
        defer { phone.close() }
        try await transferred()
        let secret = try #require(service.transferInits.first?.unlockSecret)
        let before = service.unlocks.count
        #expect(try await m.finishMove(pin: pin) == .success)
        #expect(service.unlocks.count == before + 1 && service.unlocks.last?.unlockSecret == secret)
        // The unlock proved both writes: nothing left to finish; the secret's pending record is the current one.
        #expect(!m.finishMovePending && !m.record.value.finishMovePending && m.finishMoveFailure == nil && !m.finishingMove)
        #expect(hasCurrentRecord && !pendingRecord)
        #expect(m.rotateOffered && m.phase == .setup(.finishing))
        // The member leaves the move: onboarding ends.
        try await m.finishSetup()
        #expect(m.phase == .unlocked && !m.movedIn)
    }

    /// `transfer_incomplete`: the vault did not store the transfer; "Approve it again on your old phone".
    @Test func anUnfinishedTransferIsSaidAndStaysToFinish() async throws {
        defer { phone.close() }
        try await transferred()
        service.unlockAnswers(.sealed("transfer_incomplete"))
        let r = try await m.finishMove(pin: pin)
        #expect(r == .failed(.transferIncomplete, code: "transfer_incomplete"))
        #expect(m.finishMoveFailure == .transferIncomplete && m.finishMovePending && !m.rotateOffered)
        m.acknowledgeFinishMoveFailure()
        #expect(m.finishMoveFailure == nil)
        // It can be tried again, and finishes.
        #expect(try await m.finishMove(pin: pin) == .success)
        #expect(!m.finishMovePending && m.finishMoveFailure == nil)
    }

    @Test func aWrongPinIsNamedAndTheMoveStaysToFinish() async throws {
        defer { phone.close() }
        try await transferred()
        let r = try await m.finishMove(pin: "111111")
        if case .badPin = r {} else { Issue.record("\(r)") }
        #expect(m.finishMoveFailure == .badPin && m.finishMovePending)
    }

    /// Once asked for, the move completes: the screen that asked going away only stops waiting.
    @Test func finishTheMoveCompletesWhenTheScreenGoesAway() async throws {
        defer { phone.close() }
        try await transferred()
        let screen = Task { try await m.finishMove(pin: pin) }
        screen.cancel()
        #expect(await eventually { !m.finishMovePending && !m.finishingMove })
        #expect(m.finishMoveFailure == nil && m.rotateOffered && service.isOpen)
    }

    /// The lock and the unlock are inside the runner's own task: a caller cancelled right after the lock does not stop the
    /// unlock, and the vault opens.
    @Test func aCallerCancelledAfterTheLockStillGetsTheVaultOpened() async throws {
        defer { phone.close() }
        try await transferred()
        service.unlockAnswers(.held)
        let locks = service.memberLocks + service.relayLocks
        let sent = service.unlocks.count
        let caller = Task { try await m.finishMove(pin: pin) }
        #expect(await eventually { service.memberLocks + service.relayLocks > locks })
        caller.cancel()
        #expect(await eventually { service.unlocks.count == sent + 1 })
        service.releaseHeldUnlock()
        #expect(await eventually { !m.finishMovePending && !m.finishingMove })
        #expect(m.finishMoveFailure == nil && service.isOpen && m.rotateOffered)
    }

    /// What ``finishingMove`` was at each change of the phase (read in the change's `willSet`, so before it happens).
    @MainActor
    final class PhaseLog {
        var finishingAtChange: [Bool] = []
        var phases: [AppPhase] = []

        func watch(_ m: VaultManager) {
            withObservationTracking { _ = m.phase } onChange: { [self] in
                MainActor.assumeIsolated {
                    finishingAtChange.append(m.finishingMove)
                    phases.append(m.phase)
                    watch(m)
                }
            }
        }
    }

    /// The app holds the screen while ``finishingMove`` is true, so it must be true no later than the phase change that the
    /// run's own lock makes.
    @Test func finishingIsTrueBeforeThePhaseBecomesLocked() async throws {
        defer { phone.close() }
        try await transferred()
        let log = PhaseLog()
        log.watch(m)
        #expect(try await m.finishMove(pin: pin) == .success)
        // The lock made the phase locked; the unlock made it the open one again: both while the move was running.
        #expect(log.finishingAtChange.count >= 2 && log.finishingAtChange.allSatisfy { $0 })
        #expect(log.phases.first == .setup(.finishing) && !m.finishingMove)
    }

    /// Cleared on every exit: a failing finish (a wrong PIN, a refusal, a failure of the lock).
    @Test func finishingIsClearedWhenTheMoveFails() async throws {
        defer { phone.close() }
        try await transferred()
        let r = try await m.finishMove(pin: "111111")
        if case .badPin = r {} else { Issue.record("\(r)") }
        #expect(!m.finishingMove)
        service.unlockAnswers(.sealed("transfer_incomplete"))
        _ = try await m.finishMove(pin: pin)
        #expect(!m.finishingMove)
        // A failure of the vault's lock (the relay and the member API both refuse): thrown, and cleared all the same.
        service.memberLockAnswer = .limited(5)
        service.relayLockAnswer = .noAnswer
        _ = try? await m.finishMove(pin: pin)
        #expect(!m.finishingMove)
    }

    /// A wipe of this phone (or the vault's deletion) ends the hold at once, whatever the run still waits for.
    @Test func finishingIsClearedByAWipe() async throws {
        defer { phone.close() }
        try await transferred()
        service.unlockAnswers(.held)
        let sent = service.unlocks.count
        let run = Task { try await m.finishMove(pin: pin) }
        #expect(await eventually { m.finishingMove })
        #expect(await eventually { service.unlocks.count == sent + 1 })
        try await m.eraseThisPhone()
        #expect(m.phase == .signedOut && !m.finishingMove)
        service.releaseHeldUnlock()
        _ = try? await run.value
        #expect(!m.finishingMove)
    }

    @Test func finishingIsSaidWhileTheMoveRuns() async throws {
        defer { phone.close() }
        try await transferred()
        service.unlockAnswers(.held)
        let sent = service.unlocks.count
        let run = Task { try await m.finishMove(pin: pin) }
        #expect(await eventually { m.finishingMove })
        // The answer is held until the vault has the request.
        #expect(await eventually { service.unlocks.count == sent + 1 })
        service.releaseHeldUnlock()
        #expect(try await run.value == .success)
        #expect(!m.finishingMove)
    }

    /// A PIN taken before a change neither locks nor is sent (the runner is not reached).
    @Test func aPinTakenBeforeAChangeSendsNothing() async throws {
        defer { phone.close() }
        try await transferred()
        let old = m.pinGeneration
        m.phoneSecrets.pinMoved()
        let before = (service.unlocks.count, service.memberLocks, service.relayLocks)
        let r = try await m.finishMove(pin: pin, taken: old)
        #expect(r == .failed(.credentialUnsettled, code: VaultManager.codePinTakenBefore))
        #expect((service.unlocks.count, service.memberLocks, service.relayLocks) == before && m.finishMovePending)
    }

    /// A restart before the move is finished: the move is still to finish.
    @Test func aRestartKeepsTheMoveToFinish() async throws {
        defer { phone.close() }
        try await transferred()
        try await phone.restart()
        try await m.refresh()
        #expect(m.finishMovePending && m.movedIn && m.phase == .setup(.finishing))
        #expect(try await m.finishMove(pin: pin) == .success)
        #expect(!m.finishMovePending)
    }
}

// swiftlint:enable line_length
