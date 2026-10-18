import Foundation
import Testing
import VettIDAltChan
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding
@testable import VettIDVault

/// Mirrors vettid-android `OnboardingViewModelTest`, test for test.
@MainActor
@Suite struct OnboardingViewModelTests {
    let vault = FakeVaultRepository()
    let inbox = SetupLinkInbox()
    let secret = "AbCdEfGhIjKlMnOpQrStUv"
    let goodPassword = "correct horse battery staple"

    func vm() -> OnboardingViewModel { OnboardingViewModel(account: vault, vault: vault, inbox: inbox) }

    /// The PIN, its confirmation and the password, as far as the backup step.
    func toBackup(_ vm: OnboardingViewModel) {
        vm.setPin("40281795"); vm.submitPin(); vm.setPinConfirm("40281795"); vm.submitPinConfirm()
        vm.setPassword(goodPassword); vm.setPasswordConfirm(goodPassword); vm.submitPassword()
    }

    @Test func typedSetupCodeThenEnrollAndCreateTheCredential() async {
        let vm = vm()
        await vm.settle()
        #expect(vm.state.step == .welcome)
        vm.start()
        #expect(vm.state.step == .setupScan)
        vm.typeCode()
        #expect(vm.state.step == .setupType)
        vm.setEmail("not-an-email")
        vm.setCode("K7QM-4XR0")
        #expect(vm.state.codeInvalid, "0 is never in a code")
        vm.submitCode()
        #expect(vm.state.emailInvalid)
        #expect(!vault.calls.contains("redeemSetupCode"), "nothing is sent for a malformed code")
        vm.setEmail("  Sam@Example.org ")
        vm.setCode("k7qm 4xrp")
        #expect(!vm.state.codeInvalid)
        vm.submitCode()
        await vm.settle()
        #expect(vault.lastRedeemed == .typed(email: "sam@example.org", code: "K7QM4XRP"))
        // The account is shown before any PIN is asked for (reverse phishing, ENROLLMENT-CODES §7).
        #expect(vm.state.step == .confirmAccount)
        #expect(vm.state.emailHint == "m***@example.com")
        vm.confirmAccount()
        #expect(vm.state.step == .pinCreate)
        await choosePinAndPassword(vm)
    }

    /// The second half of the test above: the PIN, the password, the backup and the enrollment.
    func choosePinAndPassword(_ vm: OnboardingViewModel) async {
        vm.setPin("123456")
        vm.submitPin()
        #expect(vm.state.pinProblem == .sequence)
        vm.setPin("40281795")
        vm.submitPin()
        vm.setPinConfirm("40281796")
        vm.submitPinConfirm()
        #expect(vm.state.pinMismatch)
        vm.setPinConfirm("40281795")
        vm.submitPinConfirm()
        #expect(vm.state.step == .password)
        vm.setPassword("40281795")
        vm.setPasswordConfirm("40281795")
        vm.submitPassword()
        #expect(vm.state.step == .password)
        vm.setPassword(goodPassword)
        vm.setPasswordConfirm(goodPassword)
        vm.submitPassword()
        #expect(vm.state.step == .backup)

        vm.submitBackup()
        await vm.settle()
        #expect(vm.state.step == .done)
        #expect(vault.lastPin == "40281795")
        #expect(vault.lastBackup == true)
        #expect(vm.state.progress.allSatisfy { $0.state == .done })
        #expect(vm.state.pin == "")
        #expect(vm.state.password == "")
        vm.finish()
        await vm.settle()
        #expect(vault.phase == .unlocked)
    }

