import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// swiftlint:disable line_length

/// Recovery on a new phone (VAULT-MESSAGING §11.11, §11.14.6) end to end: the claim of the portal's code, the attested
/// register, the open with the PIN and the password together and the attempt counter, the first handshake and the
/// credential, the lost `ok`, and leaving a registration. Against ``FakeVaultService`` as the vault being recovered.
@MainActor
@Suite(.serialized) struct VaultManagerRecoveryTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout)
    }

    var m: VaultManager { phone.manager }

    func armed() throws -> FakeVaultService.RecoveryCodeMade { try service.armRecovery(pin: pin, password: password) }

    func scanned(_ made: FakeVaultService.RecoveryCodeMade) throws -> RecoveryCode {
        try #require(RecoveryCode.parseScanned(made.qr))
    }

    func typed(_ made: FakeVaultService.RecoveryCodeMade) throws -> TypedRecoveryCode {
        guard case .ok(let t) = TypedRecoveryCode.parse(made.typed, api: service.api.baseURL) else {
            Issue.record("the typed code is not accepted")
            throw VaultFailure(.other)
        }
        return t
    }

    /// Registered by the scanned code.
    func registered() async throws -> FakeVaultService.RecoveryCodeMade {
        let made = try armed()
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        return made
    }

    var pendingRecord: Bool { (try? m.phoneSecrets.hasPending()) ?? false }
    var hasCurrentRecord: Bool { ((try? m.phoneSecrets.current()) ?? nil) != nil }
    var device: VaultDevice? { m.session?.device }

    // MARK: - Where it stands

    @Test func aPhoneThatRegisteredNothingIsAtTheCode() async throws {
        defer { phone.close() }
        #expect(try await m.recoveryStage() == .code)
        // Reading the stage makes no device and no mailbox.
        #expect(m.session == nil)
    }

    @Test func aRegisteredPhoneIsAtTheOpenAndStaysThereAfterARestart() async throws {
        defer { phone.close() }
        _ = try await registered()
        #expect(try await m.recoveryStage() == .pin)
        try await phone.restart()
        #expect(try await m.recoveryStage() == .pin)
        try await m.refresh()
        #expect(m.phase == .setup(.recovering) && device?.recovering == true)
        // Nothing is open yet: no vault, no credential.
        let isOpened = try await m.recoveryOpened()
        #expect(device?.hasVault == false && device?.deviceID == nil && !isOpened)
    }

    // MARK: - The claim and the register (§11.11.3, §11.11.7)

    @Test func theScannedCodeIsClaimedWithTheAppKeyAndRegisteredWithTheAttestation() async throws {
        defer { phone.close() }
        let made = try await registered()
        let appKey = try phone.appKeys.getOrCreate().spki()
        let claim = try #require(service.recoveryClaims.first)
        #expect(claim.kind == "qr" && claim.vaultID == made.vaultID && claim.recoveryID == made.recoveryID && claim.appKey == appKey)
        // §11.11.3, §11.12.2: the code, the attested key (IOS-PLAN §6.2) and the app key, for the claimed member.
        let seen = try #require(service.recoveryRegisters.first)
        #expect(seen.recoveryID == made.recoveryID && seen.code == made.code && seen.vaultID == made.vaultID)
        #expect(seen.userGuid == service.userGuid && seen.apiKey == appKey)
        #expect(seen.platform == "ios" && seen.keyID == phone.attester.attested.last)
        // The record is the claimed vault's; the phone key and its epoch-1 record wait for the open.
        let local = m.record.value
        #expect(local.userGuid == service.userGuid && local.vaultID == made.vaultID && local.emailHint == service.emailHint)
        #expect(local.capabilities.contains(Capabilities.recoveryR) && m.account?.emailHint == service.emailHint)
        #expect(local.recoveryRegistered && !local.noVaultHoldsAttestKey)
        #expect(m.phase == .setup(.recovering) && m.usesPhoneSecret && pendingRecord && !hasCurrentRecord)
        #expect(device?.recovering == true && device?.vaultID == made.vaultID)
        // The vault bound the key the register attested (IOS-PLAN §6.2).
        #expect(phone.attester.confirmed == phone.attester.attested)
    }

    /// IOS-PLAN §8 I3.4: typed and scanned entries make equal requests.
    @Test func aTypedCodeMakesTheSameRequestAsTheScannedOne() async throws {
        let id = Ulid.new()
        let (code, locator) = ("0123456789ABCDEFGHJKMNPQRSTVWXYZ", "ABCDEFGHJKMN")
        let scanService = try FakeVaultService()
        let scanPhone = try TestVaultPhone(service: scanService)
        defer { scanPhone.close(); phone.close() }
        let a = try scanService.armRecovery(pin: pin, password: password, recoveryID: id, code: code, locator: locator)
        let b = try service.armRecovery(pin: pin, password: password, recoveryID: id, code: code, locator: locator)
        #expect(try await scanPhone.manager.registerRecovery(try #require(RecoveryCode.parseScanned(a.qr))) == .registered(emailHint: scanService.emailHint))
        #expect(try await m.registerTypedRecovery(try typed(b)) == .registered(emailHint: service.emailHint))
        let (s, t) = (try #require(scanService.recoveryRegisters.first), try #require(service.recoveryRegisters.first))
        #expect(s.userGuid == t.userGuid && s.vaultID == t.vaultID && s.recoveryID == t.recoveryID && s.code == t.code)
        #expect(s.platform == t.platform && s.name == t.name && s.shape == t.shape)
        // The decrypted bodies, but for the request id, the keys of the phone and its attestation.
        #expect(s.normalized == t.normalized && !s.normalized.isEmpty)
        // The typed code claimed by its locator, which named the vault and the recovery.
        let claim = try #require(service.recoveryClaims.first)
        #expect(claim.kind == "locator" && claim.locator == locator && claim.vaultID == nil)
        #expect(m.record.value.vaultID == scanService.vaultID && m.record.value.vaultID == b.vaultID)
        #expect(m.phase == .setup(.recovering) && scanPhone.manager.phase == .setup(.recovering))
    }

    @Test func theClaimsRefusalsHaveTheirOwnCodesAndRegisterNothing() async throws {
        defer { phone.close() }
        let made = try armed()
        let code = try scanned(made)
        service.recoveryClaimAnswers(.notAvailable, .noBackup, .notFound)
        #expect(try await m.registerRecovery(code) == .refused(code: "not_available"))
        #expect(try await m.registerRecovery(code) == .refused(code: "no_backup"))
        #expect(try await m.registerRecovery(code) == .refused(code: "no_recovery"))
        #expect(service.recoveryRegisters.isEmpty && device?.recovering == false && !pendingRecord && m.phase != .setup(.recovering))
        #expect(!m.record.value.recoveryRegistered)
        // An unknown recovery is the claim's 404.
        let other = try #require(RecoveryCode.parseScanned(made.qr.replacingOccurrences(of: made.recoveryID, with: Ulid.new())))
        #expect(try await m.registerRecovery(other) == .refused(code: "no_recovery"))
    }

    @Test func aRateLimitedClaimIsAFailureWithItsWait() async throws {
        defer { phone.close() }
        let code = try scanned(try armed())
        service.recoveryClaimAnswers(.limited(42))
        let f = await vaultFailure { _ = try await m.registerRecovery(code) }
        #expect(f?.kind == .rateLimited && f?.retryAfterSeconds == 42)
        service.recoveryClaimAnswers(.offline)
        #expect(await vaultFailure { _ = try await m.registerRecovery(code) } != nil)
        #expect(device?.recovering == false)
    }

    @Test func theEnclavesRefusalsOfTheRegisterAreItsCodesAndNothingStays() async throws {
        defer { phone.close() }
        let code = try scanned(try armed())
        for refusal in ["bad_code", "expired", "too_early", "used", "attestation", "retry", "no_recovery"] {
            service.recoveryRegisterAnswers(.refused(refusal))
            #expect(try await m.registerRecovery(code) == .refused(code: refusal))
            // Forgotten, so that a new code can be tried; the epoch-1 record the register made goes with it.
            #expect(device?.recovering == false && device?.vaultID == nil && !pendingRecord && m.phase != .setup(.recovering))
            // Refused for certain, by a register this call built: the marks go with the registration.
            #expect(!m.record.value.recoveryRegistered && phone.attestStartOver.value == m.record.value.noVaultHoldsAttestKey)
        }
        // A refusal after a typed code's claim names its recovery; the claim's own 404 names none.
        let made = try armed()
        service.recoveryRegisterAnswers(.refused("bad_code"))
        #expect(try await m.registerTypedRecovery(try typed(made)) == .refused(code: "bad_code", recoveryID: made.recoveryID))
        service.recoveryClaimAnswers(.notFound)
        #expect(try await m.registerTypedRecovery(try typed(made)) == .refused(code: "no_recovery"))
    }

    @Test func aWrongCodeIsRefusedByTheVault() async throws {
        defer { phone.close() }
        let made = try armed()
        let wrong = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        let other = try #require(RecoveryCode.parseScanned(made.qr.replacingOccurrences(of: made.code, with: made.code == wrong ? "ZYXWVTSRQPNMKJHGFEDCBA9876543210" : wrong)))
        #expect(try await m.registerRecovery(other) == .refused(code: "bad_code"))
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
    }

    @Test func theMemberApiRefusalsOfTheRegisterAreRefusalsToo() async throws {
        defer { phone.close() }
        let code = try scanned(try armed())
        service.recoveryRegisterAnswers(.apiNotAvailable, .apiNoBackup)
        #expect(try await m.registerRecovery(code) == .refused(code: "not_available"))
        #expect(try await m.registerRecovery(code) == .refused(code: "no_backup"))
        #expect(device?.recovering == false && !pendingRecord)
    }

    @Test func aRegisterThatCouldNotBeSentLeavesTheRegistrationForARetry() async throws {
        defer { phone.close() }
        let code = try scanned(try armed())
        service.recoveryRegisterAnswers(.offline)
        #expect(await vaultFailure { _ = try await m.registerRecovery(code) } != nil)
        // Unknown outcome: the registration and the phone key stay, and a retry reuses them.
        #expect(device?.recovering == true && pendingRecord)
        let key = try m.phoneSecrets.records().pendings.first?.keyID
        #expect(try await m.registerRecovery(code) == .registered(emailHint: service.emailHint))
        #expect(try m.phoneSecrets.records().pendings.map(\.keyID) == [try #require(key)])
    }

    @Test func aReleaseThatDoesNotOfferRecoveryGetsNothing() async throws {
        defer { phone.close() }
        service.capabilities = [Capabilities.recoveryR]
        #expect(try await m.registerRecovery(try scanned(try armed())) == .refused(code: VaultManager.codeNotOffered))
        #expect(service.recoveryRegisters.isEmpty && device?.recovering == false && !pendingRecord)
    }

    @Test func aReleaseBeforeRIsRefusedBeforeAnythingIsSent() async throws {
        defer { phone.close() }
        service.capabilities = []
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(try armed())) }
        #expect(f?.kind == .releaseTooOld && service.recoveryRegisters.isEmpty && !pendingRecord)
    }

    @Test func aTimeScaleThisBuildDoesNotAcceptIsRefusedBeforeAnythingIsSent() async throws {
        defer { phone.close() }
        service.timeScale = 24
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(try armed())) }
        #expect(f?.kind == .timeScale && service.recoveryRegisters.isEmpty && !pendingRecord)
    }

    @Test func theInstancesTimeScaleIsKeptWithTheVault() async throws {
        defer { phone.close() }
        let scaled = try FakeVaultService()
        scaled.timeScales = .staging
        scaled.timeScale = 24
        let p = try TestVaultPhone(service: scaled)
        defer { p.close() }
        let made = try scaled.armRecovery(pin: pin, password: password)
        _ = try await p.manager.registerRecovery(try #require(RecoveryCode.parseScanned(made.qr)))
        #expect(p.manager.record.value.timeScale == 24 && p.manager.timeScale == 24)
    }

    @Test func aPhoneThatHoldsAVaultRegistersNoRecovery() async throws {
        defer { phone.close() }
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(try armed())) }
        #expect(f?.kind == .vaultExists || f?.kind == .enrollmentStarted)
        #expect(service.recoveryRegisters.isEmpty)
    }

    // MARK: - The open (§11.14.6)

    @Test func theRightEntryRecoversTheVaultOntoThisPhone() async throws {
        defer { phone.close() }
        let made = try await registered()
        let outcome = try await m.recoveryOpen(pin: pin, password: password)
        #expect(outcome == RecoveryOpenOutcome("ok", used: 1, attemptUsed: true))
        // What the vault received: the PIN, the password and this phone's secret of epoch 1.
        let seen = try #require(service.recoveryOpens.first)
        #expect(seen.recoveryID == made.recoveryID && seen.pin == pin && seen.password == password && seen.unlockSecret.count == 32)
        // The first handshake carried the recovery id (§11.14.6), and the credential is here.
        #expect(service.recoveryHandshakeContexts == [made.recoveryID] && !service.recoveryInvitation)
        #expect(device?.deviceID != nil && device?.hasVault == true && device?.credentialVersion != nil)
        // The recovery is over; the phone's record is the current one and the app waits for the member to read the text.
        let isOpened = try await m.recoveryOpened()
        #expect(device?.recovering == false && !isOpened)
        #expect(hasCurrentRecord && !pendingRecord && m.record.value.recoveryAttemptsUsed == 1 && m.recoveryAttemptsUsed == 1)
        #expect(m.record.value.enrollConfirmed && !m.record.value.recoveryOpenUnanswered)
        #expect(m.phase == .setup(.recovering))
        // The secret the vault holds now is this phone's: an unlock with it opens the vault.
        #expect(service.unlocks.isEmpty)
        try await m.finishRecoveryOpen()
        #expect(m.phase == .unlocked && m.record.value.setupComplete)
    }

    @Test func theOpenSendsTheManifestAndOnlyOnReleaseR() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.capabilities = []
        let f = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(f?.kind == .releaseTooOld && service.recoveryOpens.isEmpty)
        service.capabilities = [Capabilities.recoveryOffered, Capabilities.recoveryR]
        _ = try await m.recoveryOpen(pin: pin, password: password)
        #expect(try #require(service.recoveryOpens.first).manifestSerial >= 1)
    }

    @Test func aWrongEntryUsesAnAttemptAndTheSameWrongPairIsNotCountedAgain() async throws {
        defer { phone.close() }
        _ = try await registered()
        let first = try await m.recoveryOpen(pin: "111111", password: password)
        #expect(first.code == "wrong" && first.used == 1 && first.attemptUsed == true && first.retryAt == nil && !first.opened)
        #expect(m.recoveryAttemptsUsed == 1 && m.record.value.recoveryAttemptsUsed == 1)
        // The same pair again: nothing used (§11.14.6 step 2a).
        let again = try await m.recoveryOpen(pin: "111111", password: password)
        #expect(again.code == "wrong_again" && again.used == 1 && again.attemptUsed == false)
        // Another wrong pair: the second attempt, and a wait begins.
        let second = try await m.recoveryOpen(pin: pin, password: "wrong password")
        #expect(second.code == "wrong" && second.used == 2 && second.retryAt != nil && service.recoveryAttemptsUsed == 2)
        #expect(device?.recovering == true && m.phase == .setup(.recovering) && pendingRecord)
        // The right entry still recovers it, as the third attempt.
        #expect(try await m.recoveryOpen(pin: pin, password: password) == RecoveryOpenOutcome("ok", used: 3, attemptUsed: true))
    }

    @Test func theVaultsOtherAnswersAreReportedAsTheyCame() async throws {
        defer { phone.close() }
        _ = try await registered()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        service.recoveryOpenAnswers(
            .refused("quiet", attemptUsed: false, used: 0, retryAt: at), .refused("busy", attemptUsed: false), .refused("exhausted", attemptUsed: false, used: 10),
            .refused("retry", attemptUsed: true, used: 4), .refused("counter_unavailable", attemptUsed: nil)
        )
        let quiet = try await m.recoveryOpen(pin: pin, password: password)
        #expect(quiet == RecoveryOpenOutcome("quiet", used: 0, retryAt: at, attemptUsed: false))
        let busy = try await m.recoveryOpen(pin: pin, password: password)
        // `busy` carries no counter: the attempts last reported stay.
        #expect(busy == RecoveryOpenOutcome("busy", attemptUsed: false) && m.recoveryAttemptsUsed == 0)
        #expect(try await m.recoveryOpen(pin: pin, password: password) == RecoveryOpenOutcome("exhausted", used: 10, attemptUsed: false))
        #expect(m.recoveryAttemptsUsed == 10)
        let retry = try await m.recoveryOpen(pin: pin, password: password)
        #expect(retry.code == "retry" && retry.attemptUsed == true && retry.used == 4)
        #expect(try await m.recoveryOpen(pin: pin, password: password).attemptUsed == nil)
        // None of them opened anything.
        let isOpened = try await m.recoveryOpened()
        #expect(device?.recovering == true && !isOpened && !service.recoveryCompleted)
    }

    // MARK: - An open that got no answer, and a lost ok (§11.14.6)

    @Test func anOpenWhoseAnswerNeverCameIsRememberedAndTheNextAnswerSaysSo() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.unreadable)
        let f = await vaultFailure { _ = try await m.recoveryOpen(pin: "111111", password: password) }
        #expect(f != nil && m.record.value.recoveryOpenUnanswered && service.recoveryAttemptsUsed == 0)
        // It survives a restart, and the next answer carries it.
        try await phone.restart()
        let next = try await m.recoveryOpen(pin: "111111", password: password)
        // The `wrong` after an unanswered open proves nothing about it: the mark stays (IOS-PLAN 0.1.38 §4.10).
        #expect(next.code == "wrong" && next.afterUnanswered && m.record.value.recoveryOpenUnanswered)
        // So the answer after that says it too.
        #expect(try await m.recoveryOpen(pin: "222222", password: password).afterUnanswered)
    }

    @Test func aLostOkIsResumedByAnUnlockAndNoAttemptIsUsed() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        let f = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(f != nil && service.recoveryCompleted && service.recoveryInvitation)
        // The vault completed it; this phone does not know: no bundle, no token, still recovering.
        #expect(device?.hasVault == false && device?.recovering == true && m.record.value.recoveryOpenUnanswered)
        let outcome = try await m.resumeLostOk(pin: pin)
        #expect(outcome == RecoveryOpenOutcome("ok", used: nil, attemptUsed: false))
        #expect(service.unlocks.count == 1 && service.unlocks[0].pin == pin && service.unlocks[0].unlockSecret?.count == 32)
        #expect(device?.hasVault == true && device?.deviceID != nil && device?.recovering == false && device?.credentialVersion != nil)
        #expect(service.recoveryHandshakeContexts == [try #require(service.recoveryOpens.first).recoveryID])
        #expect(hasCurrentRecord && !pendingRecord && service.recoveryAttemptsUsed == 1)
        try await m.finishRecoveryOpen()
        #expect(m.phase == .unlocked)
    }

    @Test func aLostOkWithAWrongPinSaysSoAndChangesNothing() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        let bad = try await m.resumeLostOk(pin: "111111")
        #expect(bad.code == "bad_pin" && bad.opened && bad.attemptUsed == false)
        #expect(device?.recovering == true && device?.hasVault == false)
        #expect(try await m.resumeLostOk(pin: pin).ok)
    }

    /// A registered phone the vault did not adopt is not one of its unlock keys: its unlock is answered random bytes. The member
    /// API says the recovery is still registered, and this phone is not its app: the open can be tried again.
    @Test func aRecoveryThatDidNotCompleteHereIsNotResumed() async throws {
        defer { phone.close() }
        _ = try await registered()
        let outcome = try await m.resumeLostOk(pin: pin)
        #expect(outcome == RecoveryOpenOutcome(VaultManager.codeNoBundle, opened: true, attemptUsed: false))
        #expect(device?.recovering == true && device?.hasVault == false)
    }

    /// An unlock that opens without handing over a bundle proves the vault accepts this phone's key: nothing is cleared.
    @Test func anOkUnlockWithoutABundleKeepsTheMarkAndTheKey() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.unreadable)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: "111111", password: password) }
        let secret = try m.phoneSecrets.reuseOrCreate(keyVault: service.vaultID).secret
        service.storeSecret(secret)
        service.registeredPhoneHoldsUnlockKey()
        let f = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(f?.code == MoveCodes.recoveryOpened && m.record.value.recoveryOpenUnanswered)
        let a = await vaultFailure { try await m.abandonRecovery() }
        #expect(a?.code != nil && (pendingRecord || hasCurrentRecord) && device?.recovering == true)
    }

    @Test func aPhoneWithNothingToResumeSaysSo() async throws {
        defer { phone.close() }
        let f = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(f?.kind == .notSupported && f?.code == "no_recovery")
        let g = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(g?.kind == .notSupported && g?.code == "no_recovery")
    }

    // MARK: - An ok that was not finished (§11.14.6)

    /// The vault answered `ok` but the credential did not come: the phone is the vault's app, the PIN alone finishes it, and
    /// no new open is ever sent.
    @Test func anOkWhoseCredentialDidNotComeIsFinishedWithThePinAlone() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.loseAnswers(["credential.get"])
        let f = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(f?.kind == .noResponse)
        let isOpened = try await m.recoveryOpened()
        #expect(isOpened && device?.recovering == true && device?.deviceID != nil)
        // Not paired with a credential yet: another open is never sent; a restart keeps the state.
        try await phone.restart()
        #expect(try await m.recoveryOpened())
        service.loseAnswers([])
        let opens = service.recoveryOpens.count
        let outcome = try await m.recoveryOpen(pin: pin, password: "") // the password is not needed any more
        #expect(outcome.ok && service.recoveryOpens.count == opens)
        let finished = try await m.recoveryOpened()
        #expect(!finished && device?.credentialVersion != nil && device?.recovering == false)
        try await m.finishRecoveryOpen()
        #expect(m.phase == .unlocked)
    }

    @Test func aRecoveryTheVaultMadeIsNeverAbandoned() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.loseAnswers(["credential.get"])
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        let f = await vaultFailure { try await m.abandonRecovery() }
        #expect(f?.code == MoveCodes.recoveryOpened && device?.recovering == true)
        // The phone key stays.
        #expect(m.usesPhoneSecret && hasCurrentRecord)
    }

    /// A lock still pending: locked whatever the vault says, and told so (the unlock screen's words).
    @Test func aLockPendingMeanwhileKeepsThePhoneLockedAndSaysSo() async throws {
        defer { phone.close() }
        _ = try await registered()
        _ = try await m.recoveryOpen(pin: pin, password: password)
        service.relayLockAnswer = .noAnswer
        service.memberLockAnswer = .queued
        try await m.lock()
        #expect(m.lockPending)
        let f = await vaultFailure { try await m.finishRecoveryOpen() }
        #expect(f?.kind == .noResponse && f?.code == MoveCodes.lockPending && m.phase == .locked && !m.record.value.setupComplete)
    }

    // MARK: - Leaving a registration

    @Test func startingOverForgetsTheRegistrationAndTheKeysForIt() async throws {
        defer { phone.close() }
        let made = try await registered()
        let appKey = try phone.appKeys.getOrCreate().spki()
        try await m.abandonRecovery()
        #expect(m.phase == .signedOut && m.record.value == LocalAccount() && !m.usesPhoneSecret && !pendingRecord)
        #expect(try await m.recoveryStage() == .code)
        // New device keys and a new app key: the claim bound the old ones to the recovery.
        #expect(try phone.appKeys.getOrCreate().spki() != appKey)
        // A new code (or the same one again) starts afresh.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(service.recoveryClaims.count == 2 && m.phase == .setup(.recovering))
    }

    @Test func startingOverOnAPhoneThatRegisteredNothingChangesNothing() async throws {
        defer { phone.close() }
        try await m.abandonRecovery()
        #expect(m.phase == .starting && m.record.value == LocalAccount())
    }

    // MARK: - The recovery of before release R (IOS-PLAN ID8)

    @Test func theRecoveryBeforeReleaseRIsNotImplemented() async throws {
        defer { phone.close() }
        _ = try await registered()
        for body in [
            { _ = try await m.recoveryUnlock(pin: pin, approve: nil) }, { _ = try await m.recoveryCredentialBackup() },
            { _ = try await m.recoverCredential(password: password) },
        ] as [@MainActor () async throws -> Void] {
            let f = await vaultFailure(body)
            #expect(f?.kind == .notSupported && f?.code == VaultManager.codeRecoveryBeforeR)
        }
        #expect(service.unlocks.isEmpty)
    }

    @Test func thePreflightIsTheUnlocksAndNamesTheRoutedRelease() async throws {
        defer { phone.close() }
        _ = try await registered()
        let p = try await m.recoveryPreflight()
        #expect(p.routed.number == 3 && !p.rollback)
    }
}

// swiftlint:enable line_length
