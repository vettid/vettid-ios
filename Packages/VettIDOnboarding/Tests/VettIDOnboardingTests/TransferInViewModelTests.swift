import Foundation
import Testing
import VettIDCrypto
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The new phone's side of a direct transfer (VAULT-MESSAGING §6.7.1). Mirrors vettid-android `TransferInViewModelTest`,
/// test for test, on a virtual clock.
@MainActor
@Suite struct TransferInViewModelTests {
    let vault = FakeVaultRepository(.setup(.vaultElsewhere))
    let clock = VirtualTime()

    func model() -> TransferInViewModel {
        TransferInViewModel(move: vault, vault: vault, now: clock.now, sleep: clock.sleep)
    }

    /// A transfer code (or another kind of code) valid for [seconds] more at the virtual time.
    func qr(_ kind: InviteKind = .app, seconds: Int64 = 600) throws -> String {
        let exp = UInt64(clock.now().timeIntervalSince1970) + UInt64(max(seconds, 0))
        let q = InviteQr(
            kind: kind, relay: "https://relay.vettid.test", claimID: "abcdefghijklmnopqrstuvwxyz",
            hash: [UInt8](repeating: 1, count: 32), key: [UInt8](repeating: 2, count: 32), exp: exp
        )
        return try #require(String(bytes: try q.marshal(), encoding: .utf8))
    }

