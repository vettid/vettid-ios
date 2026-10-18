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
}
