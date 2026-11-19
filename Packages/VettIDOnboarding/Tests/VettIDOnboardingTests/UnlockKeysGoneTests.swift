import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// A phone that no longer holds the vault's keys (`device_secret`): recover-or-erase, the erase confirmed; the offer is
/// kept through typing and failures that did not reach the vault, and goes with any answer of the vault or a new release
/// check; an ended release or a rollback found meanwhile wins (no erase). Mirrors vettid-android `UnlockKeysGoneTest`,
/// with the iPhone's earlier-secret step (IOS-PLAN §6.3 item 5).
@MainActor
@Suite struct UnlockKeysGoneTests {
    let vault = FakeVaultRepository(.locked)

    func vm() async -> UnlockViewModel {
        let vm = UnlockViewModel(vault: vault, account: vault)
        await vm.settle()
        return vm
    }

    func submit(_ vm: UnlockViewModel) async {
        vm.setPin("40281795")
        vm.submit()
        await vm.settle()
    }

    @Test func aPhoneWithoutTheVaultsKeysMayBeErasedAfterTheConfirmation() async {
        vault.unlockResults = [.failed(.deviceSecret, code: "device_secret")]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.keysGone && !vm.state.notRecognised)
        vm.setPin("1")
        #expect(vm.state.keysGone, "typing again clears the failure's message, not the offer")
        vm.confirmErase() // nothing without the dialog
        await vm.settle()
        #expect(!vault.calls.contains("eraseThisPhone"))
        vm.askErase()
        #expect(vm.state.eraseConfirm)
        vm.confirmErase()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "eraseThisPhone" }.count == 1)
    }

    @Test func aPhoneWithoutTheKeysKeepsTheOfferUntilTheVaultAnswersOtherwise() async {
        vault.unlockResults = [
            .failed(.deviceSecret, code: "device_secret"), .failed(.network, code: nil), .badPin(retryAfterSeconds: 0),
        ]
        let vm = await vm()
        for expected in [true, true, false] {
            await submit(vm)
            #expect(vm.state.keysGone == expected)
        }
    }

    @Test func aRollbackFoundAfterKeysGoneOffersNoErase() async {
        vault.unlockResults = [.failed(.deviceSecret, code: "device_secret")]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.keysGone)
        vault.fail["preflight"] = FakeVaultRepository.failure(.releaseEnded)
        vm.retryPreflight()
        await vm.settle()
        #expect(vm.state.recoverOnly && !vm.state.keysGone && !vm.state.eraseOffered)
        vm.askErase()
        vm.confirmErase()
        await vm.settle()
        #expect(!vm.state.eraseConfirm && !vault.calls.contains("eraseThisPhone"))
    }

    @Test func anAttestationRefusalClearsTheKeysGoneOffer() async {
        vault.unlockResults = [.failed(.deviceSecret, code: "device_secret"), .failed(.attestation, code: "attestation")]
        let vm = await vm()
        for expected in [true, false] {
            await submit(vm)
            #expect(vm.state.keysGone == expected)
        }
    }

    @Test func aNetworkFailureOffersNoErase() async {
        vault.unlockResults = [.failed(.network, code: nil)]
        let vm = await vm()
        await submit(vm)
        vm.askErase()
        #expect(!vm.state.eraseConfirm)
    }

    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier secret is offered only with a replaced record, and tried only on the
    /// member's tap.
    @Test func theEarlierSecretIsTriedOnlyOnTheMembersTap() async {
        vault.unlockResults = [.failed(.deviceSecret, code: "device_secret")]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.keysGone && !vm.state.earlierSecret, "no replaced record: nothing to try")
        vm.setPin("40281795")
        vm.submitEarlierSecret()
        await vm.settle()
        #expect(!vault.calls.contains("unlockWithEarlierSecret"))

        vault.earlierSecretOffered = true
        vault.unlockResults = [.failed(.deviceSecret, code: "device_secret")]
        await submit(vm)
        #expect(vm.state.earlierSecret)
        #expect(!vault.calls.contains("unlockWithEarlierSecret"), "never by itself")
        vm.setPin("40281795")
        vm.submitEarlierSecret()
        await vm.settle()
        #expect(vault.calls.contains("unlockWithEarlierSecret"))
        #expect(vault.phase == .unlocked && !vm.state.keysGone && !vm.state.earlierSecret)
    }

    /// (iPhone, IOS-PLAN §6.2) The App Attest key gone: the keys-gone screen without the earlier-secret offer, which
    /// cannot help.
    @Test func noEarlierSecretWhenTheAppAttestKeyIsGone() async {
        vault.earlierSecretOffered = true
        vault.unlockResults = [.failed(.deviceSecret, code: VaultFailure.codeAppAttestKeyGone)]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.keysGone && !vm.state.earlierSecret)
    }

    /// (§6.7.1, owner decision a, 2026-11-18) No usable `user_guid`: this phone can never unlock, so the recover-or-erase
    /// notice is shown, its erase confirmed, and no earlier secret is offered (none adds a `user_guid`). The kind or the code
    /// alone is not it. Mirrors vettid-android `UnlockStuckTest`.
    @Test func aPhoneWithoutAUserGuidIsOfferedRecoverOrErase() async {
        vault.earlierSecretOffered = true
        vault.unlockResults = [.failed(.notSupported, code: UnlockAttempt.codeNoUserGuid)]
        let vm = await vm()
        await submit(vm)
        #expect(vm.state.keysGone && vm.state.stuckNoticeShown && vm.state.eraseOffered && !vm.state.earlierSecret)
        vm.askErase()
        #expect(vm.state.eraseConfirm)

        for other in [UnlockAttempt.failed(.notSupported, code: "other"), .failed(.other, code: UnlockAttempt.codeNoUserGuid)] {
            #expect(!UnlockViewModel.keysGone(after: other, before: false), "\(other)")
            #expect(UnlockViewModel.earlierSecretHelps(other), "\(other)")
        }
    }

    /// (§6.7.1) Known when the screen opens: the recover-or-erase notice at once, and no PIN asked, since none would be
    /// used.
    @Test func aPhoneKnownWithoutAUserGuidAsksNoPin() async {
        vault.userGuidUsable = false
        let vm = await vm()
        #expect(vm.state.noUserGuid && vm.state.keysGone && vm.state.stuckNoticeShown && vm.state.eraseOffered)
        #expect(!vm.state.showsPin && !vm.state.pinAllowed && !vm.state.submitAllowed)
        vm.setPin("40281795")
        vm.submit()
        await vm.settle()
        #expect(!vault.calls.contains("unlock"), "nothing sent")
        vm.retryPreflight()
        await vm.settle()
        #expect(vm.state.keysGone && !vm.state.showsPin, "a new release check keeps it")
    }

    /// (§6.7.1) The erase is offered only once the release check has answered, so an ended release or a rollback found by
    /// it wins (no erase); and no "Return to release N", which would ask for a PIN.
    @Test func noEraseBeforeTheReleaseCheckAnswers() async {
        vault.userGuidUsable = false
        let vm = UnlockViewModel(vault: vault, account: vault)
        #expect(vm.state.loading && vm.state.noUserGuid && !vm.state.eraseOffered && !vm.state.showsPin)
        vm.askErase()
        #expect(!vm.state.eraseConfirm)
        await vm.settle()
        #expect(vm.state.eraseOffered)

        vault.fail["preflight"] = FakeVaultRepository.failure(.releaseEnded)
        let ended = await self.vm()
        #expect(ended.state.recoverOnly && !ended.state.eraseOffered)

        vault.fail["preflight"] = nil
        vault.preflightInfo = PreflightInfo(
            routed: FakeVaultRepository.release(3), lastNumber: 4, softwareUpdated: false, rollback: true, offer: nil
        )
        let rolledBack = await self.vm()
        #expect(rolledBack.state.recoverOnly && !rolledBack.state.eraseOffered && !rolledBack.state.stuckWordsOnly)

        var s = UnlockState(loading: false)
        s.moveUnconfirmed = UnconfirmedMove(from: FakeVaultRepository.release(4), to: FakeVaultRepository.release(5), failed: true)
        #expect(s.returnOffered)
        s.noUserGuid = true
        #expect(!s.returnOffered && !s.showsPin)
    }

    /// (§6.7.1, as vettid-android #412) A release check that failed could not rule out an ended release or a rollback: no
    /// erase, no recover-or-erase notice, the stuck words alone with "Try again". A later check that answers brings the
    /// notice with Recover and Erase.
    @Test func aFailedReleaseCheckOffersNoEraseOnAPhoneWithoutAUserGuid() async {
        vault.userGuidUsable = false
        vault.fail["preflight"] = FakeVaultRepository.failure(.network)
        let vm = await vm()
        #expect(vm.state.preflightError == .network, "\"Try again\" is the primary action")
        #expect(vm.state.stuckWordsOnly && !vm.state.stuckNoticeShown && !vm.state.eraseOffered)
        #expect(!vm.state.showsPin, "still no PIN")
        vm.askErase()
        #expect(!vm.state.eraseConfirm)

        vault.fail["preflight"] = nil
        vm.retryPreflight()
        #expect(!vm.state.stuckWordsOnly && !vm.state.eraseOffered, "nothing while the check runs")
        await vm.settle()
        #expect(vm.state.eraseOffered && vm.state.stuckNoticeShown && !vm.state.stuckWordsOnly)
        vm.askErase()
        #expect(vm.state.eraseConfirm)
    }

    /// A paused service is a check that did not answer either: the words alone and "Try again" (once the pause's wait is
    /// over), no erase.
    @Test func aPausedServiceIsNoAnswer() async {
        vault.userGuidUsable = false
        vault.fail["preflight"] = FakeVaultRepository.failure(.servicePaused, retry: 30)
        let paused = await vm()
        #expect(paused.state.stuckWordsOnly && !paused.state.eraseOffered && paused.state.serviceWaitSeconds > 0)
        #expect(paused.state.preflightError == .servicePaused, "\"Try again\" once the wait is over")
    }

    /// A failure that is no vault answer (no ``VaultFailure``) is a check that did not answer: "Try again" (`.other`), the
    /// words alone, no erase.
    @Test func aFailureThatIsNoVaultAnswerOffersTryAgain() async {
        struct Odd: Error {}
        vault.userGuidUsable = false
        vault.failOther["preflight"] = Odd()
        let vm = await vm()
        #expect(vm.state.preflightError == .other, "\"Try again\"")
        #expect(vm.state.stuckWordsOnly && !vm.state.eraseOffered)
    }

    /// Each part of ``UnlockState/eraseReady`` on a phone with no usable `user_guid`: no erase while the check runs (even with
    /// an earlier answer), after a failed one (even with an answer kept), or with no answer at all.
    @Test func eachGuardOfTheEraseHolds() {
        let answered = PreflightInfo(
            routed: FakeVaultRepository.release(3), lastNumber: 3, softwareUpdated: false, rollback: false, offer: nil
        )
        var s = UnlockState(loading: true)
        s.noUserGuid = true
        s.keysGone = true
        s.preflight = answered
        #expect(!s.eraseOffered, "loading")
        s.loading = false
        s.preflightError = .network
        #expect(!s.eraseOffered, "a failed check")
        s.preflightError = nil
        s.preflight = nil
        #expect(!s.eraseOffered, "no answer")
        s.preflight = answered
        #expect(s.eraseOffered, "an answer")
    }

    /// A failed check and a "Finish the move" refused `no_user_guid`: the move card says it, so the words alone are not
    /// shown a second time.
    @Test func theWordsAreNotShownBesideTheMoveCard() {
        var s = UnlockState(loading: false)
        s.noUserGuid = true
        s.keysGone = true
        s.preflightError = .network
        #expect(s.stuckWordsOnly)
        s.moveFailure = MoveFailure(.notSupported, code: UnlockAttempt.codeNoUserGuid)
        #expect(!s.stuckWordsOnly && !s.eraseOffered)
    }

    /// A phone with its user_guid is not changed: the keys-gone offer after a failed check stays as before.
    @Test func aPhoneWithAUserGuidKeepsItsOffer() {
        var s = UnlockState(loading: false)
        s.keysGone = true
        s.preflightError = .network
        #expect(s.eraseOffered && s.stuckNoticeShown && !s.stuckWordsOnly)
    }

    /// (§6.7.1) A failed erase on a phone with no usable `user_guid` is said: a vault failure's own message, and any other
    /// failure's too (never silent).
    @Test(arguments: [true, false])
    func aFailedEraseIsSaid(_ vaultFailure: Bool) async {
        struct Odd: Error {}
        vault.userGuidUsable = false
        let vm = await vm()
        #expect(vm.state.eraseOffered)
        if vaultFailure {
            vault.fail["eraseThisPhone"] = FakeVaultRepository.failure(.network)
        } else {
            vault.failOther["eraseThisPhone"] = Odd()
        }
        vm.askErase()
        vm.confirmErase()
        await vm.settle()
        #expect(!vm.state.erasing)
        #expect(vm.state.message == .failed(vaultFailure ? .network : .other, code: nil), "\(String(describing: vm.state.message))")
    }
}
