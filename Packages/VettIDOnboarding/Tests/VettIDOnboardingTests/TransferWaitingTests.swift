import Foundation
import Testing
import VettIDCrypto
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// A transfer to this phone that is not finished (``SetupStage/transferWaiting``): onboarding opens the transfer screen,
/// and the screen takes the transfer up as it opens. Mirrors vettid-android `OnboardingViewModel`'s `TRANSFER_WAITING`
/// route and `TransferInViewModel`'s `init`.
@MainActor
@Suite struct TransferWaitingTests {
    let vault = FakeVaultRepository()
    let clock = VirtualTime()

    func onboarding() -> OnboardingViewModel { OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox()) }
    func transferIn() -> TransferInViewModel { TransferInViewModel(move: vault, vault: vault, now: clock.now, sleep: clock.sleep) }

    /// At a start with a transfer waiting, with or without a redeemed code: the move screen, never the account's
    /// confirmation or the PIN.
    @Test func aWaitingTransferAtTheStartOpensTheMoveScreen() async {
        vault.phase = .setup(.transferWaiting)
        let vm = onboarding()
        await vm.settle()
        #expect(vm.state.step == .transferIn)
    }

    /// The phase turning to it later moves any step to the move screen; once the transfer ended, the move screen stays (it
    /// shows its own end), as a recovery's does.
    @Test(arguments: [AppPhase.signedOut, .setup(.newVault)])
    func aWaitingTransferLaterOpensTheMoveScreenAndItStays(_ before: AppPhase) async {
        vault.phase = before
        let vm = onboarding()
        await vm.settle()
        #expect(vm.state.step == (before == .signedOut ? .welcome : .confirmAccount))
        vault.phase = .setup(.transferWaiting)
        await vm.settle()
        #expect(vm.state.step == .transferIn)
        vault.phase = before
        await vm.settle()
        #expect(vm.state.step == .transferIn, "the move screen shows how it ended")
    }

    /// The screen opens on the waiting transfer: its code, counted from its stored start, and the approval completes it.
    @Test func theScreenOpensOnTheWaitingTransfer() async throws {
        let started = clock.now().addingTimeInterval(-30)
        vault.waitingTransfer = .waiting(sas: "553190", startedAt: started)
        let vm = transferIn()
        await clock.runCurrent()
        #expect(await eventually { vm.state.step == .compare }, "\(vm.state.step)")
        #expect(vm.state.sas == "553190" && vm.state.secondsLeft == 630 && vm.state.deadline == started.addingTimeInterval(660))
        #expect(vault.calls.contains("awaitTransferIn"))
        vault.transferApproval.complete()
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .done && vm.state.sas == nil)
    }

    /// Past the vault's 10 minutes: the settlement's check, no Cancel.
    @Test func theScreenOpensOnTheSettlement() async throws {
        vault.waitingTransfer = .waiting(sas: "553190", startedAt: clock.now().addingTimeInterval(-640))
        vault.abandonClosed = true
        let vm = transferIn()
        await clock.runCurrent()
        #expect(await eventually { vm.state.step == .compare && vm.state.checking && vm.state.closing })
        vault.transferApproval.fail(VaultFailure(.noResponse, code: VaultManager.codeTransferDeadline))
        await vm.settle()
        #expect(vm.state.step == .timedOut)
    }

    /// A move that stopped on this phone before the member was told: "The move stopped on this phone", once.
    @Test func aStoppedMoveIsToldOnce() async throws {
        vault.waitingTransfer = .stopped
        let vm = transferIn()
        #expect(await eventually { vm.state.step == .stopped }, "\(vm.state.step)")
        #expect(!vault.calls.contains("awaitTransferIn"))
        let again = transferIn()
        await again.settle()
        #expect(again.state.step == .intro)
    }

    /// Nothing waiting: the screen starts afresh.
    @Test func nothingWaitingStartsAfresh() async {
        let vm = transferIn()
        await vm.settle()
        #expect(vm.state.step == .intro && !vault.calls.contains("awaitTransferIn"))
    }

    /// A scan begun before the answer came is the member's: the waiting transfer is handed back to the background.
    @Test func aScanBegunMeanwhileHandsTheWaitBack() async throws {
        vault.waitingTransfer = .waiting(sas: "553190", startedAt: clock.now())
        let vm = transferIn()
        vm.scan()
        await vm.settle()
        #expect(vm.state.step == .scan && !vault.calls.contains("awaitTransferIn"))
        #expect(vault.calls.contains("waitForTransferInBackground"))
    }
}
