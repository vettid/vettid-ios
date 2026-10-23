import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// The old phone's side of a direct transfer (VAULT-MESSAGING §6.7.1, §11.7.1, §11.14.10). Mirrors vettid-android
/// `TransferOutViewModelTest`, test for test, on a virtual clock.
@MainActor
@Suite struct TransferOutViewModelTests {
    static let codeSeconds: Int64 = 600
    let vault = FakeVaultRepository(.unlocked)
    let clock = VirtualTime()
    let pending = TransferPendingView(transferID: "01JTRANSFER000000000000000", name: "Pixel 10 Pro", sas: "042817")

    init() {
        vault.offer = TransferOfferView(
            transferID: "01JTRANSFER000000000000000", qrPayload: "{}", link: "link",
            expiresAt: clock.now().addingTimeInterval(TimeInterval(Self.codeSeconds))
        )
    }

    func model() -> TransferOutViewModel {
        TransferOutViewModel(move: vault, vault: vault, now: clock.now, sleep: clock.sleep)
    }

    func atCompare(_ vm: TransferOutViewModel, _ p: TransferPendingView) async {
        vm.create()
        await clock.runCurrent()
        vault.pendingTransfer.complete(p)
        await clock.runCurrent()
        #expect(vm.state.step == .compare)
    }

    func type(_ vm: TransferOutViewModel, pin: String = "975310", password: String = "correct horse battery") {
        vm.setPin(pin)
        vm.setPassword(password)
    }

    @Test func showCompareApproveMovesTheVault() async {
        let vm = model()
        vm.create()
        await clock.runCurrent()
        #expect(vm.state.step == .showing && vm.state.offer?.link == "link")
        vault.pendingTransfer.complete(pending)
        await clock.runCurrent()
        #expect(vm.state.step == .compare && vm.state.pending?.sas == "042817")
        vm.codesMatch()
        #expect(vm.state.step == .approve)
        vm.setPin("975310")
        #expect(!vm.state.canApprove)
        vm.setPassword("correct horse battery")
        #expect(vm.state.canApprove)
        vm.askApprove(true)
        #expect(vm.state.confirmApprove && !vault.calls.contains("transferApprove"))
        vm.approve()
        await clock.runCurrent()
        #expect(vault.lastTransferApproved == pending.transferID && vault.lastPin == "975310")
        #expect(vault.lastPassword == "correct horse battery")
        // The vault's device.unlinked{transferred} followed: this phone erased itself (welcome screen).
        #expect(vault.phase == .signedOut && vm.state.pin.isEmpty && vm.state.password.isEmpty)
        vm.leave()
        #expect(!vault.calls.contains("transferReject"), "leaving after the approval rejects nothing")
    }

    /// Release R (§11.14.10): after the approval this phone keeps its keys for up to 7 days, and the step says so.
    @Test func aReleaseRApprovalSaysThisPhoneKeepsItsKeys() async {
        vault.transferConfirmed = false
        let vm = model()
        await atCompare(vm, pending)
        vm.codesMatch()
        type(vm)
        vault.transferKeptSince = FakeVaultRepository.date("2026-10-16T10:00:00Z")
        vm.approve()
        await clock.runCurrent()
        #expect(vm.state.step == .moved && vm.state.keptKeys)
        #expect(vm.state.keptForSeconds == 7 * 86_400 && vm.state.keptForText == "7 days" && vm.state.stagingNote == nil)
    }

    /// STAGING-TIME-SCALE S10: the keep period is divided by the vault's time scale, and a staging build adds its note.
    @Test func aScaledVaultShortensTheKeepAndAddsItsNote() async {
        vault.transferConfirmed = false
        vault.timeScale = 24
        vault.transferKeptSince = FakeVaultRepository.date("2026-10-16T10:00:00Z")
        let vm = model()
        await atCompare(vm, pending)
        vm.codesMatch()
        type(vm)
        vm.approve()
        await clock.runCurrent()
        #expect(vm.state.keptForSeconds == 7 * 3_600 && vm.state.keptForText == "7 hours")
        #expect(vm.state.stagingNote == "Staging: 1 day = 1 hour")
    }

