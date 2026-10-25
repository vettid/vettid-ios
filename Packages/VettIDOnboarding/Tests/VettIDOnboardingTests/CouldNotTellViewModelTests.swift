import Foundation
import Testing
import VettIDAltChan
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// A phone that could not tell whether an open recovered the vault (IOS-PLAN 0.1.33 §4.9), as the recovery view models show it.
/// The data layer's rule is `VaultManagerCouldNotTellTests` and `VaultManagerCouldNotTellRegisterTests` of VettIDData.
@MainActor
@Suite struct CouldNotTellViewModelTests {
    let vault = FakeVaultRepository(.setup(.recovering))
    let clock = VirtualTime()
    let vid = "0123456789abcdef0123456789abcdef"
    let rid = "01JA0RECVERY0000000000001X"
    let code = "SK01TG8WK2FYJ1Y5MEHJ5R5J7QZKWHX0"
    let api = "https://account.vettid.org"

    var qr: String { #"{"v":1,"t":"r","api":"\#(api)","vault_id":"\#(vid)","recovery_id":"\#(rid)","code":"\#(code)"}"# }

    init() { vault.phoneSecret = true }

    func recover() async -> RecoverViewModel {
        let vm = RecoverViewModel(move: vault, vault: vault, account: vault, tick: clock.tick)
        await vm.settle()
        return vm
    }

    func open() async -> RecoveryOpenViewModel {
        let vm = RecoveryOpenViewModel(move: vault, account: vault)
        await vm.settle()
        return vm
    }

    @Test func aPhoneThatCouldNotTellStartsAtItsText() async throws {
        vault.recoveryStageValue = .pin
        vault.couldNotTellChecks = [.newCode]
        let vm = await recover()
        #expect(vm.state.step == .couldNotTell && vm.state.couldNotTell == .newCode)
        #expect(vault.calls.contains("checkCouldNotTell"))
        // The same after the new identity was made and its register was refused: the code step, as `.code` says.
        vault.recoveryStageValue = .code
        #expect(await recover().state.step == .couldNotTell)
    }

    @Test func aPhoneWithNothingToTellStartsWhereItStood() async throws {
        vault.recoveryStageValue = .pin
        #expect(await recover().state.step == .open)
        vault.recoveryStageValue = .code
        #expect(await recover().state.step == .intro)
        // A read that fails decides nothing.
        vault.recoveryStageValue = .pin
        vault.fail["checkCouldNotTell"] = VaultFailure(.network)
        #expect(await recover().state.step == .open)
    }

    @Test func theCodeStepsOfTheRuleReturnToItsText() async throws {
        vault.recoveryStageValue = .pin
        vault.couldNotTellChecks = [.newCode]
        let vm = await recover()
        vm.scan()
        #expect(vm.state.step == .scan)
        #expect(vm.back() && vm.state.step == .couldNotTell)
        vm.type()
        #expect(vm.state.step == .type)
        #expect(vm.back() && vm.state.step == .couldNotTell)
        // A scan that is refused stays on the scan step with the refusal, and a registered code leads to the open.
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vault.lastRegistered?.recoveryID == rid && vm.state.step == .open)
    }

