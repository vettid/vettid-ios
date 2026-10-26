import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// swiftlint:disable line_length

/// A phone that could not tell, after the second read: the new recovery with a new device identity and the same K, the open with
/// the earlier open's unlock secret, `409 key_in_use`, and the pairing of either identity (IOS-PLAN 0.1.35 §4.9). Continues
/// ``VaultManagerRecoveryTests``.
extension VaultManagerRecoveryTests {
    /// A second recovery of the same vault, as the member starts it on the account site.
    func secondRecovery() throws -> FakeVaultService.RecoveryCodeMade { try service.armRecovery(pin: pin, password: password) }

    // MARK: - The new identity and the same K

    @Test func theNewRecoveryIsClaimedWithKAndRegisteredWithANewIdentityAndTheSameK() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        let first = try await endedForGood()
        let earlier = try #require(service.recoveryRegisters.first)
        let made = try secondRecovery()
        let attested = phone.attester.attested.count
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        // The claim and the register carry K; the identity, the KEM key and the relay key are new.
        #expect(service.recoveryClaims.last?.appKey == k)
        let seen = try #require(service.recoveryRegisters.last)
        #expect(service.recoveryRegisters.count == 2 && seen.recoveryID == made.recoveryID && seen.apiKey == k && seen.apiKey == earlier.apiKey)
        #expect(seen.ik != earlier.ik && seen.kem != earlier.kem && seen.relayKey != earlier.relayKey)
        // A key of its own was attested for it, and the identity in use is the second.
        #expect(phone.attester.attested.count == attested + 1 && phone.attester.identityInUse == 1 && phone.attester.forgotten == [1])
        #expect(phone.attester.attestationIdentities.last == 1 && phone.attester.keptReplacedKeys == [1] && phone.attester.settled.isEmpty)
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.earlier == .first && ct.new == .second && m.record.value.activeIdentity == .second && device?.recoveryID == made.recoveryID)
        // Nothing was deleted: the earlier identity's keys, device state (with the earlier recovery id) and phone-secret record.
        try expectKept(k, secondToo: true)
        try await m.selectIdentity(.first)
        let earlierDevice = try await m.openSession().device
        #expect(earlierDevice.recoveryID == first.recoveryID && earlierDevice.recovering && earlierDevice.recoveryOpenRequestIDs.count == 1)
        try await m.selectIdentity(.second)
        // And the new recovery's stage is the open.
        #expect(try await m.couldNotTellStage() == .none && m.phase == .setup(.recovering))
    }

    @Test func aTypedCodeIsTheSameRule() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        #expect(try await m.registerTypedRecovery(try typed(made)) == .registered(emailHint: service.emailHint))
        #expect(service.recoveryClaims.last?.kind == "locator" && service.recoveryClaims.last?.appKey == k)
        #expect(service.recoveryRegisters.last?.apiKey == k && m.record.value.activeIdentity == .second)
    }

    @Test func theOpenCarriesTheEarlierOpensUnlockSecretAndTheNewRecoveryId() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(made))
        let out = try await m.recoveryOpen(pin: pin, password: password)
        #expect(out.ok)
        let (a, b) = (try #require(service.recoveryOpens.first), try #require(service.recoveryOpens.last))
        #expect(service.recoveryOpens.count == 2 && b.recoveryID == made.recoveryID && a.unlockSecret == b.unlockSecret && b.unlockSecret.count == 32)
        // The first handshake names the new recovery, and with the pairing complete the earlier identity and its records go.
        #expect(service.recoveryHandshakeContexts == [made.recoveryID] && device?.deviceID != nil && device?.recovering == false)
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .second)
        for slot in KeySlot.slots(of: .first) { #expect(try phone.wrapped.get(slot) == nil) }
        #expect(try !FileManager.default.fileExists(atPath: phone.directory.appendingPathComponent(VaultFiles.device).path))
        #expect(phone.attester.settled == [1] && hasCurrentRecord && !pendingRecord)
        // K is the same, and the phone is the vault's app with the second identity from now on.
        #expect(try phone.appKeys.getOrCreate().spki() == k)
        try await phone.restart()
        try await m.finishRecoveryOpen()
        #expect(m.phase == .unlocked)
    }

    @Test func aScannedCodeOfAnotherVaultIsRefusedBeforeTheClaim() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        let other = try #require(RecoveryCode.parseScanned(made.qr.replacingOccurrences(of: made.vaultID, with: "someone-elses-vault")))
        let claims = service.recoveryClaims.count
        #expect(try await m.registerRecovery(other) == .refused(code: VaultManager.codeOtherVault))
        #expect(service.recoveryClaims.count == claims && service.recoveryRegisters.count == 1)
        #expect(m.record.value.couldNotTell?.new == nil && m.record.value.activeIdentity == .first)
        try expectKept(k)
    }

    @Test func aRefusedRegisterOfTheNewRecoveryForgetsTheNewIdentityOnly() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryRegisterAnswers(.refused("bad_code"))
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: "bad_code"))
        // The new identity is unregistered (the screens find the code step), the earlier one and its registration stay.
        #expect(device?.recovering == false && m.record.value.recoveryRegistered && pendingRecord)
        #expect(try await m.couldNotTellStage() == .newCode)
        try expectKept(k, secondToo: true)
        // A new try uses the same identity, and the same phone-secret record.
        let key = try m.phoneSecrets.records().pendings.map(\.keyID)
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(try m.phoneSecrets.records().pendings.map(\.keyID) == key && m.record.value.couldNotTell?.new == .second)
        #expect(service.recoveryRegisters.count == 3)
    }

    @Test func aNewRecoveryHasItsOwnStageAfterARestart() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // The first register failed before it reached the vault (no network), and the app is killed.
        service.recoveryRegisterAnswers(.offline)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        try await phone.restart()
        _ = try await m.couldNotTellStage()
        #expect(m.record.value.couldNotTell?.new == .second && m.record.value.activeIdentity == .second)
        // (The POST was recorded before it was posted: the next one for this code is a repeat.)
        #expect(try await m.openSession().device.recovering == false && m.record.value.couldNotTell?.registerTried == made.recoveryID)
        // Not registered: the same N, K and code try again.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        try await phone.restart()
        #expect(try await m.recoveryStage() == .pin && device?.recoveryID == made.recoveryID)
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
    }

    // MARK: - The earlier open's answer, read once

    @Test func aReadableOkForTheEarlierOpenDecidesItAndRegistersNothing() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        // Stopped after step 2: K is only the vault's pending next key, so a claim with it passes.
        service.nextOpenStopsAfterStep2()
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let made = try secondRecovery()
        let rid = try #require(service.recoveryOpens.first?.requestID)
        service.answerReadable(rid)
        let registers = service.recoveryRegisters.count
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: VaultManager.codeRecoveryOpenSent))
        // The claim was made, the slot read once; no new identity, no register: the PIN finishes the earlier open.
        #expect(service.recoveryRegisters.count == registers && m.record.value.couldNotTell?.new == nil && device?.recoveryOpenedNotFinished == true)
        try expectKept(k)
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [first.recoveryID] && m.record.value.couldNotTell == nil)
    }

    @Test func aReadableRefusalOfTheEarlierOpenAlsoDecidesIt() async throws {
        defer { phone.close() }
        try await endedForGood(.wrongAnswerLost)
        let rid = try #require(service.recoveryOpens.first?.requestID)
        service.answerReadable(rid)
        let made = try secondRecovery()
        // The earlier open was refused (a wrong entry): the record existed, so no earlier open was adopted; the new recovery goes on.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(m.record.value.couldNotTell?.new == .second && m.record.value.activeIdentity == .second)
    }

    // MARK: - 409 key_in_use

    @Test func aClaimThatIsAKeyInUseUnlocksWithTheEarlierIdentity() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        // The vault adopted this phone (K is its app key), and two reads said `401`.
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let made = try secondRecovery()
        let registers = service.recoveryRegisters.count
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: VaultManager.codeKeyInUse))
        // Nothing registered, nothing made; the lost-ok unlock is what is left, and a start over is refused.
        #expect(service.recoveryRegisters.count == registers && m.record.value.couldNotTell?.new == nil)
        #expect(try await m.couldNotTellStage() == .finishWithPin)
        let a = await vaultFailure { try await m.abandonRecovery() }
        #expect(a?.code == VaultManager.codeRecoveryOpenSent)
        try expectKept(k)
        // Killed and started again: the unlock is still what is left.
        try await phone.restart()
        #expect(try await m.couldNotTellStage() == .finishWithPin && m.record.value.couldNotTell?.unlock == true)
        // Another code is not registered over it: the PIN is what is left.
        let again = await vaultFailure { _ = try await m.registerTypedRecovery(try typed(made)) }
        #expect(again?.code == VaultManager.codeRecoveryOpenSent)
        // The unlock opens: the earlier identity pairs with the earlier recovery id.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [first.recoveryID] && m.record.value.couldNotTell == nil)
    }

    @Test func aTypedCodeThatIsAKeyInUseIsTheSame() async throws {
        defer { phone.close() }
        try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let made = try secondRecovery()
        #expect(try await m.registerTypedRecovery(try typed(made)) == .refused(code: VaultManager.codeKeyInUse, recoveryID: nil))
        #expect(try await m.couldNotTellStage() == .finishWithPin && service.recoveryRegisters.count == 1)
        #expect(try await m.resumeLostOk(pin: pin).ok)
    }

    @Test func aUnauthorizedRegisterThenAKeyInUseClaimUnlocksToo() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        // The register is `401` (twice: the client asks again with a new signature), and a new claim is a key in use.
        service.recoveryRegisterAnswers(.unauthorized, .unauthorized)
        service.recoveryClaimAnswers(.vault, .keyInUse)
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: VaultManager.codeKeyInUse))
        let ct = try #require(m.record.value.couldNotTell)
        // A first N that never registered is dropped (it no longer counts as one of the two): the earlier one is at the PIN.
        let atPin = try await m.openSession().device
        #expect(ct.unlock && ct.new == nil && ct.identities == [.first] && m.record.value.activeIdentity == .first && atPin.recovering)
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) == nil) }
        #expect(try await m.couldNotTellStage() == .finishWithPin)
        // The unlock is refused by a vault that has not adopted this phone: everything else is kept.
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.code == VaultManager.codeNoBundle)
        try expectKept(k)
        #expect(m.record.value.activeIdentity == .first)
    }

    @Test func aUnauthorizedRegisterAloneIsKeptAsAnError() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryRegisterAnswers(.unauthorized, .unauthorized)
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(f?.kind == .unauthorized)
        // The new claim was no key in use: the rule goes on. A `401` queued nothing, so N (which never registered) is dropped,
        // E and K stay, and the code step stays.
        #expect(m.record.value.couldNotTell?.unlock == false && m.record.value.couldNotTell?.ended == true)
        #expect(m.record.value.couldNotTell?.identities == [.first] && m.record.value.activeIdentity == .first)
        #expect(try await m.couldNotTellStage() == .newCode)
        try expectKept(k)
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) == nil) }
        // A later code makes N anew.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(m.record.value.couldNotTell?.new == .second && phone.attester.forgotten.filter { $0 == 1 }.count >= 2)
    }

    // MARK: - Either identity pairs

    @Test func withNoHsRespForTheNewIdentityTheEarlierOneUnlocksAndPairsWithItsOwnRecoveryId() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        // The handshake the vault does not answer is seen within seconds here (90 s after `ok` otherwise).
        phone.pairingWait = 4
        try await phone.restart()
        service.nextOpenStopsAfterStep2()
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let made = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        // The new open answers `ok` (the vault repeats the stopped recovery), but its invitation is the earlier identity's:
        // the handshake with the new recovery id is never answered, and the earlier identity unlocks and pairs.
        let out = try await m.recoveryOpen(pin: pin, password: password)
        #expect(out.ok)
        #expect(service.recoveryHandshakeContexts == [made.recoveryID, first.recoveryID])
        #expect(m.record.value.activeIdentity == .first && device?.recoveryID == nil && device?.deviceID != nil)
        #expect(m.record.value.couldNotTell == nil && service.unlocks.count == 1)
        // The unlock asserted with the earlier identity's key; the new identity went.
        #expect(phone.attester.assertionIdentities.last == 0 && phone.attester.settled == [0])
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) == nil) }
        #expect(try phone.appKeys.getOrCreate().spki() == k)
        try await m.finishRecoveryOpen()
        #expect(m.phase == .unlocked)
    }

    @Test func theNewIdentityIsTriedFirstThenTheEarlierOne() async throws {
        defer { phone.close() }
        service.nextOpenStopsAfterStep2()
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let made = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(made))
        // The new open's answer is lost too; the vault repeated the recovery, and its device is still the earlier identity.
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // Two reads of `200`: what is left is the unlock with either.
        #expect(try await twoReads() == .finishWithPin)
        #expect(m.record.value.couldNotTell?.unlock == true)
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.ok)
        // The vault answered the new identity's unlock with bytes it cannot read; the earlier one opened.
        #expect(phone.attester.assertionIdentities.suffix(2) == [1, 0])
        #expect(service.recoveryHandshakeContexts.last == first.recoveryID && m.record.value.couldNotTell == nil)
        #expect(m.record.value.activeIdentity == .first)
    }

    @Test func thePairingOfTheNewIdentityIsNeverAnsweredByTheEarlierOnesUnlockWhenTheVaultAdoptedTheNewOne() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(made))
        // The new open completed at the vault but its answer was lost; two reads of `401` then the unlock with the new identity.
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // The vault took the new identity: the status reads `200` with no recovery.
        #expect(try await twoReads() == .finishWithPin)
        #expect(try await m.resumeLostOk(pin: pin).ok)
        // The new identity's unlock opened first; its handshake names the new recovery; the earlier identity went.
        #expect(service.unlocks.count == 1 && service.recoveryHandshakeContexts == [made.recoveryID])
        #expect(m.record.value.activeIdentity == .second && m.record.value.couldNotTell == nil)
        for slot in KeySlot.slots(of: .first) { #expect(try phone.wrapped.get(slot) == nil) }
    }

    // MARK: - A crash at each step

    @Test func aKillAfterTheOkButBeforeThePairingResumesWithEitherIdentity() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(made))
        // The open answers `ok`; the credential then never comes, and the app is killed.
        service.loseAnswers(["credential.get"])
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        try await phone.restart()
        #expect(try await m.recoveryOpened())
        // Everything is still there until the pairing completes: the earlier identity too.
        try expectKept(k, secondToo: true)
        #expect(m.record.value.couldNotTell != nil)
        service.loseAnswers([])
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        #expect(m.record.value.couldNotTell == nil && device?.recovering == false)
    }

    @Test func aKillBetweenTheDecisionAndTheCodeLeavesTheRuleForTheNextStart() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        try await phone.restart()
        #expect(try await m.couldNotTellStage() == .newCode && m.record.value.couldNotTell?.ended == true)
        try expectKept(k)
        let made = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
    }

    @Test func aWipeEraseseverything() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(made))
        try await m.eraseThisPhone()
        for slot in KeySlot.allCases { #expect(try phone.wrapped.get(slot) == nil) }
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .first)
    }
}