    @Test func anApprovalTheVaultHasNotConfirmedYetSaysTheVaultMoved() async {
        vault.transferConfirmed = false
        let vm = model()
        await atCompare(vm, pending)
        vm.codesMatch()
        type(vm)
        vm.approve()
        await clock.runCurrent()
        #expect(vm.state.step == .moved && vault.phase == .unlocked, "not wiped on the {} alone")
        #expect(vm.state.pin.isEmpty && vm.state.password.isEmpty && !vm.state.keptKeys)
        vm.leave()
        #expect(!vault.calls.contains("transferReject"))
    }

    @Test func aMismatchRejects() async {
        let vm = model()
        await atCompare(vm, pending)
        vm.askReject(true)
        #expect(vm.state.confirmReject)
        vm.reject()
        await clock.runCurrent()
        #expect(vault.lastTransferRejected == pending.transferID && vm.state.step == .rejected)
        #expect(vault.lastTransferApproved == nil)
    }

    @Test func theCodeExpiresWithoutAScan() async {
        let vm = model()
        vm.create()
        await clock.runCurrent()
        vault.pendingTransfer.complete(nil)
        await clock.runCurrent()
        #expect(vm.state.step == .expired && vm.state.offer == nil)
    }

    @Test func theCountdownEndsTheCodeAtItsDeadline() async {
        let vm = model()
        vm.create()
        await clock.runCurrent()
        #expect(vm.state.step == .showing && vm.state.secondsLeft == Self.codeSeconds)
        await clock.advance(seconds: Self.codeSeconds - 2)
        #expect(vm.state.step == .showing && (1...2).contains(vm.state.secondsLeft))
        await clock.advance(seconds: 3)
        #expect(vm.state.step == .expired && vm.state.secondsLeft == 0 && vm.state.offer == nil)
    }

    @Test func aWrongPinKeepsTheTransferOpenAndCountsTheWaitDown() async {
        let vm = model()
        await atCompare(vm, pending)
        vm.codesMatch()
        type(vm, pin: "111111", password: "pw")
        vault.fail["transferApprove"] = FakeVaultRepository.failure(.badPin, code: "bad_pin", retry: 30)
        vm.approve()
        await clock.advance(seconds: 1)
        #expect(vm.state.step == .approve && vm.state.error == .badPin && vm.state.pin.isEmpty)
        #expect((1...30).contains(vm.state.waitSeconds) && vault.phase == .unlocked)
        // Nothing is approved during the wait, whatever is typed.
        type(vm, pin: "975310", password: "pw")
        #expect(!vm.state.canApprove)
        await clock.advance(seconds: 30)
        #expect(vm.state.waitSeconds == 0 && vm.state.canApprove)
        vm.leave()
    }

    /// VAULT-MESSAGING 0.27.0 §6.7.1, §11.7.1; ANDROID-PLAN 0.1.36 §7: a new phone whose VettID has another signer is named
    /// before the PIN is asked for, and the approval carries the class the vault named.
    @Test func aChangeOfSignerIsConfirmedBeforeThePin() async {
        vault.transferSignerRequired = "google_play"
        let vm = model()
        await atCompare(vm, TransferPendingView(
            transferID: pending.transferID, name: pending.name, sas: pending.sas, signer: "google_play", signerChanged: true,
            currentSigner: .vettid
        ))
        vm.codesMatch()
        #expect(vm.state.step == .signer && !vm.state.signerConfirmed)
        #expect(vm.state.signerBody?.contains("installed from Google Play") == true)
        // Nothing is approved from the confirmation step, whatever is typed.
        type(vm, pin: "111111", password: "pw")
        vm.approve()
        await clock.runCurrent()
        #expect(!vault.calls.contains("transferApprove"))
        vm.confirmSigner()
        #expect(vm.state.step == .approve && vm.state.signerConfirmed)
        vm.askApprove(true)
        vm.approve()
        await clock.runCurrent()
        #expect(vault.transferSigners == ["google_play"] && vault.lastTransferApproved == vault.offer.transferID)
        #expect(vault.phase == .signedOut)
    }

