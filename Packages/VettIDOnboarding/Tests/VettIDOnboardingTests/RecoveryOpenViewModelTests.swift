import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

// swiftlint:disable line_length

/// The recovery open of release R (VAULT-MESSAGING 0.33.0 §11.14.6, ANDROID-PLAN 0.1.40). Mirrors vettid-android
/// `RecoveryOpenViewModelTest`.
@MainActor
@Suite struct RecoveryOpenViewModelTests {
    let vault: FakeVaultRepository

    init() {
        vault = FakeVaultRepository(.setup(.recovering))
        vault.phoneSecret = true
    }

    func model() async -> RecoveryOpenViewModel {
        let vm = RecoveryOpenViewModel(move: vault, account: vault)
        await vm.settle()
        return vm
    }

    func enterAndSend(_ vm: RecoveryOpenViewModel, pin: String = "975310", password: String = "correct horse battery") async {
        vm.setPin(pin)
        vm.setPassword(password)
        vm.review()
        vm.send()
        await vm.settle()
    }

    /// The app leaves the foreground: what was typed goes, the check goes back to the fields, a send under way is left alone.
    @Test func forgettingTheSecretsEmptiesTheEntriesAndTheCheck() async throws {
        let vm = await model()
        vm.setPin("975310")
        vm.setPassword("correct horse battery")
        vm.review()
        #expect(vm.state.step == .check)
        vm.forgetSecrets()
        #expect(vm.state.step == .enter && vm.state.pin.isEmpty && vm.state.password.isEmpty && !vm.state.canContinue)
        vm.review()
        #expect(vm.state.step == .enter, "nothing is checked or sent without the entries")
    }