    @Test func aKeyInUseSendsTheMemberToThePinOfTheLostOkFinish() async throws {
        vault.recoveryStageValue = .pin
        vault.couldNotTellChecks = [.newCode]
        vault.registrations = [.refused(code: VaultManager.codeKeyInUse)]
        let vm = await recover()
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.step == .open && vm.state.couldNotTell == .finishWithPin && vm.state.refusal == nil && !vm.state.busy)
        // The open screen starts at the PIN of the finish, nothing registered over it.
        vault.couldNotTellValue = .finishWithPin
        let open = await open()
        #expect(open.state.step == .finish && open.state.lostOk && open.state.couldNotTell == .finishWithPin)
        // An earlier open answered `ok` after all: the same.
        vault.registrations = [.refused(code: VaultManager.codeRecoveryOpenSent)]
        vault.couldNotTellValue = .newCode
        let again = await recover()
        again.scan()
        again.scanned(qr)
        await again.settle()
        #expect(again.state.step == .open && again.state.couldNotTell == .finishWithPin)
    }

    @Test func aTypedCodeThatIsAKeyInUseIsTheSame() async throws {
        vault.recoveryStageValue = .pin
        vault.couldNotTellChecks = [.newCode]
        vault.registrations = [.refused(code: VaultManager.codeKeyInUse)]
        let vm = await recover()
        vm.type()
        vm.setTyped("7ZK3M9QX2HTD" + "CDEFGHJKMNPQRSTVWXYZ0123456789AB" + "V3A1")
        vm.submitTyped()
        await vm.settle()
        #expect(vm.state.step == .open && vm.state.couldNotTell == .finishWithPin && vm.state.typed.isEmpty)
    }

    @Test func theSecondTextAfterADayOfRefusals() async throws {
        vault.couldNotTellValue = .contact
        let open = await open()
        #expect(open.state.contactVettID && open.state.step == .finish && open.state.lostOk)
        // The PIN still tries; an unlock that opens finishes the recovery and the text goes.
        open.setPin("975310")
        open.send()
        await open.settle()
        #expect(vault.calls.contains("resumeLostOk") && open.state.step == .done)
    }

    @Test func aTransferIncompleteAnswerOpensAgainAndAsksWhereTheRuleStands() async throws {
        vault.lostOkOutcomes = [RecoveryOpenOutcome("transfer_incomplete", opened: true, attemptUsed: false)]
        let open = await open()
        open.finishLostOk()
        // The recovery no longer shows `registered`: the rule applies.
        vault.couldNotTellValue = .newCode
        open.setPin("975310")
        open.send()
        await open.settle()
        #expect(open.state.step == .enter && open.state.outcome == nil && open.state.pin.isEmpty && !open.state.lostOk)
        #expect(open.state.couldNotTell == .newCode)
        // The recovery flow shows the text of the rule when it is asked.
        vault.recoveryStageValue = .pin
        let vm = await recover()
        #expect(vm.state.step == .couldNotTell)
    }

    @Test func checkingAgainFollowsTheRule() async throws {
        vault.recoveryStageValue = .pin
        let vm = await recover()
        #expect(vm.state.step == .open)
        vault.couldNotTellChecks = [.waiting(until: Date().addingTimeInterval(300)), .newCode]
        vm.checkEnded()
        await vm.settle()
        #expect(vm.state.step == .open && vm.state.couldNotTell != .newCode)
        vm.checkEnded()
        await vm.settle()
        #expect(vm.state.step == .couldNotTell && vm.state.couldNotTell == .newCode)
        // The recovery shows `registered` again (or nothing is decided): back to the open.
        vault.couldNotTellChecks = [.none]
        vm.checkEnded()
        await vm.settle()
        #expect(vm.state.step == .open)
    }

    @Test func onlyTheOpenAndTheTextAreChecked() async throws {
        vault.recoveryStageValue = .code
        let vm = await recover()
        #expect(vm.state.step == .intro)
        let before = vault.calls.filter { $0 == "checkCouldNotTell" }.count
        vm.checkEnded()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "checkCouldNotTell" }.count == before)
    }

    @Test func theRuleNeverStartsOverOrForgets() async throws {
        vault.recoveryStageValue = .pin
        vault.couldNotTellChecks = [.newCode]
        let vm = await recover()
        // "Start over" is only on the open step; the text of the rule has none.
        vm.askStartOver()
        #expect(!vm.state.confirmStartOver)
        #expect(!vault.calls.contains("abandonRecovery"))
    }
}

extension CouldNotTellViewModelTests {
    @Test func aCheckThatFailsChangesNothing() async throws {
        vault.recoveryStageValue = .pin
        vault.couldNotTellChecks = [.newCode]
        let vm = await recover()
        #expect(vm.state.step == .couldNotTell)
        vault.fail["checkCouldNotTell"] = VaultFailure(.network)
        vm.checkEnded()
        await vm.settle()
        #expect(vm.state.step == .couldNotTell && vm.state.couldNotTell == .newCode)
        // The same at the start: what the phone keeps decides when the read fails.
        vault.fail["checkCouldNotTell"] = VaultFailure(.network)
        let again = await recover()
        #expect(again.state.step == .couldNotTell)
    }
}
