import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys

/// The failure [body] throws, if it throws one.
@MainActor
func vaultFailure(_ body: @MainActor () async throws -> Void) async -> VaultFailure? {
    do {
        try await body()
        return nil
    } catch let f as VaultFailure {
        return f
    } catch {
        Issue.record("not a VaultFailure: \(error)")
        return nil
    }
}

/// The vault manager end to end, as onboarding drives it (IOS-PLAN §8 I1.6): the member API, the enclave, both relays
/// and the vault are ``FakeVaultService``; the keys are software keys behind the Secure Enclave's protocols. vettid-android
/// covers these paths with its dev-stack tests (`OnboardingDevStackTest`); here they run without one.
@MainActor
@Suite(.serialized) struct VaultManagerTests {
    let service: FakeVaultService
    let phone: TestVaultPhone

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    /// Setup code to Finish setup: the phases the onboarding flow follows, the steps of the progress screen, the unlock
    /// secret of epoch 1 in the enrollment and confirmed by it, the PIN and the password in `credential.create`, the
    /// backup setting and the confirmation.
    @Test func setupCodeToFinishSetup() async throws {
        defer { phone.close() }
        try await m.refresh()
        #expect(m.phase == .signedOut && m.account == nil)

        #expect(try await m.redeemSetupCode(.secret(service.secret)) == service.emailHint)
        #expect(m.phase == .setup(.newVault) && m.account == AccountInfo(emailHint: service.emailHint))
        #expect(service.redeems == 1)

        var steps: [EnrollStep] = []
        try await m.enroll(pin: "402817") { steps.append($0) }
        #expect(steps == [.enroll, .waitForVault, .handshake])
        #expect(m.usesPhoneSecret && m.recoveryOffered)
        let sent = try #require(service.enrolls.last)
        #expect(sent.pin == "402817")
        // The secret the vault holds is the one the phone's current record makes (§11.14.1 "On an iPhone").
        let current = try #require(try m.phoneSecrets.current())
        #expect(current.epoch == 1 && current.keyVault == service.vaultID)
        #expect(sent.unlockSecret == (try m.phoneSecrets.currentSecret()))

        try await m.createCredential(password: "correct horse battery", backup: false, pin: "402817") { steps.append($0) }
        #expect(steps == EnrollStep.allCases)
        #expect(m.phase == .setup(.finishing))
        let created = try #require(service.credentialCreates.last)
        #expect(created.pin == "402817" && created.password == "correct horse battery")
        #expect(!service.backupSetting && service.confirmed)

        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// The typed code with the account's email redeems the same way (ENROLLMENT-CODES §3).
    @Test func aTypedCodeIsRedeemed() async throws {
        defer { phone.close() }
        let hint = try await m.redeemSetupCode(.typed(email: service.email, code: service.typedCode))
        #expect(hint == service.emailHint && m.phase == .setup(.newVault))
    }

    /// After a restart the phase is read again from what the phone keeps and the vault's status: the account confirmed,
    /// the credential to create, the last screen, the open app.
    @Test func theStartReadsWhereSetupStands() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.newVault) && m.account?.emailHint == service.emailHint)

        try await m.enroll(pin: "402817") { _ in }
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.needsCredential) && m.usesPhoneSecret)

        try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in }
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.finishing))

        try await m.finishSetup()
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .unlocked)

        service.status("locked")
        try await m.refresh()
        #expect(m.phase == .locked)
        service.status("unlocked", noVault: true)
        try await m.refresh()
        #expect(m.phase == .unreachable(.noVault))
    }

    /// "That is not my account": the redeemed code is dropped with the device and its keys; the next redeem starts
    /// afresh with a new app key (§11.12.2).
    @Test func anotherCodeStartsAfresh() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        let key = try phone.appKeys.getOrCreate().spki()
        try await m.forgetSetupCode()
        #expect(m.phase == .signedOut && m.account == nil)
        try await phone.restart()
        try await m.refresh()
        #expect(m.phase == .signedOut)
        _ = try await m.redeemSetupCode(.secret(service.secret))
        #expect(m.phase == .setup(.newVault))
        #expect(try phone.appKeys.getOrCreate().spki() != key, "a new app key for the next setup")
    }

    /// Finish setup leaves onboarding only from the last screen (``FinishSetupGate``).
    @Test func finishSetupOnlyFromTheLastScreen() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.finishSetup()
        #expect(m.phase == .setup(.newVault))
    }

    /// The first-run cleanup runs before anything is read (IOS-PLAN §6.1): while it cannot (the iPhone not unlocked since
    /// it started) the phone says "Unlock your iPhone" and reads nothing.
    @Test func nothingIsReadBeforeTheFirstRunCleanup() async throws {
        defer { phone.close() }
        phone.prepareFailure = KeysError.unavailable("first run")
        try await m.refresh()
        #expect(m.phase == .unreachable(.phoneLocked))
        #expect(await vaultFailure { _ = try await m.redeemSetupCode(.secret(service.secret)) }?.kind == .phoneLocked)
        #expect(service.redeems == 0)
        phone.prepareFailure = nil
        try await m.refresh()
        #expect(m.phase == .signedOut)
    }
}