/// The new identity's own recovery ending, the decided state, a kill during the trial, the forget, the setup code and the
/// register's `401` (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    // MARK: - The new identity's recovery ended

    @Test func aReadableOkForTheEarlierOpenIsTheStageOfThePin() async throws {
        defer { phone.close() }
        service.nextOpenStopsAfterStep2()
        try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let made = try secondRecovery()
        service.answerReadable(try #require(service.recoveryOpens.first?.requestID))
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: VaultManager.codeRecoveryOpenSent))
        #expect(try await m.couldNotTellStage() == .finishWithPin && m.record.value.couldNotTell?.ended == false)
        try await phone.restart()
        #expect(try await m.couldNotTellStage() == .finishWithPin)
    }

    @Test func aKillDuringTheTrialOfTheEarlierIdentityGoesBackToTheOneThatHasTheOk() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.loseAnswers(["credential.get"])
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // The pairing began: the identity that has the `ok` is written down.
        #expect(m.record.value.activeIdentity == .second)
        // A kill in the middle of the earlier identity's trial leaves it active, with the trial marked.
        try m.persistRecord(m.record.generation) {
            $0.couldNotTell?.returnTo = .second
            $0.activeIdentity = .first
        }
        try await phone.restart()
        service.loseAnswers([])
        #expect(try await m.recoveryOpened() && m.record.value.activeIdentity == .second && m.record.value.couldNotTell?.returnTo == nil)
        try expectKept(k, secondToo: true)
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
    }

    // MARK: - Forget, setup code

    @Test func aForgetResetsTheAppAttestIdentitiesSoASecondEpisodeStartsClean() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        #expect(m.record.value.activeIdentity == .second && phone.attester.identityInUse == 1)
        let resets = phone.attester.resets
        try await m.dropSession(forget: true, vaultGone: true)
        #expect(phone.attester.resets == resets + 1 && m.record.value.activeIdentity == .first)
        _ = try await m.openSession()
        #expect(phone.attester.identityInUse == 0)
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) == nil) }
        // The new identity of the next episode has its parked keys dropped before its first use.
        let before = phone.attester.forgotten.count
        _ = try await openGotNoAnswerAgain()
        #expect(phone.attester.forgotten.count > before)
    }

    /// A second episode on a forgotten phone: a registration, an open that got no answer, the rule.
    func openGotNoAnswerAgain() async throws -> FakeVaultService.RecoveryCodeMade {
        let made = try armed()
        _ = try await m.registerRecovery(try scanned(made))
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .newCode)
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        return made
    }

    @Test func theSetupCodeNeitherForgetsNorRedeemsWhileThePhoneCouldNotTell() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let redeem = await vaultFailure { _ = try await m.redeemSetupCode(.secret(service.secret)) }
        #expect(redeem?.code == VaultManager.codeRecoveryOpenSent)
        let forget = await vaultFailure { try await m.forgetSetupCode() }
        #expect(forget?.code == VaultManager.codeRecoveryOpenSent)
        try expectKept(k)
        // Also with the new identity made and no device state stored for it yet.
        _ = try? await m.registerRecovery(try scanned(try secondRecovery()))
        #expect(await vaultFailure { try await m.forgetSetupCode() }?.code == VaultManager.codeRecoveryOpenSent)
        try expectKept(k, secondToo: true)
    }

    // MARK: - The register's 401

    @Test func aUnauthorizedAnswerToThePollAfterTheRegisterWasQueuedKeepsTheRegistration() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        let claims = service.recoveryClaims.count
        service.recoveryRegisterAnswers(.slotUnauthorized)
        // (The status with K does not show the registration yet.)
        service.recoveryStatusShows("available")
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(f?.kind == .unauthorized)
        // The register was queued: maybe registered, so the new identity keeps its registration, and nothing is claimed again.
        let d = try await m.openSession().device
        #expect(d.recovering && service.recoveryClaims.count == claims + 1 && m.record.value.couldNotTell?.unlock == false)
    }

    // MARK: - The run of refusals

    @Test func aPinAnsweredWrongEndsTheRunOfRefusals() async throws {
        defer { phone.close() }
        try await keyInUseUnlock()
        service.unlockAnswers(.sealed("unknown_device"))
        _ = try await m.resumeLostOk(pin: pin)
        #expect(m.record.value.couldNotTell?.refusalsSinceMs != nil)
        #expect(try await m.resumeLostOk(pin: "000000").code == "bad_pin")
        #expect(m.record.value.couldNotTell?.refusalsSinceMs == nil)
    }
}

// swiftlint:enable line_length
