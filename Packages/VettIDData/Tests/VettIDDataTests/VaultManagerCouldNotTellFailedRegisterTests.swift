import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A failed register of N (IOS-PLAN 0.1.38 §4.9 "A failed register"), each POST judged on its own: only a first POST for a code with
/// no `202` is not registered and is retried with the same N, K and code; a failure after a `202`, or a repeat refused
/// `409 recovery_not_available` or `used`, is maybe registered and the status signed with K decides; a readable refusal settles its
/// POST; a `401` drops only an N that never registered, was left maybe registered or unknown; any other answer without a `202` keeps
/// N as unknown (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    @Test(arguments: [
        FakeVaultService.RecoveryRegisterAnswer.apiRefused(503), .apiRefused(429), .apiNotAvailable, .offline,
    ])
    func aFirstPostWithNo202IsNotRegisteredAndIsRetriedWithTheSameNAndK(_ answer: FakeVaultService.RecoveryRegisterAnswer) async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryRegisterAnswers(answer)
        _ = try? await m.registerRecovery(try scanned(made))
        // N is made and kept, but not registered; the POST was recorded before it was posted; the code step stays.
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.new == .second && ct.registerTried == made.recoveryID && ct.registerKept == nil && ct.ended)
        #expect(try await m.openSession().device.recovering == false && m.record.value.activeIdentity == .second)
        #expect(try await m.couldNotTellStage() == .newCode)
        try expectKept(k, secondToo: true)
        let earlier = try #require(service.recoveryRegisters.first)
        // The retry (a repeat): the same N (made once) and K, the same code; the first was not recorded, so it registers.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        let seen = try #require(service.recoveryRegisters.last)
        #expect(seen.ik != earlier.ik && seen.apiKey == k && seen.recoveryID == made.recoveryID)
        #expect(m.record.value.couldNotTell?.identities == [.first, .second] && phone.attester.forgotten == [1])
    }

    @Test func aSecondPostAfterOneWithNo202IsARepeatAndTheStatusDecides() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // `503` to the first POST (not registered), `409 recovery_not_available` to the second: a repeat, so maybe registered, and
        // the status with K (no registration applied) does not confirm it.
        service.recoveryRegisterAnswers(.apiRefused(503), .apiNotAvailable)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        let reads = service.statusReads
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: "retry"))
        #expect(service.statusReads > reads && m.record.value.couldNotTell?.registerKept == made.recoveryID)
        // Retries are always allowed: the next one registers.
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
    }

    @Test(arguments: [FakeVaultService.RecoveryRegisterAnswer.answerLostAfterRegistering, .slotUnauthorized])
    func aFailureAfterA202IsMaybeRegisteredAndConfirmedByTheStatus(_ answer: FakeVaultService.RecoveryRegisterAnswer) async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // Taken (`202`) and applied; the poll fails: the status with K shows `registered`.
        service.recoveryRegisterAnswers(answer)
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(device?.recoveryID == made.recoveryID && m.record.value.couldNotTell?.ended == false)
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
    }

    @Test func aFailureAfterA202ThatTheStatusDoesNotConfirmKeepsN() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryRegisterAnswers(.answerLostAfterRegistering, .apiNotAvailable)
        service.recoveryStatusShows("available")
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(device?.recovering == true && device?.recoveryID == made.recoveryID)
        #expect(m.record.value.couldNotTell?.registerKept == made.recoveryID)
        try expectKept(k, secondToo: true)
        // The repeat is refused because the first was recorded; the status with K now confirms it.
        service.recoveryStatusShows(nil)
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
    }

    @Test func aRepeatAnsweredUsedIsMaybeRegistered() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // The first copy is applied, its answer lost, and the status does not confirm it yet: N stays maybe registered.
        service.recoveryRegisterAnswers(.answerLostAfterRegistering)
        service.recoveryStatusShows("available")
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        // A repeat the vault answers `used`: maybe registered, and the status with K now confirms it.
        service.recoveryStatusShows(nil)
        service.recoveryRegisterAnswers(.refused("used"))
        #expect(try await m.registerRecovery(try scanned(made)) == .registered(emailHint: service.emailHint))
        #expect(device?.recoveryID == made.recoveryID)
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

    @Test func aReadableRefusalOfARegisterAgainPutsNsEarlierRegistrationAndHistoryBack() async throws {
        defer { phone.close() }
        let ids = try await secondEnded(.neverProcessed)
        let history = try #require(device?.recoveryOpens)
        let third = try secondRecovery()
        service.recoveryRegisterAnswers(.refused("bad_code"))
        #expect(try await m.registerRecovery(try scanned(third)) == .refused(code: "bad_code"))
        // N is registered for its earlier recovery again, with the history of its opens: it pairs with that one.
        #expect(device?.recoveryID == ids.second.recoveryID && device?.recoveryOpens == history && history.count == 1)
        #expect(try await m.couldNotTellStage() == .unlockOrNewCode)
        // A first POST with no answer at all does the same.
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

    /// A first N whose earlier POST for the code got a `202` (in this flow: its slot said `expired`; in an earlier flow: the poll
    /// failed and the status did not confirm it): a `401` or a readable refusal to the next POST keeps N, registered for the code.
    @Test(arguments: [FakeVaultService.RecoveryRegisterAnswer.unauthorized, .refused("bad_code")], [true, false])
    func aUnauthorizedOrARefusalAfterA202KeepsN(_ answer: FakeVaultService.RecoveryRegisterAnswer, sameFlow: Bool) async throws {
        defer { phone.close() }
        try await endedForGood()
        let second = try secondRecovery()
        service.recoveryStatusShows("available")
        if sameFlow {
            service.recoveryRegisterAnswers(.slotExpiredAfterRegistering, answer, answer)
        } else {
            service.recoveryRegisterAnswers(.answerLostAfterRegistering)
            _ = try? await m.registerRecovery(try scanned(second))
            service.recoveryRegisterAnswers(answer, answer)
        }
        _ = try? await m.registerRecovery(try scanned(second))
        let ct = try #require(m.record.value.couldNotTell)
        let n = try await m.openSession()
        #expect(ct.identities == [.first, .second] && n.identity == .second && n.device.recoveryID == second.recoveryID)
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) != nil) }
    }

    @Test func aReadableRefusalToARepostAfterInstanceMovedPutsNsRegistrationBack() async throws {
        defer { phone.close() }
        let ids = try await secondEnded(.neverProcessed)
        // The first POST is answered `instance_moved` (nothing taken), the re-post a readable `bad_code`: a repeat, but nothing left
        // N maybe registered, so N is registered for its earlier recovery again.
        service.recoveryRegisterAnswers(.instanceMoved, .refused("bad_code"))
        #expect(try await m.registerRecovery(try scanned(try secondRecovery())) == .refused(code: "bad_code"))
        #expect(device?.recoveryID == ids.second.recoveryID && m.record.value.couldNotTell?.registerKept == nil)
    }

    @Test func anyOtherAnswerWithoutA202KeepsNAsUnknown() async throws {
        defer { phone.close() }
        try await endedForGood()
        let made = try secondRecovery()
        // `409 recovery_unavailable` is no answer of the list: N may have registered.
        service.recoveryRegisterAnswers(.apiNoBackup)
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: VaultManager.codeNoBackup))
        #expect(device?.recovering == true && device?.recoveryID == made.recoveryID)
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.identities == [.first, .second] && ct.registerKept == made.recoveryID)
    }
}