    @Test func scanCompareApproveDone() async throws {
        let vm = model()
        vm.scan()
        let code = try qr()
        vm.scanned(code)
        await clock.runCurrent()
        #expect(vault.lastTransferCode == code && vm.state.step == .compare && vm.state.sas == "042817")
        #expect((590...600).contains(vm.state.secondsLeft) && !vm.state.busy)
        vault.transferApproval.complete()
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .done && vm.state.sas == nil && vm.state.canUnlockLater)
        #expect(vault.phase == .setup(.finishing))
        vm.finish()
        await vm.settle()
        #expect(vault.phase == .unlocked)
    }

    /// The countdown to the end of the approval window runs on the clock.
    @Test func theApprovalCountdownRunsOnTheClock() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        #expect(vm.state.secondsLeft == 600)
        await clock.advance(seconds: 90)
        #expect(vm.state.secondsLeft == 510 && vm.state.step == .compare)
    }

    /// Release R: the phone key made for the transfer is known to the screen ("Finish the move" follows).
    @Test func aPhoneKeyMadeForTheTransferIsReported() async throws {
        vault.phoneSecret = true
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        vault.transferApproval.complete()
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .done && vm.state.phoneSecret)
    }

    /// VAULT-MESSAGING 0.17.0 §6.7.1: a vault release before 0.17.0 gives no user_guid; the transfer completes with a warning.
    @Test func aTransferWithoutUserGuidCompletesAndWarns() async throws {
        vault.transferGaveUserGuid = false
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        vault.transferApproval.complete()
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .done && !vm.state.canUnlockLater)
        #expect(vault.phase == .setup(.finishing))
    }

    @Test func rejectedOnTheOldPhone() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        vault.transferApproval.fail(FakeVaultRepository.failure(.rejected, code: "rejected"))
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .rejected && vm.state.sas == nil)
        vm.again()
        #expect(vm.state.step == .scan)
    }

    @Test func timesOutAfterTheWindow() async throws {
        let vm = model()
        vm.paste()
        vm.setInput(try qr())
        vm.submitInput()
        await clock.runCurrent()
        vault.transferApproval.fail(FakeVaultRepository.failure(.noResponse))
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .timedOut)
    }

    @Test func otherCodesAreRefusedBeforeAnythingIsSent() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr(.connection))
        #expect(vm.state.inputProblem == .inviteInvalid)
        vm.scanned("hello")
        #expect(vm.state.inputProblem == .inviteInvalid)
        vm.scanned(try qr(seconds: 0))
        #expect(vm.state.inputProblem == .inviteExpired)
        #expect(!vault.calls.contains("transferIn") && vm.state.step == .scan)
        // Typing again takes the problem away.
        vm.setInput("x")
        #expect(vm.state.inputProblem == nil)
    }

    @Test func aPastedCodeIsCheckedTheSameWay() async throws {
        let vm = model()
        vm.paste()
        vm.setInput(try qr(.desktop))
        vm.submitInput()
        #expect(vm.state.inputProblem == .inviteInvalid && vm.state.step == .paste && !vault.calls.contains("transferIn"))
        vm.setInput("  \(try qr())\n")
        vm.submitInput()
        await clock.runCurrent()
        #expect(vm.state.step == .compare)
    }

    @Test func cancellingDropsTheHandshake() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        #expect(vm.back())
        await vm.settle()
        #expect(vault.calls.contains("abandonTransferIn") && vm.state.step == .intro)
        #expect(!vm.back())
    }

    /// §6.7.1 step 2 (0.10.6): a dropped hs.init is never answered; the new phone stops after 60 s.
    @Test func noHsRespWithin60SecondsSaysWhyAndOffersANewCode() async throws {
        let hs = TestDeferred<String>()
        vault.transferHsResp = hs
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.advance(seconds: 59)
        #expect(vm.state.step == .connecting && vm.state.busy && !vault.calls.contains("abandonTransferIn"))
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .notAnswered && !vm.state.busy)
        #expect(vault.calls.contains("abandonTransferIn") && !vault.calls.contains("awaitTransferIn"))
        // A late hs.resp changes nothing: the wait was cancelled.
        hs.complete("042817")
        await clock.runCurrent()
        #expect(vm.state.step == .notAnswered)
        vm.again()
        #expect(vm.state.step == .scan)
    }

    @Test func theRepositorysOwnHsRespTimeoutSaysTheSame() async throws {
        vault.fail["transferIn"] = FakeVaultRepository.failure(.noResponse, code: MoveCodes.hsUnanswered)
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        #expect(vm.state.step == .notAnswered && !vm.state.busy)
    }

    @Test func anHsRespWithin60SecondsShowsTheCode() async throws {
        let hs = TestDeferred<String>()
        vault.transferHsResp = hs
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.advance(seconds: 45)
        hs.complete("042817")
        await clock.runCurrent()
        #expect(vm.state.step == .compare && vm.state.sas == "042817")
        // The window counts from the hs.init's answer, not from the 60 seconds' end.
        await clock.advance(seconds: 30)
        #expect(vm.state.step == .compare)
    }

    @Test func aFailureToConnectReturnsToTheCode() async throws {
        vault.fail["transferIn"] = FakeVaultRepository.failure(.noResponse)
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        #expect(vm.state.step == .scan && vm.state.error == .noResponse && !vm.state.busy)
    }

    /// The vault's own refusal of the code (`invite_invalid` after it parsed here) goes back to the code with the problem.
    @Test func aCodeTheVaultRefusesReturnsToTheCodeWithTheProblem() async throws {
        vault.fail["transferIn"] = FakeVaultRepository.failure(.inviteExpired, code: "expired")
        let vm = model()
        vm.paste()
        vm.setInput(try qr())
        vm.submitInput()
        await clock.runCurrent()
        #expect(vm.state.step == .paste && vm.state.inputProblem == .inviteExpired && vm.state.error == nil)
    }

    /// Any other failure after the SAS goes back to the start with its kind and code.
    @Test func anotherFailureWhileWaitingReturnsToTheStart() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        vault.transferApproval.fail(FakeVaultRepository.failure(.vaultUnavailable, code: "down"))
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .intro && vm.state.error == .vaultUnavailable && vm.state.errorCode == "down" && vm.state.sas == nil)
    }

    struct Odd: Error {}

    /// Swift cannot interrupt an await: a SAS that arrives in the same instant as `cancel()` changes nothing.
    @Test func aSasThatReturnsAfterCancelDoesNotShowTheCompareStep() async throws {
        let hs = TestDeferred<String>()
        vault.transferHsResp = hs
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        hs.complete("042817")
        vm.cancel() // before the model's task can run again
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .intro && vm.state.sas == nil && vm.state.secondsLeft == 0)
        #expect(!vault.calls.contains("awaitTransferIn"))
    }

    @Test func anApprovalThatReturnsAfterCancelDoesNotMoveToDone() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        vault.transferApproval.complete()
        vm.back() // cancels
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .intro && vm.state.sas == nil)
    }

    @Test func aFailureThatReturnsAfterCancelChangesNothing() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        vault.transferApproval.fail(FakeVaultRepository.failure(.rejected, code: "rejected"))
        vm.cancel()
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .intro)
    }

    /// An error that is not a vault failure ends the step with "other": the screen never freezes.
    @Test func anotherErrorWhileConnectingReturnsToTheCode() async throws {
        let hs = TestDeferred<String>()
        vault.transferHsResp = hs
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        hs.fail(Odd())
        await clock.runCurrent()
        #expect(vm.state.step == .scan && vm.state.error == .other && !vm.state.busy)
    }

    @Test func anotherErrorWhileWaitingForTheApprovalReturnsToTheStart() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        vault.transferApproval.fail(Odd())
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .intro && vm.state.error == .other && vm.state.sas == nil)
    }

    /// A dropped model deinits although its tasks wait: they hold it weakly.
    @Test func aDroppedModelDeinitsWhileItsTasksWait() async throws {
        weak var weakModel: TransferInViewModel?
        do {
            let vm = model()
            weakModel = vm
            vm.scan()
            vm.scanned(try qr())
            await clock.runCurrent()
            #expect(vm.state.step == .compare)
        }
        await clock.advance(seconds: 3)
        #expect(weakModel == nil)
    }

    @Test func theStateNamesNoCodeOrSas() async throws {
        let vm = model()
        vm.scan()
        vm.scanned(try qr())
        await clock.runCurrent()
        vm.setInput("secret-looking-text")
        #expect(!"\(vm.state)".contains("042817") && !"\(vm.state)".contains("secret-looking-text"))
    }
}