    @Test func scannedSetupQrIsRedeemedOnlyForThisEnvironment() async {
        let vm = vm()
        await vm.settle()
        vm.start()
        vm.scanned(#"{"v":1,"t":"e","api":"https://account.staging.vettid.org","s":"\#(secret)"}"#)
        #expect(vm.state.scanRefusal == .otherEnvironment)
        #expect(vm.state.otherApi == "https://account.staging.vettid.org")
        vm.scanned("hello")
        #expect(vm.state.scanRefusal == .notACode)
        let recoveryQr = #"{"v":1,"t":"r","api":"https://account.vettid.org","vault_id":"0123456789abcdef0123456789abcdef","#
            + #""recovery_id":"01JABCDEF0123456789ABCDEFG","code":"SK0ATG8WK2FYJ0Y5MEHJ5R5J7QZKWHX0"}"#
        vm.scanned(recoveryQr)
        #expect(vm.state.scanRefusal == .recoveryCode)
        #expect(!vault.calls.contains("redeemSetupCode"))
        vm.scanned(#"{"v":1,"t":"e","api":"https://account.vettid.org","s":"\#(secret)"}"#)
        await vm.settle()
        #expect(vault.lastRedeemed == .secret(secret))
        #expect(vm.state.step == .confirmAccount)
    }

    @Test func appLinkIsRedeemedWhileNothingIsSetUp() async {
        let vm = vm()
        await vm.settle()
        inbox.offer("https://account.vettid.org/vault/enroll/#s=\(secret)")
        await vm.settle()
        #expect(inbox.link == nil)
        #expect(vault.lastRedeemed == .secret(secret))
        #expect(vm.state.step == .confirmAccount)
    }

    @Test func anotherEnvironmentsAppLinkIsNotRedeemed() async {
        let vm = vm()
        await vm.settle()
        inbox.offer("https://account.staging.vettid.org/vault/enroll/#s=\(secret)")
        await vm.settle()
        #expect(!vault.calls.contains("redeemSetupCode"))
        #expect(vm.state.scanRefusal == .notACode)
    }

    /// (iOS) A link offered before the flow exists (the app was opened by it) is redeemed when the flow starts.
    @Test func aLinkWaitingAtLaunchIsRedeemed() async {
        inbox.offer("https://account.vettid.org/vault/enroll/#s=\(secret)")
        let vm = vm()
        await vm.settle()
        #expect(inbox.link == nil)
        #expect(vault.lastRedeemed == .secret(secret))
        #expect(vm.state.step == .confirmAccount)
    }

    @Test func aRefusedCodeSaysSoAndNotMyAccountStartsOver() async {
        let vm = vm()
        await vm.settle()
        vm.start()
        vm.typeCode()
        vm.setEmail("sam@example.org")
        vm.setCode("K7QM-4XRP")
        vault.fail["redeemSetupCode"] = FakeVaultRepository.failure(.setupCodeInvalid, code: "invalid_code")
        vm.submitCode()
        #expect(vm.state.busy, "busy at once: a second tap is ignored")
        await vm.settle()
        #expect(vm.state.step == .setupType)
        #expect(vm.state.error == .setupCodeInvalid)
        vm.submitCode()
        await vm.settle()
        #expect(vm.state.step == .confirmAccount)
        vm.useAnotherCode()
        await vm.settle()
        #expect(vault.calls.contains("forgetSetupCode"))
        #expect(vm.state.step == .welcome)
    }

    /// iPhone only (vettid-android starts over whatever the answer): a start-over the manager refuses because an
    /// enrollment may already have made a vault (`enrollment_started`) leaves the flow where it is, with the failure's
    /// text; any other failure still starts over.
    @Test func aRefusedStartOverStaysWhereItIs() async throws {
        vault.phase = .setup(.newVault)
        let vm = vm()
        await vm.settle()
        #expect(vm.state.step == .confirmAccount)
        vault.fail["forgetSetupCode"] = VaultFailure(.enrollmentStarted, code: VaultManager.codeEnrollmentStarted, retryAfterSeconds: 3600)
        vm.useAnotherCode()
        await vm.settle()
        #expect(vm.state.step == .confirmAccount && !vm.state.busy)
        #expect(vm.state.error == .enrollmentStarted && vm.state.errorCode == VaultManager.codeEnrollmentStarted)
        // When the start-over becomes possible, for the text (``FailureKind/enrollmentStartedText(after:)``).
        let after = try #require(vm.state.errorRetryAt)
        #expect(abs(after.timeIntervalSinceNow - 3600) < 60)
        vault.fail["forgetSetupCode"] = FakeVaultRepository.failure(.network)
        vm.useAnotherCode()
        await vm.settle()
        #expect(vm.state.step == .welcome && vm.state.error == nil && vm.state.errorRetryAt == nil)
    }

    @Test func backupOffNeedsTheAcknowledgement() async {
        vault.phase = .setup(.newVault)
        let vm = vm()
        await vm.settle()
        vm.confirmAccount()
        toBackup(vm)
        vm.setBackup(false)
        #expect(!vm.state.canContinueBackup)
        vm.submitBackup()
        #expect(vm.state.step == .backup)
        vm.acknowledgeBackupOff(true)
        vm.submitBackup()
        await vm.settle()
        #expect(vault.lastBackup == false)
    }

    @Test func vaultElsewhereFollowsThePhase() async {
        let vm = vm()
        await vm.settle()
        vault.phase = .setup(.vaultElsewhere)
        await vm.settle()
        #expect(vm.state.step == .vaultElsewhere)
        vm.enrollAnyway()
        #expect(vm.state.step == .pinCreate)
    }

    @Test func enrollFailureMarksTheStepAndRetryResumesAfterEnrollment() async {
        vault.phase = .setup(.newVault)
        let vm = vm()
        await vm.settle()
        vm.confirmAccount()
        toBackup(vm)
        vault.fail["createCredential"] = FakeVaultRepository.failure(.noResponse)
        vm.submitBackup()
        await vm.settle()
        let s = vm.state
        #expect(s.step == .progress)
        #expect(s.error == .noResponse)
        #expect(s.progressFailed)
        vm.run()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "enroll" }.count == 1)
        #expect(vm.state.step == .done)
    }

