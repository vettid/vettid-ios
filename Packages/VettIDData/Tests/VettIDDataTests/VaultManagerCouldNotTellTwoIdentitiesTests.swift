import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// Two identities at most, E and N, never a third (IOS-PLAN 0.1.35 §4.9; owner decisions of 2026-10-25): when N's recovery ends
/// too, the phone keeps both, tries the unlock with each, and registers N again for the next recovery; a code of another vault is
/// refused (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    /// N registers a new code, optionally opens, and its recovery ends too; two reads said so.
    func secondEnded(_ open: FakeVaultService.RecoveryOpenAnswer?, pin entered: String? = nil) async throws -> Codes {
        let first = try await endedForGood()
        let second = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(second)) == .registered(emailHint: service.emailHint))
        if let open {
            service.recoveryOpenAnswers(open)
            _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        } else if let entered {
            #expect(try await m.recoveryOpen(pin: entered, password: password).code == "wrong")
        }
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .unlockOrNewCode)
        return (first, second)
    }

    typealias Codes = (first: FakeVaultService.RecoveryCodeMade, second: FakeVaultService.RecoveryCodeMade)

    func expectBothKept(_ k: [UInt8], _ ids: Codes) async throws {
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.bothEnded && ct.unlock && !ct.unlockByReads && ct.ended && !ct.keyInUse && ct.identities == [.first, .second])
        try expectKept(k, secondToo: true)
        try await m.selectIdentity(.first)
        #expect(try await m.openSession().device.recoveryID == ids.first.recoveryID)
        try await m.selectIdentity(.second)
        #expect(try await m.openSession().device.recoveryID == ids.second.recoveryID)
    }

    @Test func whenTheSecondIdentitysRecoveryEndsWithAnUnansweredOpenBothAreKept() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        let ids = try await secondEnded(.neverProcessed)
        try await expectBothKept(k, ids)
    }

    @Test func whenTheSecondIdentitysRecoveryEndsWithNoOpenBothAreKept() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        let ids = try await secondEnded(nil)
        try await expectBothKept(k, ids)
    }

    @Test func whenTheSecondIdentitysRecoveryEndsAfterOnlyReadableRefusalsBothAreKeptToo() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        let ids = try await secondEnded(nil, pin: "111111")
        try await expectBothKept(k, ids)
    }

    // MARK: - N registered again

    @Test func aFurtherRecoveryRegistersNAgainAndOpensWithTheEarlierUnlockSecretNeverAThirdIdentity() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        let ids = try await secondEnded(.neverProcessed)
        let nRegister = try #require(service.recoveryRegisters.last)
        let (attested, registers) = (phone.attester.attested.count, service.recoveryRegisters.count)
        let third = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(third)) == .registered(emailHint: service.emailHint))
        // The same K, the same N keys, the new code; no third identity, and N pairs with the recovery it registered for last.
        let seen = try #require(service.recoveryRegisters.last)
        #expect(service.recoveryRegisters.count == registers + 1 && service.recoveryClaims.last?.appKey == k)
        #expect(seen.recoveryID == third.recoveryID && seen.apiKey == k)
        #expect(seen.ik == nRegister.ik && seen.kem == nRegister.kem && seen.relayKey == nRegister.relayKey)
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.identities == [.first, .second] && !ct.ended && !ct.unlock && !ct.bothEnded && m.record.value.activeIdentity == .second)
        #expect(device?.recoveryID == third.recoveryID && device?.recoveryOpens.count == 1)
        // A new App Attest key of its own, N's earlier ones kept: nothing of N is forgotten.
        #expect(phone.attester.attested.count == attested + 1 && phone.attester.attestationIdentities.last == 1)
        #expect(Set(phone.attester.attested).count == phone.attester.attested.count)
        #expect(phone.attester.forgotten == [1] && phone.attester.keptReplacedKeys == [1, 1] && phone.attester.settled.isEmpty)
        try expectKept(k, secondToo: true)
        try await m.selectIdentity(.first)
        #expect(try await m.openSession().device.recoveryID == ids.first.recoveryID)
        try await m.selectIdentity(.second)
        // The open carries E's unlock secret, and the pairing completes with N's last recovery id.
        let out = try await m.recoveryOpen(pin: pin, password: password)
        #expect(out.ok)
        let secrets = service.recoveryOpens.map(\.unlockSecret).filter { !$0.isEmpty }
        #expect(Set(secrets.map { Data($0) }).count == 1 && service.recoveryOpens.last?.recoveryID == third.recoveryID)
        #expect(service.recoveryHandshakeContexts == [third.recoveryID] && m.record.value.couldNotTell == nil)
        #expect(phone.attester.settled == [1])
    }

    @Test func eachReRegisterOfNUsesANewAppAttestKeyAndAllOfThemStayUntilTheHandshake() async throws {
        defer { phone.close() }
        _ = try await secondEnded(.neverProcessed)
        var nKeys = Array(zip(phone.attester.attestationIdentities, phone.attester.attested).filter { $0.0 == 1 }.map(\.1))
        for _ in 0..<2 {
            // N's recovery ends again, and a further one registers N again.
            #expect(try await m.registerRecovery(try scanned(try secondRecovery())) == .registered(emailHint: service.emailHint))
            nKeys.append(try #require(phone.attester.attested.last))
            #expect(phone.attester.attestationIdentities.last == 1)
            service.cancelRecoveryAtApi()
            #expect(try await twoReads() == .unlockOrNewCode)
        }
        #expect(nKeys.count == 3 && Set(nKeys).count == 3)
        // E's key and N's are never forgotten meanwhile (forgotten once: the parked keys of a new N, before its first register).
        #expect(phone.attester.forgotten == [1] && phone.attester.settled.isEmpty && phone.attester.resets == 0)
        #expect(m.record.value.couldNotTell?.identities.count == 2)
    }

    @Test func aTypedFurtherCodeRegistersNAgainToo() async throws {
        defer { phone.close() }
        _ = try await secondEnded(.neverProcessed)
        let claims = service.recoveryClaims.count
        let third = try secondRecovery()
        #expect(try await m.registerTypedRecovery(try typed(third)) == .registered(emailHint: service.emailHint))
        #expect(service.recoveryClaims.count == claims + 1 && service.recoveryClaims.last?.kind == "locator")
        #expect(m.record.value.couldNotTell?.identities.count == 2 && device?.recoveryID == third.recoveryID)
    }

    @Test func noCodeIsRegisteredBeforeTheReadsAllowIt() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // N's open got no answer and its recovery still shows `registered`: a further code is refused, nothing claimed.
        let claims = service.recoveryClaims.count
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(try secondRecovery())) }
        #expect(f != nil && service.recoveryClaims.count == claims)
    }

    @Test func aDayOfRefusalsAfterBothRecoveriesEndedShowsNoTextAndANewCodeStillWorks() async throws {
        defer { phone.close() }
        _ = try await secondEnded(.neverProcessed)
        // The network not answering is no refusal.
        service.unlockAnswers(.offline, .offline)
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(m.record.value.couldNotTell?.refusalsSinceMs == nil)
        // Both unlocks are refused (the recoveries ended), for more than a day: no contact text; the unlock and a new code stay.
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        later(86_500)
        #expect(try await m.couldNotTellStage() == .unlockOrNewCode)
        try await phone.restart()
        #expect(try await m.couldNotTellStage() == .unlockOrNewCode)
        // A key in use is the other case: its text is `contact`.
        var ct = try #require(m.record.value.couldNotTell)
        (ct.bothEnded, ct.ended, ct.refusalsSinceMs, ct.refusalsForMs) = (false, false, 0, 1)
        try m.persistRecord(m.record.generation) { $0.couldNotTell = ct }
        #expect(try await m.couldNotTellStage() == .contact)
    }

    @Test func theUnlockStillTriesBothIdentitiesNewestFirstAfterBothRecoveriesEnded() async throws {
        defer { phone.close() }
        service.nextOpenStopsAfterStep2()
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.statusUnauthorized = true
        #expect(try await twoReads() == .unlockOrNewCode)
        service.statusUnauthorized = false
        #expect(m.record.value.couldNotTell?.bothEnded == true)
        // The vault took the first identity: the second's unlock is not its key, the first's is.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(phone.attester.assertionIdentities.suffix(2) == [1, 0])
        #expect(service.recoveryHandshakeContexts == [first.recoveryID] && m.record.value.couldNotTell == nil)
        #expect(phone.attester.settled == [0])
    }

    @Test func aRecoveryThatShowsRegisteredAgainIsOpenedAgainOnlyOnThePairOfReads() async throws {
        defer { phone.close() }
        let ids = try await secondEnded(.neverProcessed)
        // The member API takes N's recovery again; the earlier identity is the one in use.
        service.uncancelRecoveryAtApi()
        try await m.selectIdentity(.first)
        // The first read is no decision: the stage stays the unlock and a new code (not a wait).
        #expect(try await m.checkCouldNotTell() == .unlockOrNewCode)
        #expect(m.record.value.couldNotTell?.bothEnded == true && m.record.value.couldNotTellRead?.registered == true)
        let (wall, up) = (phone.clockAhead, phone.uptimeAhead)
        later(301)
        #expect(try await m.checkCouldNotTell() == .none)
        (phone.clockAhead, phone.uptimeAhead) = (wall, up)
        let ct = try #require(m.record.value.couldNotTell)
        #expect(!ct.bothEnded && !ct.unlock && !ct.ended && m.record.value.activeIdentity == .second)
        // N opens again, and pairs with the recovery it registered for last.
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        #expect(service.recoveryHandshakeContexts == [ids.second.recoveryID] && m.record.value.couldNotTell == nil)
    }

    @Test func readsThatDecideNothingAfterBothRecoveriesEndedLeaveTheUnlockAndANewCode() async throws {
        defer { phone.close() }
        _ = try await secondEnded(.neverProcessed)
        // Reads of every kind, at once and a minute apart: never a wait, so the code steps stay offered.
        for read in 0..<4 {
            if read == 2 { service.recoveryStatusShows("available") }
            later(60)
            #expect(try await m.checkCouldNotTell() == .unlockOrNewCode)
        }
        try await phone.restart()
        #expect(try await m.checkCouldNotTell() == .unlockOrNewCode)
        #expect(try await m.registerRecovery(try scanned(try secondRecovery())) == .registered(emailHint: service.emailHint))
    }

    // MARK: - The App Attest key each registration of N asserts with

    @Test func aRegisterOfNAgainWhoseAnswerWasLostOpensWithItsOwnNewKey() async throws {
        defer { phone.close() }
        phone.attester.modelKeys()
        _ = try await secondEnded(.neverProcessed)
        let before = Set(phone.attester.attestedKeyIDs)
        // N is registered again; the register is taken and applied, and the poll of its slot is answered `401`: nothing confirms
        // its key, and N keeps the registration as unknown.
        let third = try secondRecovery()
        service.recoveryRegisterAnswers(.slotUnauthorized)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(third)) }
        let k3 = try #require(phone.attester.attestedKeyIDs.last)
        #expect(!before.contains(k3) && device?.recoveryID == third.recoveryID)
        // The open of that recovery asserts with the key that registration bound, not N's earlier one.
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(phone.attester.assertedKeys.last == k3)
    }

    /// N registered again with the vault's binding on the first copy's key A, while the phone holds a later key B of the same
    /// recovery that nothing confirmed or discarded, and asserts with B: the first copy is applied but its slot says `expired`; the
    /// flow seals again with B, the member API takes it and its answer is lost; the next try (key C) is answered `used`, which
    /// discards C, and the status with K confirms the registration.
    func registeredWithTwoKeys() async throws -> TwoKeys {
        phone.attester.modelKeys()
        service.checkAttestationKeys()
        _ = try await secondEnded(.neverProcessed)
        let third = try secondRecovery()
        let before = phone.attester.attestedKeyIDs.count
        service.recoveryRegisterAnswers(.slotExpiredAfterRegistering, .answerLostAfterRegistering)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(third)) }
        #expect(try await m.registerRecovery(try scanned(third)) == .registered(emailHint: service.emailHint))
        let keys = Array(phone.attester.attestedKeyIDs.dropFirst(before))
        #expect(keys.count == 3)
        return TwoKeys(code: third, a: keys[0], b: keys[1])
    }

    struct TwoKeys {
        let code: FakeVaultService.RecoveryCodeMade
        let a: String
        let b: String
    }

    @Test func anOpenRefusedForItsKeyTriesTheOtherKeyOfThatRecoveryAndCountsNoAttempt() async throws {
        defer { phone.close() }
        let two = try await registeredWithTwoKeys()
        let (a, b) = (two.a, two.b)
        // The open with B is refused `attestation` (nothing counted); the open with A, the registration's, succeeds.
        let asserted = phone.attester.assertedKeys.count
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        #expect(Array(phone.attester.assertedKeys.dropFirst(asserted).prefix(2)) == [b, a])
        #expect(service.recoveryAttemptsUsed == 1)
    }

    @Test func aRepeatWhosePostWasNeverTakenDiscardsItsKeyAndTheOpenUsesTheFirst() async throws {
        defer { phone.close() }
        phone.attester.modelKeys()
        service.checkAttestationKeys()
        _ = try await secondEnded(.neverProcessed)
        let third = try secondRecovery()
        // Taken and applied (key A), the answer lost; the repeat (key B) is refused by the member API before the vault: B is discarded.
        let before = phone.attester.attestedKeyIDs.count
        service.recoveryRegisterAnswers(.answerLostAfterRegistering, .apiNotAvailable)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(third)) }
        #expect(try await m.registerRecovery(try scanned(third)) == .registered(emailHint: service.emailHint))
        let keys = Array(phone.attester.attestedKeyIDs.dropFirst(before))
        #expect(keys.count == 2 && phone.attester.discarded.count >= 1)
        let asserted = phone.attester.assertedKeys.count
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        #expect(phone.attester.assertedKeys.dropFirst(asserted).first == keys[0])
    }

    @Test func theLostOkUnlockOfNAssertsWithTheKeyTheVaultBound() async throws {
        defer { phone.close() }
        let two = try await registeredWithTwoKeys()
        let (third, a) = (two.code, two.a)
        // The open with B is refused for its key; the one with A completes at the vault, and its answer is lost.
        service.recoveryOpenAnswers(.vault, .answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // Two reads of `200`: the lost-ok unlock with N asserts with the bound key A (the vault refuses any other), and the
        // recovery finishes.
        #expect(try await twoReads() == .finishWithPin)
        let asserted = phone.attester.assertedKeys.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(phone.attester.assertedKeys.dropFirst(asserted).last == a)
        #expect(service.recoveryHandshakeContexts.last == third.recoveryID && m.record.value.couldNotTell == nil)
    }

    // MARK: - The contact text

    @Test(arguments: ["exhausted", "closed", "not_armed"])
    func aFreshOpenOfNAnsweredSoThatRecoveryIsRuledOutIsTheContactTextAndNotTerminal(_ code: String) async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.recoveryOpenAnswers(.refused(code))
        let out = try await m.recoveryOpen(pin: pin, password: password)
        #expect(out.code == code && out.contactCouldNotRecover)
        // Not terminal: everything is kept, and when the reads allow it a new code registers N again.
        #expect(m.record.value.couldNotTell?.identities == [.first, .second])
        try expectKept(k, secondToo: true)
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .unlockOrNewCode)
        let third = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(third)) == .registered(emailHint: service.emailHint))
        #expect(device?.recoveryID == third.recoveryID && m.record.value.couldNotTell?.identities.count == 2)
    }

    @Test func theContactTextIsNeverForOtherAnswersOrForTheEarlierIdentityOrAKeyInUse() async throws {
        defer { phone.close() }
        // E alone, a fresh open answered `exhausted`: not the text (N is not there).
        _ = try await registered()
        service.recoveryOpenAnswers(.refused("exhausted"))
        #expect(try await m.recoveryOpen(pin: pin, password: password).contactCouldNotRecover == false)
        // N there: `wrong`, `busy`, `no_recovery` are not it.
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .newCode)
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.recoveryOpenAnswers(.refused("busy"), .refused("no_recovery"))
        #expect(try await m.recoveryOpen(pin: pin, password: password).contactCouldNotRecover == false)
        #expect(try await m.recoveryOpen(pin: pin, password: password).contactCouldNotRecover == false)
        #expect(m.couldNotRecover("exhausted"))
        // A key in use (K is the vault's): never this text.
        try m.persistRecord(m.record.generation) { $0.couldNotTell?.unlock = true }
        #expect(!m.couldNotRecover("exhausted"))
    }

    // MARK: - An ok to finish

    @Test func anIdentityWithAnOkToFinishIsNeverRegisteredAgainAndNoDecisionIsReadWhileItWaits() async throws {
        defer { phone.close() }
        try await endedForGood()
        let second = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(second))
        service.loseAnswers(["credential.get"])
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // The other identity is the one in use; the second still holds the bundle.
        try await m.selectIdentity(.first)
        #expect(try await m.couldNotTellStage() == .finishWithPin)
        service.cancelRecoveryAtApi()
        let reads = service.statusReads
        let (wall, up) = (phone.clockAhead, phone.uptimeAhead)
        later(301)
        _ = try await m.checkCouldNotTell()
        _ = try await m.checkCouldNotTell()
        (phone.clockAhead, phone.uptimeAhead) = (wall, up)
        #expect(service.statusReads == reads && m.record.value.couldNotTellRead == nil)
        // A code is refused before it is claimed; the PIN finishes the open.
        let claims = service.recoveryClaims.count
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(try secondRecovery())) }
        #expect(f != nil && service.recoveryClaims.count == claims)
        service.loseAnswers([])
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .second)
    }

    // MARK: - A code of another vault

    @Test func aTypedCodeOfAnotherVaultIsRefusedAsSoonAsTheClaimNamesItsVault() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryClaimAnswers(.otherVault)
        let registers = service.recoveryRegisters.count
        let r = try await m.registerTypedRecovery(try typed(made))
        #expect(r == .refused(code: VaultManager.codeOtherVault, recoveryID: made.recoveryID))
        #expect(service.recoveryRegisters.count == registers)
        #expect(m.record.value.couldNotTell?.identities == [.first] && m.record.value.couldNotTell?.ended == true)
        try expectKept(k)
        #expect(try await m.couldNotTellStage() == .newCode)
        // The same with N there: nothing registered, E, N and K stay.
        _ = try await m.registerRecovery(try scanned(made))
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .unlockOrNewCode)
        service.recoveryClaimAnswers(.otherVault)
        let later = try secondRecovery()
        let again = try await m.registerTypedRecovery(try typed(later))
        #expect(again == .refused(code: VaultManager.codeOtherVault, recoveryID: later.recoveryID))
        #expect(service.recoveryRegisters.count == registers + 1)
        try expectKept(k, secondToo: true)
    }

    // MARK: - A mark from a build before the history

    @Test func aDeviceSecretAnswerNeverClearsTheMarkOfABuildBeforeTheHistory() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        _ = try await registered()
        try m.persistRecord(m.record.generation) { $0.recoveryOpenUnanswered = true }
        service.registeredPhoneHoldsUnlockKey()
        service.unlockAnswers(.sealed("device_secret"))
        _ = try await m.resumeLostOk(pin: pin)
        #expect(!m.record.value.recoveryOpenUnanswered && device?.recoveryOpens.map(\.id) == ["legacy"])
        #expect(await vaultFailure { try await m.abandonRecovery() } != nil)
        #expect(try phone.appKeys.getOrCreate().spki() == k)
    }

    @Test func anOpenOfALaterIdentityIsJudgedAgainstEveryOpenOfThePhone() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        let device = try await m.openSession().device
        // Its own history is empty, the first identity's open is unanswered: the phone has one.
        #expect(device.recoveryOpens.isEmpty && m.phoneHasUnansweredOpen(device))
    }
}