    /// Cancel on the confirmation rejects the transfer (after the usual confirmation), so the code cannot be used.
    @Test func theChangeOfSignerCanBeRefused() async {
        let vm = model()
        await atCompare(vm, TransferPendingView(
            transferID: pending.transferID, name: pending.name, sas: pending.sas, signer: "development", signerChanged: true,
            currentSigner: .vettid
        ))
        vm.codesMatch()
        #expect(vm.state.step == .signer)
        vm.askReject(true)
        #expect(vm.state.confirmReject)
        vm.reject()
        await clock.runCurrent()
        #expect(vm.state.step == .rejected && vault.lastTransferRejected == vault.offer.transferID)
        #expect(!vault.calls.contains("transferApprove"))
    }

    /// The same signer, or a vault from before 0.27.0: no confirmation and no `signer` in the approval.
    @Test func theSameSignerAsksNothingAndSendsNoSigner() async {
        vault.transferSignerClass = "vettid"
        let vm = model()
        await atCompare(vm, TransferPendingView(
            transferID: pending.transferID, name: pending.name, sas: pending.sas, signer: "vettid", signerChanged: false
        ))
        vm.codesMatch()
        #expect(vm.state.step == .approve)
        type(vm, pin: "111111", password: "pw")
        vm.approve()
        await clock.runCurrent()
        #expect(vault.transferSigners == [nil] && vault.phase == .signedOut)
    }

    @Test func aPendingWithoutSignerMembersIsApprovedAsBefore() async {
        let vm = model()
        await atCompare(vm, pending)
        vm.codesMatch()
        #expect(vm.state.step == .approve)
        type(vm, pin: "111111", password: "pw")
        vm.approve()
        await clock.runCurrent()
        #expect(vault.transferSigners == [nil] && vault.phase == .signedOut)
    }

    /// `signer_unconfirmed` (the vault's binding changed after its pending said "unchanged"): not a wrong PIN, no wait; the
    /// confirmation is shown and the next approval names the class. The transfer stays open throughout.
    @Test func anUnconfirmedSignerAsksForTheConfirmationAndRetries() async {
        vault.transferSignerRequired = "google_play"
        let vm = model()
        await atCompare(vm, TransferPendingView(
            transferID: pending.transferID, name: pending.name, sas: pending.sas, signer: "google_play", signerChanged: false
        ))
        vm.codesMatch()
        type(vm, pin: "111111", password: "pw")
        vm.approve()
        await clock.runCurrent()
        let s = vm.state
        #expect(s.step == .signer && s.signerUnconfirmed && s.error == nil && s.waitSeconds == 0)
        #expect(s.pin.isEmpty && s.password.isEmpty && !s.busy)
        #expect(vault.phase == .unlocked && vault.lastTransferRejected == nil)
        vm.confirmSigner()
        type(vm, pin: "111111", password: "pw")
        vm.approve()
        await clock.runCurrent()
        #expect(vault.transferSigners == [nil, "google_play"] && vault.phase == .signedOut)
    }

    /// A vault that wants a confirmation but never named a class: there is nothing to confirm with; no loop.
    @Test func anUnconfirmedSignerWithoutAClassIsAPlainFailure() async {
        vault.transferSignerRequired = "google_play"
        let vm = model()
        await atCompare(vm, pending)
        vm.codesMatch()
        type(vm, pin: "111111", password: "pw")
        vm.approve()
        await clock.runCurrent()
        #expect(vm.state.step == .approve && vm.state.error == .other && vm.state.errorCode == "signer_unconfirmed")
        #expect(vault.transferSigners.count == 1)
        vm.leave()
    }