    @Test func vaultExistsGoesToTheElsewhereStep() async {
        vault.phase = .setup(.newVault)
        let vm = vm()
        await vm.settle()
        vm.confirmAccount()
        toBackup(vm)
        vault.fail["enroll"] = FakeVaultRepository.failure(.vaultExists, code: "vault_exists")
        vm.submitBackup()
        await vm.settle()
        #expect(vm.state.step == .vaultElsewhere)
    }

    @Test func needsCredentialResumesAtThePassword() async {
        vault.phase = .setup(.needsCredential)
        let vm = vm()
        await vm.settle()
        #expect(vm.state.step == .password)
        #expect(vm.state.credentialOnly)
        #expect(!vm.back())
    }

    /// Release R (VAULT-MESSAGING 0.33.0 §11.14.9): credential.create carries the enrollment's PIN.
    @Test func releaseRCredentialCreateCarriesThePin() async {
        vault.phoneSecret = true
        vault.phase = .setup(.newVault)
        let vm = vm()
        await vm.settle()
        vm.confirmAccount()
        toBackup(vm)
        vm.submitBackup()
        await vm.settle()
        #expect(vault.calls.contains("createCredential"))
        #expect(vault.lastCredentialPin == "40281795")
    }

    /// Release R: after a restart the PIN is not in memory; the password step asks for it and credential.create carries it.
    @Test func releaseRNeedsCredentialAsksForThePin() async {
        vault.phoneSecret = true
        vault.phase = .setup(.needsCredential)
        let vm = vm()
        await vm.settle()
        #expect(vm.state.askPin)
        vm.setPassword(goodPassword); vm.setPasswordConfirm(goodPassword)
        #expect(!vm.state.credentialPinReady)
        vm.submitPassword()
        #expect(vm.state.step == .password)
        vm.setPin("40281795")
        vm.submitPassword()
        #expect(vm.state.step == .backup)
        vm.submitBackup()
        await vm.settle()
        #expect(vault.lastCredentialPin == "40281795")
    }

    /// IOS-PLAN ID8: the iPhone asks for the PIN after a restart even when its phone secret cannot be read now (every
    /// vault of the iPhone app is of release R), so credential.create never goes without it.
    @Test func theIPhoneAlwaysAsksForThePinAfterARestart() async {
        vault.phase = .setup(.needsCredential)
        let vm = vm()
        await vm.settle()
        #expect(vm.state.askPin)
        vm.setPassword(goodPassword); vm.setPasswordConfirm(goodPassword); vm.submitPassword()
        #expect(vm.state.step == .password, "not without the PIN")
        vm.setPin("40281795")
        vm.submitPassword()
        vm.submitBackup()
        await vm.settle()
        #expect(vault.calls.contains("createCredential"))
    }

    @Test func recoverFromTheWelcomeScreenNeedsNoSignIn() async {
        let vm = vm()
        await vm.settle()
        vm.startRecovery()
        #expect(vm.state.step == .recover)
        // Registered: the phase follows, the flow stays; finishing does not jump to the generic done screen.
        vault.phase = .setup(.recovering)
        await vm.settle()
        #expect(vm.state.step == .recover)
        vault.phase = .setup(.finishing)
        await vm.settle()
        #expect(vm.state.step == .recover)
    }

    @Test func transferFromTheWelcomeScreenAndBack() async {
        let vm = vm()
        await vm.settle()
        vm.startTransfer()
        #expect(vm.state.step == .transferIn)
        vm.leaveMove()
        await vm.settle()
        #expect(vm.state.step == .welcome)
        // After a redeem that found a vault elsewhere, leaving goes back to that choice.
        vault.phase = .setup(.newVault)
        await vm.settle()
        vm.transfer()
        vm.leaveMove()
        await vm.settle()
        #expect(vm.state.step == .vaultElsewhere)
        vm.recover()
        #expect(vm.state.step == .recover)
    }

    @Test func aRecoveryInProgressResumesAfterARestart() async {
        vault.phase = .setup(.recovering)
        let vm = vm()
        await vm.settle()
        #expect(vm.state.step == .recover)
    }

    @Test func aPhoneThatErasedItselfShowsAFreshWelcome() async {
        // Owner decision 2026-10-05: a replaced phone wipes itself and is signed out; nothing of before is shown.
        vault.phase = .setup(.newVault)
        let vm = vm()
        await vm.settle()
        #expect(vm.state.step == .confirmAccount)
        vm.confirmAccount()
        vm.setEmail("sam@example.org")
        vm.setPin("40281795")
        vault.phase = .signedOut
        await vm.settle()
        #expect(vm.state == OnboardingState(devHint: vault.devHint))
        #expect(vm.state.step == .welcome)
        #expect(vm.state.email == "")
        #expect(vm.state.pin == "")
        #expect(vm.state.error == nil)
    }

