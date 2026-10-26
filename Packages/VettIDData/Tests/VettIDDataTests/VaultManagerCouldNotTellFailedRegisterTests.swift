import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A failed register of N (IOS-PLAN 0.1.35 §4.9 "A failed register"): only a first attempt for a code that failed before reaching
/// the vault is not registered and is retried with the same N, K and code; a repeat refused `409 recovery_not_available` or `used`
/// is maybe registered and the status signed with K decides; a `401` drops only an N that never registered; any other failure keeps
/// N as unknown (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    @Test(arguments: [
        FakeVaultService.RecoveryRegisterAnswer.apiRefused(503), .apiRefused(429), .apiNotAvailable, .offline,
    ])
    func aFirstAttemptThatFailedBeforeTheVaultIsNotRegisteredAndIsRetriedWithTheSameNAndK(
        _ answer: FakeVaultService.RecoveryRegisterAnswer
    ) async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryRegisterAnswers(answer)
        _ = try? await m.registerRecovery(try scanned(made))
        // N is made and kept, but not registered; the code step stays.
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.new == .second && ct.registerTried == made.recoveryID && ct.ended)
        #expect(try await m.openSession().device.recovering == false && m.record.value.activeIdentity == .second)
        #expect(try await m.couldNotTellStage() == .newCode)
        try expectKept(k, secondToo: true)
        let earlier = try #require(service.recoveryRegisters.first)
        // The retry: the same N (made once) and K, the same code; the first was not recorded, so it registers.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        let seen = try #require(service.recoveryRegisters.last)
        #expect(seen.ik != earlier.ik && seen.apiKey == k && seen.recoveryID == made.recoveryID)
        #expect(m.record.value.couldNotTell?.identities == [.first, .second] && phone.attester.forgotten == [1])
    }

    @Test func aRepeatRefusedNotAvailableIsMaybeRegisteredAndTheStatusWithKSaysRegistered() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // The first copy is recorded and applied, but its answer is lost: N may have registered.
        service.recoveryRegisterAnswers(.answerLostAfterRegistering, .apiNotAvailable)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        // The repeat is refused by the member API because the first was recorded: the status with K shows `registered`.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(device?.recoveryID == made.recoveryID && m.record.value.couldNotTell?.ended == false)
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
    }

    @Test func aRepeatAnsweredUsedIsHarmlessAndKeepsN() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryRegisterAnswers(.answerLostAfterRegistering, .refused("used"))
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(device?.recoveryID == made.recoveryID)
    }

    @Test func aRepeatThatTheStatusDoesNotShowRegisteredKeepsNAsUnknown() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryRegisterAnswers(.slotUnauthorized, .refused("used"))
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        // The status with K is not `registered` (the first copy was not applied): not confirmed, N keeps the registration.
        service.recoveryStatusShows("available")
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: "retry"))
        #expect(device?.recovering == true && device?.recoveryID == made.recoveryID)
        try expectKept(k, secondToo: true)
    }

    @Test func aDefiniteRefusalOfARegisterAgainPutsNsEarlierRegistrationAndHistoryBack() async throws {
        defer { phone.close() }
        let ids = try await secondEnded(.neverProcessed)
        let history = try #require(device?.recoveryOpens)
        let third = try secondRecovery()
        service.recoveryRegisterAnswers(.refused("bad_code"))
        #expect(try await m.registerRecovery(try scanned(third)) == .refused(code: "bad_code"))
        // N is registered for its earlier recovery again, with the history of its opens: it pairs with that one.
        #expect(device?.recoveryID == ids.second.recoveryID && device?.recoveryOpens == history && history.count == 1)
        #expect(try await m.couldNotTellStage() == .unlockOrNewCode)
        // A failure before the vault does the same.
        service.recoveryRegisterAnswers(.offline)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(try secondRecovery())) }
        #expect(device?.recoveryID == ids.second.recoveryID && device?.recoveryOpens == history)
    }

    @Test func aUnauthorizedRegisterOfAReRegisteredNDropsNothing() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        let ids = try await secondEnded(.neverProcessed)
        service.recoveryRegisterAnswers(.unauthorized, .unauthorized)
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(try secondRecovery())) }
        #expect(f?.kind == .unauthorized)
        // N may be the identity the vault adopted: its keys, its registration and its history stay, and it still counts.
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.identities == [.first, .second] && device?.recoveryID == ids.second.recoveryID)
        try expectKept(k, secondToo: true)
        #expect(phone.attester.forgotten == [1])
    }

    @Test func aNetworkFailureAfterTheMemberApiTookTheRegisterKeepsNAsUnknown() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // Taken (`202`) and applied; the poll of the slot gets no answer: the vault may have registered N.
        service.recoveryRegisterAnswers(.answerLostAfterRegistering, .apiNotAvailable)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(device?.recovering == true && device?.recoveryID == made.recoveryID)
        // The repeat is refused because the first was recorded; the status with K confirms it.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
    }

    @Test func aRepostOfTheSameCodeInTheSameFlowIsARepeat() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // The first copy is applied but its slot says `expired`; the flow seals and posts it again, and the member API refuses the
        // repeat: maybe registered, and the status with K says registered.
        service.recoveryRegisterAnswers(.slotExpiredAfterRegistering, .apiNotAvailable)
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(device?.recoveryID == made.recoveryID && m.record.value.couldNotTell?.ended == false)
    }

    @Test func anyOtherFailureKeepsNAsUnknown() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // The register was queued, and the poll of its slot is answered `401`: it may have registered.
        service.recoveryRegisterAnswers(.slotUnauthorized)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(device?.recovering == true && device?.recoveryID == made.recoveryID)
        #expect(m.record.value.couldNotTell?.identities == [.first, .second])
    }
}