    @Test func okShowsTheAttemptsUsedBeforeTheAppOpens() async throws {
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("ok", used: 2)]
        let vm = await model()
        await enterAndSend(vm)
        let s = vm.state
        #expect(s.step == .done && s.outcome?.used == 2 && s.pin.isEmpty && s.password.isEmpty)
        // The app opens only when the member continues.
        #expect(!vault.calls.contains("finishRecoveryOpen"))
        vm.openApp()
        await vm.settle()
        #expect(vault.calls.contains("finishRecoveryOpen") && vault.phase == .unlocked && vm.state.opened)
    }

    /// The release R recovery end to end over one vault, as the screens run it: the recovery flow at its open, the open
    /// answered `ok`, Continue. When the open returns without the app open (finishing, which the onboarding ignores while it
    /// shows the recovery), the recovery screen's hand-over to the end of setup opens it.
    @Test func okThenContinueOpensTheAppFromTheRecoveryScreens() async throws {
        vault.recoveryOpenLeavesFinishing = true
        vault.recoveryStageValue = .pin
        let recover = RecoverViewModel(move: vault, vault: vault, account: vault)
        let open = await model()
        await recover.settle()
        #expect(recover.state.step == .open && vault.usesPhoneSecret)
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("ok", used: 1)]
        await enterAndSend(open)
        #expect(open.state.step == .done)
        open.openApp()
        await open.settle()
        // The phase the bug left the phone in: finishing, ignored under the recovery screen.
        #expect(vault.phase == .setup(.finishing) && open.state.opened)
        // What the pane does once opened (the recovery flow's finish).
        recover.finish()
        await recover.settle()
        #expect(vault.calls.contains("finishSetup") && vault.phase == .unlocked)
    }

    /// A lock asked for between `ok` and Continue is pending: the phone stays locked, the app never opens, and the screen says
    /// so (not a silent stop).
    @Test func aLockPendingAtContinueKeepsThePhoneLockedAndSaysSo() async throws {
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("ok", used: 1)]
        let vm = await model()
        await enterAndSend(vm)
        vault.recoveryLockPending = true
        vm.openApp()
        await vm.settle()
        let s = vm.state
        #expect(vault.phase == .locked && !s.opened && s.failure == .noResponse && s.failureCode == MoveCodes.lockPending && s.step == .done)
    }

    /// Anything else thrown at Continue (the account record's write): a failure on the screen, never the open app.
    @Test func anUnexpectedErrorAtContinueIsAFailureNotACrash() async throws {
        struct RecordWrite: Error {}
        vault.recoveryFinishError = RecordWrite()
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("ok", used: 1)]
        let vm = await model()
        await enterAndSend(vm)
        vm.openApp()
        await vm.settle()
        let s = vm.state
        #expect(!s.opened && s.failure == .other && s.failureCode == MoveCodes.notOpened && vault.phase == .setup(.recovering))
        // Continue may be pressed again, and opens nothing twice.
        vault.recoveryFinishError = nil
        vm.openApp()
        await vm.settle()
        #expect(vm.state.opened && vm.state.failure == nil && vault.phase == .unlocked)
    }

    @Test func aDoubleTapOnContinueOpensOnce() async throws {
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("ok", used: 1)]
        let vm = await model()
        await enterAndSend(vm)
        vm.openApp()
        vm.openApp()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "finishRecoveryOpen" }.count == 1 && vm.state.opened)
    }

    /// The start-up read of an `ok` that was not finished does not overwrite a step the member has moved to.
    @Test func theLateStartReadDoesNotOverwriteAStep() async throws {
        vault.recoveryOpenedValue = true
        let vm = RecoveryOpenViewModel(move: vault, account: vault)
        vm.setPin("975310")
        vm.setPassword("x")
        vm.review()
        #expect(vm.state.step == .check)
        await vm.settle()
        #expect(vm.state.step == .check)
    }

    /// After ok the vault removed the recovery: a failure then, or a restart, finishes with the PIN, never a new open.
    @Test func anOkWhoseRestFailedIsFinishedWithThePin() async throws {
        vault.fail["recoveryOpen"] = VaultFailure(.noResponse)
        let vm = await model()
        vault.recoveryOpenedValue = true // the vault answered ok; the handshake did not complete
        await enterAndSend(vm)
        #expect(vm.state.step == .finish && vm.state.failure == .noResponse)
        // The phone's own unlock with a wrong PIN: said as that, still finishing.
        vault.fail["recoveryOpen"] = nil
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("bad_pin", used: 1, opened: true)]
        vm.setPin("111111")
        vm.send()
        await vm.settle()
        #expect(vm.state.step == .finish && vm.state.outcome?.opened == true)
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("ok", used: 1)]
        vm.setPin("975310")
        vm.send()
        await vm.settle()
        #expect(vm.state.step == .done)
        // And after a restart: straight to the PIN alone.
        let again = await model()
        #expect(again.state.step == .finish)
    }

    /// Finishing an ok recovery the vault no longer accepts: erase VettID from this phone, after a confirmation only.
    @Test func aVaultThatNoLongerHasThisPhoneOffersTheErase() async throws {
        vault.recoveryOpenedValue = true
        let vm = await model()
        #expect(vm.state.step == .finish && !vm.state.canErase)
        // A temporary failure: no erase.
        vault.fail["recoveryOpen"] = VaultFailure(.noResponse)
        vm.setPin("975310")
        vm.send()
        await vm.settle()
        #expect(!vm.state.canErase)
        // Its own key refused at both epochs: the vault no longer has this phone.
        vault.fail["recoveryOpen"] = nil
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("device_secret", used: 1, opened: true)]
        vm.setPin("975310")
        vm.send()
        await vm.settle()
        #expect(vm.state.canErase)
        vm.erase()
        await vm.settle()
        #expect(!vault.calls.contains("eraseThisPhone"))
        vm.askErase()
        #expect(vm.state.confirmErase)
        vm.erase()
        await vm.settle()
        #expect(vault.calls.contains("eraseThisPhone") && vault.phase == .signedOut)
        // Answers the host or the member API can produce never offer it: random bytes, a 401, no vault.
        for f in [VaultFailure(.other, code: "unreadable_result"), VaultFailure(.unauthorized), VaultFailure(.noVault)] {
            let again = await model()
            vault.fail["recoveryOpen"] = f
            again.setPin("975310")
            again.send()
            await again.settle()
            #expect(again.state.step == .finish && !again.state.canErase, "\(f)")
        }
    }

    /// A lost ok (0.34.0 §11.14.6): after an open with no readable answer the PIN unlocks with this phone's secret; a result
    /// with the vault's bundle finishes the recovery, one without it leads back to the open.
    @Test func aLostOkIsResumedWithThePin() async throws {
        vault.fail["recoveryOpen"] = VaultFailure(.other, code: "unreadable_result")
        let vm = await model()
        await enterAndSend(vm)
        #expect(vm.state.step == .answered && vm.state.failureCode == "unreadable_result")
        vault.fail["recoveryOpen"] = nil
        vm.finishLostOk()
        #expect(vm.state.step == .finish && vm.state.lostOk && vm.state.password.isEmpty && !vm.state.canErase)
        // No bundle for this phone: said so, and back to the open.
        vault.lostOkOutcomes = [RecoveryOpenOutcome(VaultManager.codeNoBundle, used: 2, opened: true, attemptUsed: false)]
        vm.setPin("975310")
        vm.send()
        await vm.settle()
        #expect(vm.state.step == .finish && vm.state.outcome?.code == VaultManager.codeNoBundle)
        // The vault's device_secret to the resume: this phone is not in its unlock keys, said like no bundle, with the way
        // back (never "try again").
        vault.lostOkOutcomes = [RecoveryOpenOutcome("device_secret", used: 2, opened: true, attemptUsed: false)]
        vm.setPin("975310")
        vm.send()
        await vm.settle()
        #expect(vm.state.outcome?.code == VaultManager.codeNoBundle && !vm.state.canErase)
        #expect(openAnswerText(try #require(vm.state.outcome), rightButIncomplete: false).key == .lostNotHere)
        // The bundle came: the recovery is finished on this phone, without a new open.
        vm.setPin("975310")
        vm.send()
        await vm.settle()
        #expect(vm.state.step == .done)
        #expect(vault.calls.filter { $0 == "resumeLostOk" }.count == 3 && vault.calls.filter { $0 == "recoveryOpen" }.count == 1)
        vm.again()
        #expect(!vm.state.lostOk)
    }

    /// (IOS-PLAN 0.1.40 §4.9) The pairing keeps the PIN only while it is in front: leaving the foreground while it runs forgets
    /// it, and a pairing that then needs the lost-ok unlock again comes back to the PIN, which finishes it.
    @Test func aPinForgottenDuringThePairingIsAskedForAgain() async throws {
        vault.fail["recoveryOpen"] = VaultFailure(.other, code: "unreadable_result")
        let vm = await model()
        await enterAndSend(vm)
        vault.fail["recoveryOpen"] = nil
        vm.finishLostOk()
        vault.lostOkOutcomes = [RecoveryOpenOutcome(VaultManager.codePinNeeded, opened: true, attemptUsed: false)]
        vm.setPin("975310")
        vm.send()
        #expect(vm.state.step == .sending)
        // The app leaves the foreground while the pairing runs: nothing under way is touched, the kept PIN is forgotten.
        vm.forgetSecrets()
        #expect(vm.state.step == .sending && vault.calls.contains("forgetPairingPin"))
        await vm.settle()
        #expect(vm.state.step == .finish && vm.state.lostOk && vm.state.outcome == nil && vm.state.failure == nil)
        #expect(vm.state.pin.isEmpty)
        // The PIN entered again finishes it.
        vm.setPin("975310")
        vm.send()
        await vm.settle()
        #expect(vm.state.step == .done && vault.lastPin == "975310")
        #expect(vault.calls.filter { $0 == "resumeLostOk" }.count == 2)
    }

    /// "The last attempt was right but could not be completed": only after an open that got no answer.
    @Test func rightButIncompleteOnlyAfterAnUnansweredOpen() async throws {
        let at = Date(timeIntervalSince1970: 1_792_497_600)
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("attempt_lost", used: 3, retryAt: at)]
        let vm = await model()
        await enterAndSend(vm)
        #expect(!vm.state.rightButIncomplete)
        // An attempt_lost before never makes the next answer "right but incomplete".
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("wait", used: 3, retryAt: at)]
        vm.again()
        vm.review()
        vm.send()
        await vm.settle()
        #expect(!vm.state.rightButIncomplete)
        // The data layer reports that the open before got no answer (kept across a restart).
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("wait", used: 4, retryAt: at, afterUnanswered: true)]
        vm.again()
        vm.review()
        vm.send()
        await vm.settle()
        #expect(vm.state.rightButIncomplete)
    }

    /// The warnings before sending also on the first send after a restart: the attempts used as last reported.
    @Test func warningsUseTheAttemptsReportedBeforeARestart() async throws {
        vault.recoveryAttemptsUsed = 1
        #expect(await model().state.warning == .second)
        vault.recoveryAttemptsUsed = 8
        #expect(await model().state.warning == .fewLeft)
    }

    @Test func aWrongEntryClearsThePasswordAndAnythingElseKeepsTheEntries() async throws {
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("wrong", used: 1), RecoveryOpenOutcome("busy")]
        let vm = await model()
        await enterAndSend(vm)
        #expect(vm.state.step == .answered && vm.state.used == 1 && vm.state.password.isEmpty && vm.state.pin == "975310")
        vm.again()
        #expect(vm.state.step == .enter && vm.state.outcome == nil)
        vm.setPassword("another one")
        vm.review()
        vm.send()
        await vm.settle()
        #expect(vm.state.outcome?.code == "busy" && vm.state.password == "another one" && vm.state.used == 1)
    }

    @Test func theCheckStepCannotBeSkippedAndTheEntriesNeedBoth() async throws {
        let vm = await model()
        vm.setPin("97531")
        vm.setPassword("x")
        vm.review()
        #expect(vm.state.step == .enter, "a PIN of five digits is not enough")
        vm.setPin("9753-10a")
        #expect(vm.state.pin == "975310")
        vm.setPassword("")
        vm.review()
        #expect(vm.state.step == .enter)
        vm.send()
        await vm.settle()
        #expect(vm.state.step == .enter && !vault.calls.contains("recoveryOpen"))
        vm.setPassword("x")
        vm.review()
        #expect(vm.state.step == .check)
        vm.change()
        #expect(vm.state.step == .enter && vm.state.pin == "975310" && vm.state.password == "x")
    }

    @Test func anOpenThatThrewBeforeAnyAnswerIsAFailureStepWithTheEntriesKept() async throws {
        vault.fail["recoveryOpen"] = VaultFailure(.network)
        let vm = await model()
        await enterAndSend(vm)
        #expect(vm.state.step == .answered && vm.state.failure == .network && vm.state.outcome == nil && vm.state.password == "correct horse battery")
    }

    @Test func theEntriesStayOutOfTheDescription() {
        var s = RecoveryOpenState()
        s.pin = "135792"
        s.password = "correct horse battery staple"
        #expect(!"\(s)".contains("135792") && !"\(s)".contains("horse") && !String(reflecting: s).contains("horse"))
        #expect(s.canContinue)
    }
}

// swiftlint:enable line_length
