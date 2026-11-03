import Testing
@testable import VettIDSettings

/// Which states hold a due daily check (VAULT-MESSAGING §3.6.5: the check must not interrupt a credential operation): a
/// started one from the moment its screen opens until it is done or sent, typed or not.
@Suite struct HoldsInputTests {
    @Test func theAlarmHoldsFromTheQuestionUntilResolved() {
        for step in [AlarmStep.ask, .confirmMine, .confirmNotMine, .rotate] { #expect(AlarmState(step: step).holdsInput) }
        #expect(!AlarmState(step: .resolved).holdsInput)
    }

    @Test func aTransferHoldsUntilItEnds() {
        var s = TransferOutState()
        for step in [TransferOutStep.intro, .showing, .compare, .signer, .approve] {
            s.step = step
            #expect(s.holdsInput)
        }
        for step in [TransferOutStep.expired, .rejected, .moved] {
            s.step = step
            #expect(!s.holdsInput)
        }
    }

    @Test func credentialOperationsHoldUntilDone() {
        var rotate = RotateState()
        var phone = NewPhoneSecretState()
        var credential = NewCredentialState()
        var pin = ChangePinState()
        var password = ChangePasswordState()
        #expect(rotate.holdsInput && phone.holdsInput && credential.holdsInput && pin.holdsInput && password.holdsInput)
        rotate.done = true
        phone.done = true
        credential.done = true
        pin.done = true
        password.done = true
        #expect(!rotate.holdsInput && !phone.holdsInput && !credential.holdsInput && !pin.holdsInput && !password.holdsInput)
    }

    @Test func theDeleteFormAndTheNameChangeHoldFromOpening() {
        #expect(DeleteVaultState().holdsInput)
        var name = ChangeNameState()
        #expect(name.holdsInput)
        name.step = .sent
        #expect(!name.holdsInput)
    }

    @Test func theWindowDialogHoldsWhileOpen() {
        var s = CredentialState()
        #expect(!s.holdsInput)
        s.windowDialog = true
        #expect(s.holdsInput)
    }
}