    /// ANDROID-PLAN "Passwords": the rules as the member types; Continue only once they pass (staging release 15:
    /// password1234).
    @Test func theReleaseRPasswordRulesAtEnrollment() async {
        let vm = vm()
        await vm.settle()
        vm.confirmAccount()
        vm.setPin("40281795"); vm.submitPin(); vm.setPinConfirm("40281795"); vm.submitPinConfirm()
        #expect(vm.state.step == .password)
        func verdict(_ pw: String) -> PasswordRule {
            vm.setPassword(pw); vm.setPasswordConfirm(pw)
            return vm.state.passwordRule
        }
        #expect(verdict("short") == .short)
        #expect(verdict("aaaaaaaaaaaaaa") == .repeated)
        #expect(verdict("password1234") == .common)
        #expect(verdict("Password1234") == .common)
        #expect(verdict("123456789123") == .guessable)
        #expect(!vm.state.canSubmitPassword)
        vm.submitPassword()
        #expect(vm.state.step == .password, "a refused password goes no further")
        #expect(verdict(goodPassword) == .ok)
        #expect(vm.state.canSubmitPassword)
        vm.submitPassword()
        #expect(vm.state.step == .backup)
    }

    @Test func aPasswordEqualToThePinIsRefused() async {
        vault.phoneSecret = true
        vault.phase = .setup(.needsCredential)
        let vm = vm()
        await vm.settle()
        vm.setPassword("402817950582163"); vm.setPasswordConfirm("402817950582163")
        #expect(vm.state.passwordRule != .sameAsPin)
        // The PIN entered after the password on the same screen.
        vm.setPin("402817950582163")
        #expect(vm.state.passwordRule == .sameAsPin)
        #expect(!vm.state.canSubmitPassword)
    }

    /// The vault's weak_password{reason}: back to the password, the reason under the field in the app's own words.
    @Test func theVaultsWeakPasswordReasonIsShown() async {
        vault.phase = .setup(.needsCredential)
        let op = VaultOpError(type: "credential.create", code: "weak_password", detail: "", body: Array(#"{"reason":"guessable"}"#.utf8))
        vault.fail["createCredential"] = VaultFailure(.weakPassword, code: "weak_password", cause: op)
        let vm = vm()
        await vm.settle()
        vm.setPin("40281795") // asked after a restart (ID8)
        vm.setPassword(goodPassword); vm.setPasswordConfirm(goodPassword); vm.submitPassword()
        vm.submitBackup()
        await vm.settle()
        #expect(vm.state.step == .password)
        #expect(vm.state.passwordRule == .guessable)
        #expect(vm.state.passwordRefused)
        #expect(vm.state.error == nil)
        #expect(!vm.state.canSubmitPassword, "the same password is not sent again")
        vm.setPassword("a much better passphrase 9 here"); vm.setPasswordConfirm("a much better passphrase 9 here")
        #expect(!vm.state.passwordRefused)
        #expect(vm.state.canSubmitPassword)
    }

    /// A reason this app does not know: the generic text, and the same password is not sent again.
    @Test func anUnknownWeakPasswordReasonBlocksTheSamePassword() async {
        vault.phase = .setup(.needsCredential)
        vault.fail["createCredential"] = VaultFailure(.weakPassword, code: "weak_password")
        let vm = vm()
        await vm.settle()
        vm.setPassword(goodPassword); vm.setPasswordConfirm(goodPassword); vm.submitPassword()
        vm.submitBackup()
        await vm.settle()
        #expect(vm.state.step == .password)
        #expect(vm.state.passwordRule == .vaultRefused)
        #expect(vm.state.passwordRefused)
        #expect(!vm.state.canSubmitPassword)
        vm.submitPassword()
        #expect(vm.state.step == .password)
    }

    /// After a move (also after a restart before leaving onboarding) the last screen is the move's, not the enrollment's.
    @Test func theLastScreenAfterAMoveIsTheMoves() async {
        vault.movedInFlag = true
        vault.phoneSecret = true
        vault.phase = .setup(.finishing)
        let vm = vm()
        await vm.settle()
        #expect(vm.state.step == .done)
        #expect(vm.state.movedIn)
        #expect(vm.state.phoneSecret)
    }

    @Test func theLastScreenAfterAnEnrollmentIsTheEnrollments() async {
        vault.phase = .setup(.finishing)
        let vm = vm()
        await vm.settle()
        #expect(vm.state.step == .done)
        #expect(!vm.state.movedIn)
    }
}
