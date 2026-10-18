import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys
import VettIDKeysTesting

/// Each failure the onboarding screens show, from the vault manager over ``FakeVaultService``, and the retries after
/// them: the code refused, the network, the vault elsewhere, the phone's attestation refused, a release before R (ID8),
/// a weak password, a locked iPhone, and the answers lost on the way back (IOS-PLAN §6.3 item 7).
@MainActor
@Suite(.serialized) struct VaultManagerFailureTests {
    let service: FakeVaultService
    let phone: TestVaultPhone

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func redeemed() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
    }

    /// A used, expired or wrong code is `404 invalid_code`: nothing is kept; another try with a good code works.
    @Test func aRefusedCodeKeepsNothing() async throws {
        defer { phone.close() }
        service.redeemAnswer = .invalidCode
        let f = await vaultFailure { try await redeemed() }
        #expect(f?.kind == .setupCodeInvalid && f?.code == "invalid_code")
        #expect(m.account == nil && m.phase != .setup(.newVault))
        service.redeemAnswer = .ok
        try await redeemed()
        #expect(m.phase == .setup(.newVault))
    }

    /// No network at the redeem, then a retry.
    @Test func theRedeemIsRetriedAfterANetworkFailure() async throws {
        defer { phone.close() }
        service.redeemAnswer = .offline
        #expect(await vaultFailure { try await redeemed() }?.kind == .network)
        service.redeemAnswer = .ok
        try await redeemed()
        #expect(service.redeems == 1 && m.phase == .setup(.newVault))
    }

    /// The account has a vault this phone does not hold (`vault_exists`), and the enclave refused this phone's
    /// attestation (`attestation`): each its own failure; nothing is confirmed. Both are definite (no vault was made):
    /// the enrollment's record and key are dropped, and a start-over is allowed.
    @Test func theEnclavesRefusalsAreTheirOwnFailures() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.refused("vault_exists"), .refused("attestation"))
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .vaultExists)
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .attestation)
        #expect(try m.phoneSecrets.current() == nil && !m.usesPhoneSecret)
        #expect(try m.phoneSecrets.records().pendings.isEmpty && phone.phoneKeys.count == 0)
        #expect(m.session?.device.altState.enrollAttempts.isEmpty == true)
        try await m.forgetSetupCode()
        #expect(m.phase == .signedOut)
    }

    /// The enrollment failed before any request was posted (the enclave route unreachable): nothing reached the vault,
    /// nothing of it is kept, and a start-over is allowed.
    @Test func aFailureBeforeAnyPostKeepsNothing() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enclaveOffline = true
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .network)
        #expect(phone.phoneKeys.count == 0 && service.enrolls.isEmpty)
        try await m.forgetSetupCode()
        #expect(m.phase == .signedOut)
    }

    /// A failure once a request was posted (the post itself, or the result slot) leaves the outcome unknown: the keys are
    /// kept and a start-over is refused.
    @Test(arguments: [FakeVaultService.EnrollAnswer.offline, .slotLost])
    func aFailureAfterThePostKeepsTheKeys(_ answer: FakeVaultService.EnrollAnswer) async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(answer)
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } } != nil)
        #expect(try phone.phoneKeys.count == 1 && m.phoneSecrets.records().pendings.count == 1)
        #expect(await vaultFailure { try await m.forgetSetupCode() }?.kind == .enrollmentStarted)
    }

    /// Within one enrollment call: the first post's slot `expired` (§11.5: also written when the enclave did not answer,
    /// so the request may have been processed), the retry is refused `attestation`: the keys are kept. After
    /// `etk_unknown` (the enclave could not decrypt it) the same refusal drops them.
    @Test(arguments: [(FakeVaultService.EnrollAnswer.slotExpired, true), (.etkUnknown, false)])
    func anEarlierPostInTheSameCallCounts(_ first: FakeVaultService.EnrollAnswer, _ kept: Bool) async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(first, .refused("attestation"))
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .attestation)
        #expect(service.enrolls.count == 2)
        #expect(phone.phoneKeys.count == (kept ? 1 : 0))
        let f = await vaultFailure { try await m.forgetSetupCode() }
        #expect((f?.kind == .enrollmentStarted) == kept)
    }

    /// After a request whose answer was lost, the enclave may answer any refusal while the vault exists (it checks the
    /// manifest, the attestation and the request before it looks for the vault): `attestation` then drops nothing,
    /// a start-over stays refused, and the late `vault.enrolled` for the first request is still accepted.
    @Test func aRefusalAfterAnUnknownOutcomeDropsNothing() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.answerLostEnrolledLate, .refused("attestation"))
        service.holdLateEnrolled = true
        _ = await vaultFailure { try await m.enroll(pin: "402817") { _ in } }
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .attestation)
        #expect(try phone.phoneKeys.count == 1 && m.phoneSecrets.records().pendings.count == 1)
        #expect(await vaultFailure { try await m.forgetSetupCode() }?.kind == .enrollmentStarted)
        service.deliverLateEnrolled()
        try await awaitPinned()
        try await m.enroll(pin: "402817") { _ in }
        #expect(service.enrolls.count == 2, "no third request: the vault is pinned")
        #expect(service.enrolls.first?.unlockSecret == (try m.phoneSecrets.currentSecret()))
    }

    /// Another account's code while this phone's enrollment outcome is unknown: refused, never mixed with it; the record
    /// still names the first vault.
    @Test func anotherVaultsCodeIsRefusedWhileAnEnrollmentIsUnknown() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.answerLostEnrolledLate)
        _ = await vaultFailure { try await m.enroll(pin: "402817") { _ in } }
        service.redeemNames("fedcba9876543210fedcba9876543210")
        let redeemPath = "/api/vault/enroll/redeem"
        let before = service.api.requests.filter { $0.path == redeemPath }.count
        let f = await vaultFailure { try await redeemed() }
        #expect(f?.kind == .enrollmentStarted && (f?.retryAfterSeconds ?? 0) > 0)
        // Refused before the member API: no code is spent and the app key stays bound to the first vault.
        #expect(service.api.requests.filter { $0.path == redeemPath }.count == before)
        #expect(m.record.value.vaultID == service.vaultID && m.record.value.enrollStartedMs != nil)
        // The same vault's code again is refused the same way: the record already names it.
        service.redeemNames(nil)
        #expect(await vaultFailure { try await redeemed() }?.kind == .enrollmentStarted)
        #expect(service.api.requests.filter { $0.path == redeemPath }.count == before)
    }

    /// A lost answer keeps the keys from a start-over for 24 h plus a margin (§11.3: a provisional vault not confirmed
    /// by then may be replaced), measured from the persisted start, also after a restart.
    @Test func theGuardOfAnUnknownOutcomeExpires() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.answerLostEnrolledLate)
        _ = await vaultFailure { try await m.enroll(pin: "402817") { _ in } }
        #expect(await vaultFailure { try await m.forgetSetupCode() }?.code == VaultManager.codeEnrollmentStarted)
        phone.clockAhead = VaultManager.unknownEnrollmentKept - 60
        try phone.restart()
        #expect(await vaultFailure { try await m.forgetSetupCode() }?.code == VaultManager.codeEnrollmentStarted)
        phone.clockAhead = VaultManager.unknownEnrollmentKept + 60
        try await m.forgetSetupCode()
        #expect(m.phase == .signedOut)
    }

    /// Two epoch-1 records alive for the vault `vault.enrolled` pinned: the start cannot tell which one the vault holds,
    /// leaves both pending (an unlock proves the right one) and carries on.
    @Test func anAmbiguousEpochOneDoesNotBlockTheStart() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.answerLost)
        _ = await vaultFailure { try await m.enroll(pin: "402817") { _ in } }
        try await awaitPinned()
        _ = try m.phoneSecrets.create(keyVault: service.vaultID)
        try phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.needsCredential) && m.usesPhoneSecret)
        #expect(try m.phoneSecrets.records().pendings.count == 2)
    }

    /// Only the phone whose enrollment made the vault confirms it at a start.
    @Test func onlyTheEnrollingPhoneResumesTheConfirmation() async throws {
        defer { phone.close() }
        try await redeemed()
        try await m.enroll(pin: "402817") { _ in }
        service.failNext("vault.enroll.confirm")
        _ = await vaultFailure { try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in } }
        try m.record.update(since: m.record.generation) { $0.enrolledHere = false }
        try phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.finishing) && !service.confirmed)
    }

    /// IOS-PLAN ID8: an instance without `recovery_r` gets nothing; no phone key is made for it.
    @Test func aReleaseBeforeRIsRefusedBeforeAnythingIsSent() async throws {
        defer { phone.close() }
        try await redeemed()
        service.capabilities = nil
        let f = await vaultFailure { try await m.enroll(pin: "402817") { _ in } }
        #expect(f?.kind == .releaseTooOld && f?.code == ReleasePath.codeReleaseTooOld)
        #expect(service.enrolls.isEmpty && phone.phoneKeys.count == 0)
        service.capabilities = ["recovery_r"]
        try await m.enroll(pin: "402817") { _ in }
        #expect(!m.recoveryOffered, "release R without recovery_offered hides recovery (§11.10.9)")
    }

    /// Waits until the device holds the vault `vault.enrolled` pinned (the collector delivers it).
    func awaitPinned() async throws {
        for _ in 0..<200 where m.session?.device.vaultID == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(m.session?.device.vaultID == service.vaultID)
    }

    /// The enrollment's answer lost on the way back while the vault was made (it deposits `vault.enrolled` and answers
    /// any later request `vault_exists`): the retry sends no second request, confirms the epoch-1 record the vault holds
    /// and goes on with the handshake and the credential.
    @Test func aRetryAfterALostAnswerUsesTheVaultItMade() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.answerLost)
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .network)
        #expect(try m.phoneSecrets.current() == nil, "unconfirmed until the vault answers")
        try await m.enroll(pin: "402817") { _ in }
        let sent = try #require(service.enrolls.first?.unlockSecret)
        #expect(service.enrolls.count == 1)
        #expect(sent == (try m.phoneSecrets.currentSecret()))
        #expect(try m.phoneSecrets.records().pendings.isEmpty && phone.phoneKeys.count == 1)
        try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in }
        #expect(m.phase == .setup(.finishing) && service.confirmed)
    }

    /// The same when the retry is sent before `vault.enrolled` arrived: the vault answers `vault_exists`, and the
    /// enrollment waits for its own vault's `vault.enrolled` instead of reporting another phone's vault.
    @Test func vaultExistsFromThePhonesOwnLostRequestIsNotAnotherPhones() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.answerLostEnrolledLate)
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .network)
        try await m.enroll(pin: "402817") { _ in }
        #expect(service.enrolls.count == 2 && m.usesPhoneSecret)
        #expect(service.enrolls[0].unlockSecret == service.enrolls[1].unlockSecret)
        #expect(service.enrolls.first?.unlockSecret == (try m.phoneSecrets.currentSecret()))
    }

    /// IOS-PLAN §6.2 (chosen; not in the spec): the first request's answer lost, the retry refused `vault_exists`; the
    /// first request's `vault.enrolled` confirms the App Attest key it attested, and the refused retry's key is
    /// discarded.
    @Test func vaultEnrolledConfirmsTheKeyOfTheRequestThatMadeTheVault() async throws {
        defer { phone.close() }
        try await redeemed()
        #expect(phone.attestStartOver.value, "no vault can hold a key yet")
        service.enrollAnswers(.answerLostEnrolledLate)
        _ = await vaultFailure { try await m.enroll(pin: "402817") { _ in } }
        #expect(!phone.attestStartOver.value, "an enrollment's outcome is unknown")
        try await m.enroll(pin: "402817") { _ in }
        let a = phone.attester.attested
        #expect(a.count == 2)
        #expect(phone.attester.discarded == [a[1]])
        #expect(phone.attester.confirmed.first == a[0] && !phone.attester.confirmed.contains(a[1]))
        #expect(!phone.attestStartOver.value)
    }

    /// An enrollment that certainly made no vault (`etk_unknown`, then a refusal) discards every key it attested.
    @Test func anAbandonedEnrollmentDiscardsItsKeys() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.etkUnknown, .refused("attestation"))
        _ = await vaultFailure { try await m.enroll(pin: "402817") { _ in } }
        let a = phone.attester.attested
        #expect(a.count == 2 && Set(phone.attester.discarded) == Set(a) && phone.attester.confirmed.isEmpty)
        #expect(phone.attestStartOver.value, "nothing can hold a key: a damaged record may start over")
    }

    /// The app crashed after the vault made the vault and before the enrollment's answer confirmed the record: at the
    /// next start `vault.enrolled` confirms it (``PhoneSecrets/confirmPending(keyVault:)``), and setup resumes with the
    /// credential.
    @Test func aCrashAfterTheVaultsOkConfirmsTheRecordAtTheStart() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.answerLost)
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .network)
        try await awaitPinned()
        try phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.needsCredential) && m.usesPhoneSecret)
        #expect(service.enrolls.first?.unlockSecret == (try m.phoneSecrets.currentSecret()))
        try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in }
        #expect(m.phase == .setup(.finishing))
    }

    /// While the phone may hold a vault (a request whose answer was lost), "that is not my account" keeps every key:
    /// the provisional vault's secret is never deleted.
    @Test func aStartOverNeverForgetsAPossibleVaultsKeys() async throws {
        defer { phone.close() }
        try await redeemed()
        let appKey = try phone.appKeys.getOrCreate().spki()
        // The vault's `vault.enrolled` is held back: while it has not arrived, only the unknown outcome refuses, and says
        // for how long.
        service.enrollAnswers(.answerLostEnrolledLate)
        service.holdLateEnrolled = true
        _ = await vaultFailure { try await m.enroll(pin: "402817") { _ in } }
        let f = await vaultFailure { try await m.forgetSetupCode() }
        #expect(f?.kind == .enrollmentStarted && f?.code == VaultManager.codeEnrollmentStarted)
        #expect((f?.retryAfterSeconds ?? 0) > 24 * 3600, "says when the start-over becomes possible")
        #expect(try phone.phoneKeys.count == 1 && phone.appKeys.getOrCreate().spki() == appKey)
        #expect(m.phase == .setup(.newVault))
        // After a restart too: the stored device is looked at.
        try phone.restart()
        #expect(await vaultFailure { try await m.forgetSetupCode() }?.kind == .enrollmentStarted)
        #expect(phone.phoneKeys.count == 1)
    }

    /// An answer lost before the app was killed: after the restart the retry reuses the epoch-1 record (the vault may
    /// hold its secret), and the vault's late `vault.enrolled` for the first request is accepted.
    @Test func aRetryAfterARestartReusesTheEpochOneRecord() async throws {
        defer { phone.close() }
        try await redeemed()
        service.enrollAnswers(.answerLostEnrolledLate)
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .network)
        try phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.newVault))
        try await m.enroll(pin: "402817") { _ in }
        #expect(phone.phoneKeys.count == 1 && m.usesPhoneSecret)
        #expect(service.enrolls.count == 2 && service.enrolls[0].unlockSecret == service.enrolls[1].unlockSecret)
    }

    /// Every vault of this app is of release R (ID8): `credential.create` never goes without the PIN.
    @Test func noCredentialWithoutThePin() async throws {
        defer { phone.close() }
        try await redeemed()
        try await m.enroll(pin: "402817") { _ in }
        let f = await vaultFailure { try await m.createCredential(password: "correct horse battery", backup: true) { _ in } }
        #expect(f?.code == VaultManager.codePinRequired && service.credentialCreates.isEmpty)
    }

    /// A restart after `credential.create` and before `vault.enroll.confirm` (§11.3: the vault is still provisional):
    /// the start sends the member's backup choice and the confirmation before onboarding goes on.
    @Test(arguments: ["settings.get", "vault.enroll.confirm"])
    func aRestartBeforeTheConfirmationResumesIt(_ stoppedAt: String) async throws {
        defer { phone.close() }
        try await redeemed()
        try await m.enroll(pin: "402817") { _ in }
        service.failNext(stoppedAt)
        #expect(await vaultFailure {
            try await m.createCredential(password: "correct horse battery", backup: false, pin: "402817") { _ in }
        } != nil)
        #expect(!service.confirmed && service.credentialCreates.count == 1)
        try phone.restart()
        try await m.refresh()
        #expect(m.phase == .setup(.finishing))
        #expect(service.confirmed && !service.backupSetting)
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// Finish setup never ends onboarding before the vault was confirmed.
    @Test func finishSetupWaitsForTheConfirmation() async throws {
        defer { phone.close() }
        try await redeemed()
        m.phase = .setup(.finishing)
        #expect(await vaultFailure { try await m.finishSetup() }?.code == VaultManager.codeEnrollUnconfirmed)
        #expect(m.phase == .setup(.finishing))
    }

    /// A locked iPhone refuses the phone key for now (IOS-PLAN §6.3): "Unlock your iPhone", nothing sent, nothing lost.
    @Test func aLockedIPhoneSendsNothing() async throws {
        defer { phone.close() }
        try await redeemed()
        phone.phoneKeys.source.behaviour = .locked
        #expect(await vaultFailure { try await m.enroll(pin: "402817") { _ in } }?.kind == .phoneLocked)
        #expect(service.enrolls.isEmpty)
        phone.phoneKeys.source.behaviour = .normal
        try await m.enroll(pin: "402817") { _ in }
    }

    /// The vault refuses the password (`weak_password{reason}`, §11.14.7): the reason reaches the screen; a new password
    /// creates the credential without enrolling again.
    @Test func aWeakPasswordCarriesTheVaultsReason() async throws {
        defer { phone.close() }
        try await redeemed()
        try await m.enroll(pin: "402817") { _ in }
        service.refusePassword("common")
        let f = await vaultFailure {
            try await m.createCredential(password: "password1234", backup: true, pin: "402817") { _ in }
        }
        #expect(f?.kind == .weakPassword && f?.weakPasswordReason == "common")
        #expect(m.phase == .setup(.newVault))
        try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in }
        #expect(m.phase == .setup(.finishing) && service.enrolls.count == 1)
        #expect(service.credentialCreates.map(\.password) == ["correct horse battery"])
    }

    /// A `credential.create` whose answer was lost: the vault answers `exists` to the retry and the phone fetches the
    /// credential instead of asking for a new one.
    @Test func aCredentialTheVaultAlreadyHoldsIsFetched() async throws {
        defer { phone.close() }
        try await redeemed()
        try await m.enroll(pin: "402817") { _ in }
        service.credentialAlreadyCreated()
        try await m.createCredential(password: "correct horse battery", backup: true, pin: "402817") { _ in }
        #expect(m.phase == .setup(.finishing) && service.credentialCreates.isEmpty && service.confirmed)
    }
}