    /// The approval window still runs on the confirmation step.
    @Test func theConfirmationStepExpiresWithTheTransfer() async {
        let vm = model()
        await atCompare(vm, TransferPendingView(
            transferID: pending.transferID, name: pending.name, sas: pending.sas, signer: "google_play", signerChanged: true
        ))
        vm.codesMatch()
        #expect(vm.state.step == .signer)
        await clock.advance(seconds: 601)
        #expect(vm.state.step == .expired && !vm.state.signerConfirmed)
    }

    @Test func leavingCancelsTheOpenTransfer() async {
        let vm = model()
        vm.create()
        await clock.runCurrent()
        vm.leave()
        await clock.runCurrent()
        #expect(vault.lastTransferRejected == vault.offer.transferID && vm.state.step == .intro)
    }

    @Test func anOpenTransferIsReported() async {
        vault.fail["transferCreate"] = FakeVaultRepository.failure(.other, code: "exists")
        let vm = model()
        vm.create()
        await clock.runCurrent()
        #expect(vm.state.step == .intro && vm.state.errorCode == "exists" && !vm.state.busy)
    }

    /// The pending's failure ends the code's wait: expired, with the failure said.
    @Test func aFailureWhileWaitingForTheScanEndsTheCode() async {
        let vm = model()
        vm.create()
        await clock.runCurrent()
        vault.pendingTransfer.fail(FakeVaultRepository.failure(.network))
        await clock.runCurrent()
        #expect(vm.state.step == .expired && vm.state.error == .network)
    }

    /// Leaving while `device.transfer.create` is on its way: the late offer does not bring the code back.
    @Test func aLateOfferAfterLeavingDoesNotShowTheCode() async {
        let gate = TestDeferred<Void>()
        vault.transferCreateGate = gate
        let vm = model()
        vm.create()
        await clock.runCurrent()
        vm.leave()
        gate.complete()
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .intro && vm.state.offer == nil && !vm.state.busy && vm.state.error == nil)
    }

    /// The same when the create returns in the very instant of leaving: the code is shown nowhere, and cancelled at the vault.
    @Test func anOfferThatReturnsAfterLeavingIsCancelledAtTheVault() async {
        let gate = TestDeferred<Void>()
        vault.transferCreateGate = gate
        let vm = model()
        vm.create()
        await clock.runCurrent()
        gate.complete()
        vm.leave() // before the model's task can run again
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .intro && vm.state.offer == nil)
        #expect(vault.lastTransferRejected == vault.offer.transferID)
    }

    @Test func aPendingThatReturnsAfterLeavingChangesNothing() async {
        let vm = model()
        vm.create()
        await clock.runCurrent()
        vault.pendingTransfer.complete(pending)
        vm.leave()
        await clock.advance(seconds: 2)
        #expect(vm.state.step == .intro && vm.state.pending == nil)
    }

    /// A dropped model deinits although its tasks wait: they hold it weakly.
    @Test func aDroppedModelDeinitsWhileItsTasksWait() async {
        weak var weakModel: TransferOutViewModel?
        do {
            let vm = model()
            weakModel = vm
            vm.create()
            await clock.runCurrent()
            #expect(vm.state.step == .showing)
        }
        await clock.advance(seconds: 3)
        #expect(weakModel == nil)
    }

    @Test func thePinKeepsOnlyDigitsUpToTheLimit() {
        let vm = model()
        vm.setPin("12ab34-56" + String(repeating: "7", count: 40))
        #expect(vm.state.pin.count == 32 && vm.state.pin.allSatisfy { $0.isNumber })
    }

    @Test func theStateNamesNoSecret() async {
        let vm = model()
        await atCompare(vm, pending)
        vm.codesMatch()
        type(vm, pin: "975310", password: "correct horse battery")
        let text = "\(vm.state) \(String(reflecting: vm.state))"
        #expect(!text.contains("975310") && !text.contains("correct horse") && !text.contains("042817"))
        vm.leave()
    }
}
