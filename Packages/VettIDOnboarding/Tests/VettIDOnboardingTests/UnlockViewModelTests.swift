import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The countdowns' seconds, moved on only by the test (kotlinx-coroutines-test's virtual time).
@MainActor
final class ManualTicker {
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    var tick: @Sendable () async throws -> Void {
        { [weak self] in try await self?.wait() }
    }

    private func wait() async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    /// [seconds] pass, one at a time, with what each one starts run.
    func advance(_ seconds: Int, _ vm: UnlockViewModel) async {
        for _ in 0..<seconds {
            await vm.settle()
            let w = waiters
            waiters = []
            for c in w { c.resume() }
            await vm.settle()
        }
    }
}

/// Mirrors vettid-android `UnlockViewModelTest`, test for test (What's new comes with I1.8; the owner check's own
/// repository with I1.7b, so its state is set here as that repository will).
@MainActor
@Suite struct UnlockViewModelTests {
    let vault = FakeVaultRepository(.locked)
    let ticker = ManualTicker()

    func vm() async -> UnlockViewModel {
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick)
        await vm.settle()
        return vm
    }

    func submit(_ vm: UnlockViewModel, _ pin: String = "40281795") async {
        vm.setPin(pin)
        vm.submit()
        await vm.settle()
    }

    @Test func unlocksWithThePin() async {
        let vm = await vm()
        #expect(vm.state.pinAllowed)
        vm.setPin("4028 1795")
        #expect(vm.state.pin == "40281795")
        vm.submit()
        await vm.settle()
        #expect(vault.phase == .unlocked && vm.state.pin.isEmpty && vault.lastApproved == nil)
    }

    /// Release R (§11.14.10): on the old phone after a transfer's approval, an unlock its own keys cannot make is "The move
    /// didn't finish" failing; a network failure is said as that.
    @Test func theMoveBackFailingSaysContactVettId() async {
        vault.transferKeptSince = FakeVaultRepository.date("2026-10-16T10:00:00Z")
        let vm = await vm()
        #expect(vm.state.keptTransfer)
        vault.unlockResults = [.failed(.deviceSecret, code: "device_secret")]
        await submit(vm)
        #expect(vm.state.message == .moveBackFailed)
        vault.unlockResults = [.failed(.network, code: nil)]
        await submit(vm)
        #expect(vm.state.message == .failed(.network, code: nil))
        let usual = UnlockMessage.of(.deviceSecret, code: "device_secret", keptTransfer: false)
        #expect(usual == .failed(.deviceSecret, code: "device_secret"))
    }

    /// A locked vault past its owner-check deadline: PIN and password on one screen, the check after the unlock (§3.6.5).
    @Test func pastTheDeadlineAsksForThePasswordWithThePin() async {
        let vm = await vm()
        vm.ownerCheck(due: true, lockedByChecks: false)
        #expect(vm.state.checkDue)
        vm.setPin("40281795")
        #expect(!vm.state.submitAllowed, "the password too")
        vm.setPassword("correct horse")
        vm.submit()
        await vm.settle()
        #expect(vault.calls.contains("unlockWithCheck"))
        #expect(vault.lastPassword == "correct horse")
        #expect(vm.state.password.isEmpty)
    }

    @Test func beforeTheDeadlineOnlyThePin() async {
        let vm = await vm()
        #expect(!vm.state.checkDue)
        await submit(vm)
        #expect(!vault.calls.contains("unlockWithCheck") && vault.calls.contains("unlock"))
    }

    @Test func tenFailedChecksShowTheLock() async {
        let vm = await vm()
        vm.ownerCheck(due: false, lockedByChecks: true)
        #expect(vm.state.lockedByOwnerCheck && vm.state.checkDue)
    }

    @Test func softwareUpdatedMustBeAcknowledgedBeforeThePin() async {
        vault.preflightInfo = PreflightInfo(
            routed: FakeVaultRepository.release(4), lastNumber: 3, softwareUpdated: true, rollback: false, offer: nil
        )
        let vm = await vm()
        await submit(vm)
        #expect(!vault.calls.contains("unlock"))
        vm.acknowledgeUpdate()
        await submit(vm)
        #expect(vault.calls.contains("unlock"))
    }

    @Test func rollbackNeverSendsThePin() async {
        vault.preflightInfo = PreflightInfo(
            routed: FakeVaultRepository.release(2), lastNumber: 3, softwareUpdated: false, rollback: true, offer: nil
        )
        let vm = await vm()
        await submit(vm)
        #expect(!vm.state.pinAllowed && !vault.calls.contains("unlock"))
    }

    @Test func approvedOfferTravelsWithTheUnlock() async {
        let offer = FakeVaultRepository.release(5)
        vault.preflightInfo = PreflightInfo(
            routed: FakeVaultRepository.release(4, status: "deprecated"), lastNumber: 4, softwareUpdated: false, rollback: false,
            offer: offer
        )
        let vm = await vm()
        vm.setApproveOffer(true)
        await submit(vm)
        #expect(vault.lastApproved == offer)
    }

    @Test func badPinStartsTheBackoffCountdown() async {
        vault.unlockResults = [.badPin(retryAfterSeconds: 30)]
        let vm = await vm()
        await submit(vm, "11112222")
        #expect(vm.state.message == .badPin)
        #expect(vm.state.waitSeconds == 30 && !vm.state.pinAllowed)
        await ticker.advance(10, vm)
        #expect(vm.state.waitSeconds == 20)
        await ticker.advance(20, vm)
        #expect(vm.state.waitSeconds == 0 && vm.state.pinAllowed)
    }

    /// Release R: a "Finish the move" that did not open the vault says why on the unlock screen it leads to.
    @Test func aFailedFinishTheMoveIsShownHere() async {
        vault.finishMoveFailure = .transferIncomplete
        let vm = await vm()
        #expect(vm.state.moveFailure == .transferIncomplete)
        vm.dismissMoveFailure()
        await vm.settle()
        #expect(vm.state.moveFailure == nil)
    }

    @Test func recoveryPendingThenCancelAndUnlock() async {
        vault.unlockResults = [.recoveryPending]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.recoveryPending && !vault.lastCancelRecovery)
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vault.lastCancelRecovery && vault.phase == .unlocked)
    }

    /// Release R (ANDROID-PLAN "Other screens"): a cancel from the app asks for the password and sends the owner check.
    @Test func releaseRCancelSendsTheOwnerCheck() async {
        vault.phoneSecret = true
        vault.unlockResults = [.recoveryPending]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.recoveryPending)
        #expect(!vm.state.cancelAllowed, "the password first")
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(!vault.lastCancelRecovery)
        vm.setPassword("the password")
        #expect(vm.state.cancelAllowed)
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vault.lastCancelRecovery && vault.lastCancelCheckPassword == "the password")
        #expect(vm.state.password.isEmpty && vault.phase == .unlocked)
    }

    /// §11.7.1: `signer_refused` is a state of its own. Not a wrong PIN: no message, no countdown, the field stays usable;
    /// the same answer for any PIN keeps the notice, and nothing offers to erase the phone.
    @Test func signerRefusedIsItsOwnStateNotAWrongPin() async {
        vault.unlockResults = [.signerRefused, .signerRefused]
        let vm = await vm()
        await submit(vm)
        var s = vm.state
        #expect(s.signerRefused && s.message == nil && s.waitSeconds == 0 && s.pin.isEmpty && !s.busy && s.pinAllowed)
        #expect(!s.notRecognised && !s.recoveryPending && vault.phase == .locked)
        vm.showSignerHelp(true)
        #expect(vm.state.signerHelp)
        vm.showSignerHelp(false)
        #expect(!vm.state.signerHelp)
        await submit(vm, "11112222")
        s = vm.state
        #expect(s.signerRefused && s.message == nil && s.waitSeconds == 0)
        vm.askErase()
        #expect(!vm.state.eraseConfirm)
    }

    @Test func signerRefusedClearsOnAnotherAnswerOfTheVault() async {
        vault.unlockResults = [.signerRefused, .failed(.network, code: nil), .badPin(retryAfterSeconds: 0)]
        let vm = await vm()
        vm.showSignerHelp(true) // nothing to help with yet
        #expect(!vm.state.signerHelp)
        for expected in [true, true, false] {
            await submit(vm)
            #expect(vm.state.signerRefused == expected)
        }
        #expect(vm.state.message == .badPin)
    }

    @Test func stateRollbackAndFailures() async {
        vault.unlockResults = [.stateRollback]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.stateRollback)

        vault.fail["preflight"] = FakeVaultRepository.failure(.releaseEnded)
        let ended = await self.vm()
        #expect(ended.state.preflightError == .releaseEnded && !ended.state.pinAllowed)
    }

    /// The vault's release is not in the app's manifest, the manifest could not be loaded, the enclave's document did not
    /// verify, or (iPhone, IOS-PLAN ID8) the release is older than R: no PIN is asked for or sent, and "Try again" checks
    /// again.
    @Test(arguments: [FailureKind.releaseUnknown, .manifestUnavailable, .manifest, .enclave, .network, .releaseTooOld])
    func noPinWhileTheVaultsSoftwareIsNotVerified(_ kind: FailureKind) async {
        let v = FakeVaultRepository(.locked)
        v.fail["preflight"] = FakeVaultRepository.failure(kind, code: "enclave")
        let vm = UnlockViewModel(vault: v, account: v, tick: ticker.tick)
        await vm.settle()
        #expect(vm.state.preflightError == kind && vm.state.preflight == nil)
        #expect(!vm.state.pinAllowed, "no PIN is asked for")
        #expect(vm.state.retryAllowed, "Try again is offered")
        vm.setPin("40281795")
        #expect(!vm.state.submitAllowed)
        vm.submit()
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(!v.calls.contains { $0.hasPrefix("unlock") }, "no PIN was sent")
        #expect(v.phase == .locked)
        vm.retryPreflight()
        await vm.settle()
        #expect(vm.state.preflightError == nil)
        #expect(v.calls.filter { $0 == "preflight" }.count == 2)
        #expect(vm.state.pinAllowed)
    }

    @Test func aCheckThatFailsAfterOneThatPassedTakesThePinAway() async {
        let vm = await vm()
        #expect(vm.state.pinAllowed)
        vault.fail["preflight"] = FakeVaultRepository.failure(.enclave, code: "enclave")
        vm.retryPreflight()
        await vm.settle()
        #expect(vm.state.preflightError == .enclave && vm.state.preflight == nil, "the earlier check does not count")
        await submit(vm)
        #expect(!vm.state.pinAllowed && !vault.calls.contains { $0.hasPrefix("unlock") })
    }

    // MARK: - "Erase VettID from this phone" (owner decision, 2026-10-05)

    func unrecognised() async -> UnlockViewModel {
        vault.unlockResults = [.failed(.other, code: UnlockState.codeUnreadable)]
        let vm = await vm()
        await submit(vm)
        return vm
    }

    @Test func anUnreadableResultOffersTheErase() async {
        let vm = await unrecognised()
        #expect(vm.state.notRecognised && !vm.state.eraseConfirm)
        vm.setPin("1")
        #expect(vm.state.notRecognised, "typing a PIN again keeps the offer")
        #expect(!vault.calls.contains("eraseThisPhone"))
    }

    @Test func confirmErasesOnceThenTheWelcomeScreen() async {
        let vm = await unrecognised()
        vm.askErase()
        #expect(vm.state.eraseConfirm)
        #expect(!vault.calls.contains("eraseThisPhone"), "nothing before the confirmation")
        vm.confirmErase()
        vm.confirmErase() // a double tap
        await vm.settle()
        #expect(vault.calls.filter { $0 == "eraseThisPhone" }.count == 1)
        #expect(vm.state.erasing && !vm.state.eraseConfirm)
        #expect(vault.phase == .signedOut && vault.account == nil)
    }

    @Test func tryAgainClosesAnOpenEraseConfirmation() async {
        let vm = await unrecognised()
        vm.askErase()
        vm.retryPreflight()
        #expect(!vm.state.eraseConfirm, "closed while the release check runs")
        await vm.settle()
        #expect(!vm.state.eraseConfirm, "still closed after it")
        #expect(vm.state.eraseOffered, "the offer itself stays")
        vm.confirmErase() // a stale confirm from the closed dialog
        await vm.settle()
        #expect(!vault.calls.contains("eraseThisPhone"))
    }

    @Test func cancelErasesNothing() async {
        let vm = await unrecognised()
        vm.askErase()
        vm.dismissErase()
        #expect(!vm.state.eraseConfirm)
        vm.confirmErase()
        await vm.settle()
        #expect(!vault.calls.contains("eraseThisPhone"))
        #expect(vault.phase == .locked && vm.state.notRecognised)
    }

    /// iPhone: an erase that fails is said, and the screen stays (vettid-android does not handle it).
    @Test func aFailedEraseIsSaid() async {
        let vm = await unrecognised()
        vault.fail["eraseThisPhone"] = FakeVaultRepository.failure(.notSupported)
        vm.askErase()
        vm.confirmErase()
        await vm.settle()
        #expect(!vm.state.erasing && vm.state.message == .failed(.notSupported, code: nil))
        #expect(vm.state.eraseOffered)
    }

    @Test func noEraseWhereTheVaultKnowsThisPhone() async {
        let outcomes: [UnlockAttempt] = [
            .badPin(retryAfterSeconds: 0), .failed(.network, code: nil), .stateRollback, .recoveryPending,
        ]
        for o in outcomes {
            vault.unlockResults = [o]
            let vm = await vm()
            #expect(!vm.state.notRecognised)
            await submit(vm)
            #expect(!vm.state.notRecognised, "\(o)")
            vm.askErase()
            vm.confirmErase()
            await vm.settle()
            #expect(!vm.state.eraseConfirm, "\(o)")
        }
        #expect(!vault.calls.contains("eraseThisPhone"))
    }

    /// (iPhone, until I1.7b brings the wipe) a sealed `unknown_device` is shown as not recognised, with the erase, never a
    /// dead end (vettid-android wipes the phone at once on it).
    @Test func aSealedUnknownDeviceOffersTheEraseUntilTheWipeArrives() async {
        vault.unlockResults = [.failed(.other, code: "unknown_device")]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.notRecognised && vm.state.eraseOffered)
        #expect(!vault.calls.contains("eraseThisPhone"))
    }

    /// A PIN handed over for an unlock the model refuses (the release check not passed) does not stay in its state.
    @Test func aRefusedSubmitForgetsThePin() async {
        vault.fail["preflight"] = FakeVaultRepository.failure(.enclave, code: "enclave")
        let vm = await vm()
        vm.setPin("40281795")
        vm.submit()
        #expect(vm.state.pin.isEmpty && !vault.calls.contains("unlock"))
        vm.setPin("40281795")
        vm.submitEarlierSecret()
        #expect(vm.state.pin.isEmpty)
    }

    /// A `401` that the phone's clock explains says to check the date and time; it never offers to erase the phone.
    @Test func aRefusalTheClockExplainsOffersNoErase() async {
        vault.unlockResults = [.failed(.clock, code: "clock_skew")]
        let vm = await vm()
        await submit(vm)
        #expect(!vm.state.notRecognised && vm.state.message == .failed(.clock, code: "clock_skew"))
        vm.askErase()
        #expect(!vm.state.eraseConfirm)
    }

    @Test func aRecognisedAnswerWithdrawsTheOffer() async {
        let vm = await unrecognised()
        vault.unlockResults = [.failed(.network, code: nil)]
        await submit(vm)
        #expect(vm.state.notRecognised, "a network failure says nothing either way")
        vault.unlockResults = [.badPin(retryAfterSeconds: 0)]
        await submit(vm)
        #expect(!vm.state.notRecognised, "a sealed bad_pin: the vault knows this phone after all")
        vm.askErase()
        #expect(!vm.state.eraseConfirm)
    }

    // MARK: - A phone sent here by repeated relay refusals (RefusalWatch)

    @Test func aRefusedPhoneIsOfferedTheEraseAfterAnUnreadableUnlock() async {
        vault.refusedByVault = true
        let vm = await vm()
        #expect(vm.state.refused)
        #expect(!vm.state.notRecognised, "the refusals alone offer nothing")
        vm.askErase()
        #expect(!vm.state.eraseConfirm)
        vault.unlockResults = [.failed(.other, code: UnlockState.codeUnreadable)]
        await submit(vm)
        #expect(vm.state.notRecognised)
        #expect(!vault.calls.contains("eraseThisPhone"), "never erased without the member")
        #expect(vault.phase == .locked)
        vm.askErase()
        vm.confirmErase()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "eraseThisPhone" }.count == 1)
    }

    @Test func aRefusedPhoneThatTheVaultKnowsIsNotOfferedTheErase() async {
        vault.refusedByVault = true
        let vm = await vm()
        vault.unlockResults = [.badPin(retryAfterSeconds: 0)]
        await submit(vm)
        #expect(!vm.state.refused && !vm.state.notRecognised)
        await submit(vm)
        #expect(vault.phase == .unlocked && !vault.calls.contains("eraseThisPhone"))
    }

    @Test func withoutRefusalsTheUnlockScreenSaysNothingOfThem() async {
        let vm = await vm()
        #expect(!vm.state.refused)
        vault.unlockResults = [.failed(.network, code: nil)]
        await submit(vm)
        #expect(!vm.state.refused && !vm.state.notRecognised)
    }

    @Test func aPausedServiceWaitsForRetryAfterAndNeverOffersTheErase() async {
        vault.unlockResults = [.failed(.servicePaused, code: "vault_unavailable", retryAfterSeconds: 300)]
        let vm = await vm()
        await submit(vm)
        let s = vm.state
        #expect(s.message == .failed(.servicePaused, code: "vault_unavailable"))
        #expect(s.serviceWaitSeconds == 300 && !s.notRecognised && !s.pinAllowed)
        // The member's next try waits; nothing retries by itself.
        await submit(vm)
        await ticker.advance(299, vm)
        #expect(vault.calls.filter { $0 == "unlock" }.count == 1)
        #expect(!vm.state.pinAllowed)
        await ticker.advance(1, vm)
        #expect(vm.state.serviceWaitSeconds == 0 && vm.state.pinAllowed)
        #expect(vault.calls.filter { $0 == "unlock" }.count == 1)
        await submit(vm)
        #expect(vault.phase == .unlocked)
    }

    @Test func aPausedReleaseCheckHoldsTryAgainUntilRetryAfter() async {
        vault.fail["preflight"] = VaultFailure(.servicePaused, code: "vault_unavailable", retryAfterSeconds: 300)
        let vm = await vm()
        #expect(vm.state.preflightError == .servicePaused && vm.state.serviceWaitSeconds == 300 && !vm.state.retryAllowed)
        vm.retryPreflight()
        await ticker.advance(1, vm)
        #expect(vault.calls.filter { $0 == "preflight" }.count == 1)
        await ticker.advance(299, vm)
        #expect(vm.state.retryAllowed)
        #expect(vault.calls.filter { $0 == "preflight" }.count == 1, "no automatic retry")
        vm.retryPreflight()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "preflight" }.count == 2)
        #expect(vm.state.preflightError == nil && vm.state.pinAllowed)
    }

    @Test func aServiceThatIsNotThereYetHasNoWait() async {
        vault.unlockResults = [.failed(.vaultUnavailable, code: "vault_unavailable")]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.serviceWaitSeconds == 0 && vm.state.pinAllowed && !vm.state.notRecognised)
    }

    /// A lock the vault has not confirmed is said on the unlock screen, with "Try again", until it is confirmed.
    @Test func anUnconfirmedLockIsShownUntilTheVaultConfirms() async {
        let vm = await vm()
        #expect(vm.state.lock == .none)
        let pending = LockNotice.unconfirmed(askedAt: FakeVaultRepository.date("2026-10-12T10:00:00Z"), attempts: 2)
        vault.lockNotice = pending
        await vm.settle()
        #expect(vm.state.lock == pending)
        vm.retryLock()
        #expect(vault.calls.contains("retryLock"))
        vault.lockNotice = .confirmedLate
        await vm.settle()
        #expect(vm.state.lock == .confirmedLate)
        vm.dismissLockNotice()
        await vm.settle()
        #expect(vm.state.lock == .none)
    }

    /// (iPhone, IOS-PLAN §6.3) Typed secrets are dropped when the app leaves the foreground.
    @Test func secretsAreForgottenOnLeaving() async {
        vault.unlockResults = [.recoveryPending]
        let vm = await vm()
        await submit(vm)
        vm.setPassword("the password")
        vm.forgetSecrets()
        #expect(vm.state.pin.isEmpty && vm.state.password.isEmpty)
        #expect(!vm.state.description.contains("4028"))
    }
}
