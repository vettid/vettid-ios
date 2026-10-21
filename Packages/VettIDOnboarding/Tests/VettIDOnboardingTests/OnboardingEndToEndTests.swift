import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The onboarding view model over the real vault manager (IOS-PLAN §8 I1.6), the vault service faked in process
/// (``FakeVaultService``) and software keys: the screens' steps follow the phases the manager publishes, from the setup
/// QR to the open app, and after a restart in the middle.
@MainActor
@Suite(.serialized) struct OnboardingEndToEndTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let inbox = SetupLinkInbox()
    let pin = "40281795"
    let password = "correct horse battery staple"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    func model() -> OnboardingViewModel { OnboardingViewModel(account: phone.manager, vault: phone.manager, inbox: inbox) }

    func pinAndPassword(_ vm: OnboardingViewModel) {
        vm.setPin(pin)
        vm.submitPin()
        vm.setPinConfirm(pin)
        vm.submitPinConfirm()
        vm.setPassword(password)
        vm.setPasswordConfirm(password)
        vm.submitPassword()
    }

    @Test func fromTheSetupQRToTheOpenApp() async throws {
        defer { phone.close() }
        let vm = model()
        try await phone.manager.refresh()
        await vm.settle()
        #expect(vm.state.step == .welcome)
        vm.start()
        vm.scanned(service.setupQR)
        await vm.settle()
        #expect(vm.state.step == .confirmAccount && vm.state.emailHint == service.emailHint)
        #expect(phone.manager.phase == .setup(.newVault))
        vm.confirmAccount()
        pinAndPassword(vm)
        #expect(vm.state.step == .backup)
        vm.submitBackup()
        await vm.settle()
        #expect(vm.state.error == nil)
        #expect(vm.state.step == .done && vm.state.progress.allSatisfy { $0.state == .done })
        #expect(phone.manager.phase == .setup(.finishing))
        #expect(service.enrolls.last?.pin == pin && service.credentialCreates.last?.pin == pin && service.confirmed)
        #expect(vm.state.pin.isEmpty && vm.state.password.isEmpty, "the secrets are dropped once used")
        vm.finish()
        await vm.settle()
        #expect(phone.manager.phase == .unlocked)
    }

    /// The app stopped after the enrollment: the start reads `needsCredential`, the flow asks for the password and the
    /// PIN (release R: `credential.create` carries it), and resumes with the credential only.
    @Test func aRestartAfterTheEnrollmentResumesWithTheCredential() async throws {
        defer { phone.close() }
        _ = try await phone.manager.redeemSetupCode(.secret(service.secret))
        try await phone.manager.enroll(pin: pin) { _ in }
        try await phone.restart()
        let vm = model()
        try await phone.manager.refresh()
        await vm.settle()
        #expect(phone.manager.phase == .setup(.needsCredential))
        #expect(vm.state.step == .password && vm.state.credentialOnly && vm.state.askPin)
        vm.setPin(pin)
        vm.setPassword(password)
        vm.setPasswordConfirm(password)
        vm.submitPassword()
        vm.submitBackup()
        await vm.settle()
        #expect(vm.state.step == .done && service.enrolls.count == 1)
        #expect(vm.state.progress.map(\.step) == [.createCredential, .backup, .confirm])
    }

    /// The failures the screens show come through as the manager reports them: the vault elsewhere goes to its
    /// screen; a weak password goes back to the password with the vault's reason.
    @Test func theVaultsRefusalsReachTheScreens() async throws {
        defer { phone.close() }
        let vm = model()
        try await phone.manager.refresh()
        vm.start()
        vm.scanned(service.setupQR)
        await vm.settle()
        vm.confirmAccount()
        pinAndPassword(vm)
        service.enrollAnswers(.refused("vault_exists"))
        vm.submitBackup()
        await vm.settle()
        #expect(vm.state.step == .vaultElsewhere && vm.state.error == .vaultExists)

        vm.enrollAnyway()
        pinAndPassword(vm)
        service.refusePassword("common")
        vm.submitBackup()
        await vm.settle()
        #expect(vm.state.step == .password && vm.state.passwordRefused && vm.state.passwordRule == .common)
    }

    /// A setup QR another environment's portal made is not redeemed; nothing reaches the member API.
    @Test func anotherEnvironmentsCodeIsNotSent() async throws {
        defer { phone.close() }
        let vm = model()
        try await phone.manager.refresh()
        vm.start()
        vm.scanned(#"{"v":1,"t":"e","api":"https://account.example.org","s":"\#(service.secret)"}"#)
        await vm.settle()
        #expect(vm.state.scanRefusal == .otherEnvironment && service.redeems == 0)
    }
}
