import Foundation
import Testing
import VettIDAltChan
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The parts of the iOS port that vettid-android's test does not cover: the typed code's grouping, the state's
/// descriptions, back navigation, the followed "Finish the move" flag, and the model's tasks ending with it.
@MainActor
@Suite struct OnboardingModelTests {
    @Test func theTypedCodeIsGroupedAsItFills() {
        #expect(SetupCodeFormat.grouped("") == "")
        #expect(SetupCodeFormat.grouped("k7q") == "K7Q")
        #expect(SetupCodeFormat.grouped("k7qm") == "K7QM", "no separator before there is a fifth character")
        #expect(SetupCodeFormat.grouped("k7qm4") == "K7QM-4")
        #expect(SetupCodeFormat.grouped("K7QM-4XRP") == "K7QM-4XRP")
        #expect(SetupCodeFormat.grouped("k7 qm\u{00A0}4x-rp") == "K7QM-4XRP")
        #expect(SetupCodeFormat.grouped("K7QM-") == "K7QM", "a deleted fifth character takes its separator")
        #expect(SetupCodeFormat.grouped("K7QM4XRPAB") == "K7QM-4XRP-AB")
        // What a code never contains stays visible, so the field shows the refusal's reason.
        #expect(SetupCodeFormat.grouped("k7q0é") == "K7Q0-é")
        let grouped = SetupCodeFormat.grouped("k7qm4xrp")
        #expect(SetupCodes.normalize(grouped) == "K7QM4XRP")
        #expect(!SetupCodes.hasForeignCharacter(grouped))
    }

    static let qr = #"{"v":1,"t":"e","api":"https://account.vettid.org","s":"AbCdEfGhIjKlMnOpQrStUv"}"#

    /// (Chosen; not in the spec) The camera keeps reading the QR whose redeem failed: it is not redeemed again until
    /// another text is read, or the scan screen is opened anew.
    @Test func aFailedScanIsNotRedeemedAgainAtOnce() async {
        let vault = FakeVaultRepository()
        let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox())
        vm.start()
        vault.fail["redeemSetupCode"] = FakeVaultRepository.failure(.network)
        vm.scanned(Self.qr)
        await vm.settle()
        #expect(vm.state.error == .network)
        vm.scanned(Self.qr)
        vm.scanned(Self.qr)
        await vm.settle()
        #expect(vault.calls.filter { $0 == "redeemSetupCode" }.count == 1)
        // Another text, then the same QR: redeemed.
        vm.scanned("hello")
        #expect(vm.state.scanRefusal == .notACode)
        vault.fail["redeemSetupCode"] = FakeVaultRepository.failure(.network)
        vm.scanned(Self.qr)
        await vm.settle()
        #expect(vault.calls.filter { $0 == "redeemSetupCode" }.count == 2)
        // Leaving the scan screen and coming back: redeemed again.
        #expect(vm.back())
        vm.start()
        vm.scanned(Self.qr)
        await vm.settle()
        #expect(vault.calls.filter { $0 == "redeemSetupCode" }.count == 3)
        #expect(vm.state.step == .confirmAccount)
    }

    /// A second tap (or the keyboard's Done) while the first runs sends nothing more.
    @Test func aDoubleSubmitSendsOnce() async {
        let vault = FakeVaultRepository()
        let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox())
        vm.start()
        vm.typeCode()
        vm.setEmail("sam@example.org")
        vm.setCode("K7QM-4XRP")
        vm.submitCode()
        vm.submitCode()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "redeemSetupCode" }.count == 1)
        #expect(vm.state.step == .confirmAccount)

        vm.confirmAccount()
        vm.setPin("40281795"); vm.submitPin(); vm.setPinConfirm("40281795"); vm.submitPinConfirm()
        vm.setPassword("correct horse battery staple"); vm.setPasswordConfirm("correct horse battery staple"); vm.submitPassword()
        vm.submitBackup()
        vm.submitBackup()
        vm.run()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "enroll" }.count == 1)
        #expect(vault.calls.filter { $0 == "createCredential" }.count == 1)
        #expect(vm.state.step == .done)
    }

    /// A failed finishSetup is shown and can be tried again; a second tap while it runs asks once.
    @Test func aFailedFinishIsShown() async {
        let vault = FakeVaultRepository(.setup(.finishing))
        let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox())
        vault.fail["finishSetup"] = FakeVaultRepository.failure(.network)
        vm.finish()
        vm.finish()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "finishSetup" }.count == 1)
        #expect(vm.state.error == .network && !vm.state.busy)
        vm.finish()
        await vm.settle()
        #expect(vault.phase == .unlocked)
    }

    /// The refresh after leaving a move shows its failure, without holding the next screen busy.
    @Test func aFailedRefreshAfterAMoveIsShown() async {
        let vault = FakeVaultRepository()
        let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox())
        vm.startTransfer()
        vault.fail["refresh"] = FakeVaultRepository.failure(.network)
        vm.leaveMove()
        #expect(!vm.state.busy)
        await vm.settle()
        #expect(vm.state.step == .welcome && vm.state.error == .network)
    }

    @Test func theStateNamesNoSecret() {
        var s = OnboardingState(step: .password)
        s.pin = "40281795"
        s.password = "correct horse battery staple"
        s.email = "sam@example.org"
        s.codeInput = "K7QM-4XRP"
        for text in [s.description, s.debugDescription, String(reflecting: s), "\(s)"] {
            #expect(!text.contains("40281795") && !text.contains("horse") && !text.contains("sam@") && !text.contains("K7QM"))
        }
        #expect(Mirror(reflecting: s).children.isEmpty)
    }

    @Test func backFollowsTheSteps() async {
        let vault = FakeVaultRepository()
        let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox())
        #expect(!vm.back(), "nothing before the welcome screen")
        vm.start()
        vm.typeCode()
        vm.setCode("K7Q0")
        #expect(vm.state.codeInvalid)
        #expect(vm.back())
        #expect(vm.state.step == .setupScan && !vm.state.codeInvalid)
        #expect(vm.back())
        #expect(vm.state.step == .welcome)

        vm.confirmAccount()
        vm.setPin("40281795"); vm.submitPin(); vm.setPinConfirm("40281795"); vm.submitPinConfirm()
        vm.setPassword("correct horse battery staple")
        #expect(vm.back())
        #expect(vm.state.step == .pinConfirm && vm.state.password.isEmpty && vm.state.passwordRule == .short)
        vm.setPinConfirm("4028")
        #expect(vm.back())
        #expect(vm.state.step == .pinCreate && vm.state.pinConfirm.isEmpty)
        await vm.settle()
    }

    @Test func finishMovePendingIsFollowed() async {
        let vault = FakeVaultRepository()
        vault.finishMovePending = true
        let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox())
        #expect(vm.state.finishMovePending, "the current value at once")
        vault.finishMovePending = false
        await vm.settle()
        #expect(!vm.state.finishMovePending)
    }

    @Test func theModelGoesWithItsTasks() async {
        let vault = FakeVaultRepository()
        weak var gone: OnboardingViewModel?
        do {
            let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox())
            gone = vm
            vm.start()
            vm.scanned(#"{"v":1,"t":"e","api":"https://account.vettid.org","s":"AbCdEfGhIjKlMnOpQrStUv"}"#)
            await vm.settle()
            #expect(vm.state.step == .confirmAccount)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(gone == nil)
        // A change after it went reaches nobody.
        vault.phase = .signedOut
        for _ in 0..<10 { await Task.yield() }
    }
}
