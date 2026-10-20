import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The unlock screen's way back to release N (IOS-PLAN §4.3 point 3), the "being deleted" screen's Check again and the
/// one-time notice on the welcome screen (IOS-PLAN §4.2).
@MainActor
@Suite struct DeletingAndReturnTests {
    let vault = FakeVaultRepository(.locked)

    static func move(failed: Bool) -> UnconfirmedMove {
        UnconfirmedMove(
            from: ReleaseView(number: 3, pcr0: String(repeating: "aa", count: 48), status: "", endsAt: nil, notes: ""),
            to: ReleaseView(number: 4, pcr0: String(repeating: "a4", count: 48), status: "", endsAt: nil, notes: ""),
            failed: failed
        )
    }

    func unlockModel() async -> UnlockViewModel {
        let vm = UnlockViewModel(vault: vault, account: vault)
        await vm.settle()
        return vm
    }

    /// Offered only with the marker and its `failed`; without either, the question does not even open.
    @Test func returnIsOfferedOnlyAfterAFailedUnlockOnTheNewRelease() async {
        let vm = await unlockModel()
        #expect(!vm.state.returnOffered)
        vm.askReturn()
        #expect(!vm.state.returnConfirm)
        vault.unconfirmedMove = Self.move(failed: false)
        await vm.settle()
        #expect(!vm.state.returnOffered)
        vault.unconfirmedMove = Self.move(failed: true)
        await vm.settle()
        #expect(vm.state.returnOffered)
        vault.unconfirmedMove = nil
        await vm.settle()
        #expect(!vm.state.returnOffered, "cleared with the marker")
    }

    /// The PIN goes to release N only on the confirmed tap: the unlock screen's PIN when typed, else the keypad asks first.
    @Test func thePinGoesToReleaseNOnlyOnTheTap() async {
        vault.unconfirmedMove = Self.move(failed: true)
        let vm = await unlockModel()
        vm.askReturn()
        #expect(vm.state.returnConfirm && vault.returnPins.isEmpty)
        vm.dismissReturn()
        #expect(!vm.state.returnConfirm && vault.returnPins.isEmpty)
        // A plain unlock never goes back.
        vm.setPin("402817")
        vm.submit()
        await vm.settle()
        #expect(vault.returnPins.isEmpty && vault.calls.contains("unlock"))
        // Confirmed with the PIN typed: it goes to the way back.
        vm.askReturn()
        vm.setPin("402817")
        vm.confirmReturn()
        #expect(vault.returnPins == ["402817"] && vm.state.pin.isEmpty)
        // Confirmed without a PIN: the keypad asks for it, and the primary action sends it to the way back.
        vm.askReturn()
        vm.confirmReturn()
        #expect(vm.state.returnAsksPin && vault.returnPins.count == 1)
        vm.setPin("402817")
        vm.submit()
        await vm.settle()
        #expect(vault.returnPins.count == 2 && !vm.state.returnAsksPin)
    }

    /// Check again: "not finished yet" while listed, the unreachable text, nothing once gone; the bound's state followed.
    @Test func checkAgainSaysWhatItFound() async {
        vault.deletion = VaultDeletion(since: Date(), until: Date())
        vault.deletionReads = [.listed, .unreachable, .gone]
        let vm = VaultDeletingViewModel(account: vault)
        #expect(!vm.state.slow)
        vault.deletion?.slow = true
        await Task.yield()
        for _ in 0..<20 where !vm.state.slow { await Task.yield() }
        #expect(vm.state.slow)
        vm.checkAgain()
        vm.checkAgain()
        await vm.settle()
        #expect(vm.state.note == .still && vault.calls.filter { $0 == "checkDeletionAgain" }.count == 1)
        vm.checkAgain()
        await vm.settle()
        #expect(vm.state.note == .unreachable)
        vm.checkAgain()
        await vm.settle()
        #expect(vm.state.note == nil && !vm.state.checking)
    }

    /// The notice on the welcome screen, once: kept through the welcome's reset, gone when seen.
    @Test func theDeletedNoticeShowsOnce() async {
        let account = FakeVaultRepository(.signedOut)
        account.vaultDeletedNotice = true
        let vm = OnboardingViewModel(account: account, vault: account, inbox: SetupLinkInbox())
        for _ in 0..<5 { await Task.yield() }
        #expect(vm.state.deletedNotice)
        vm.dismissDeletedNotice()
        #expect(!vm.state.deletedNotice && !account.vaultDeletedNotice)
    }
}
