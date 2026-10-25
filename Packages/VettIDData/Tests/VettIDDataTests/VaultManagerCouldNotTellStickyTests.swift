import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The sticky mark of an unanswered open (IOS-PLAN 0.1.34 §4.10), the trial's wrong PIN, and the reads that go on (continues
/// ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    @Test func aRefusalAfterAnUnansweredOpenNeverClearsTheStickyMark() async throws {
        defer { phone.close() }
        _ = try await registered()
        // A readable `wrong` for a first open proves no step 1 was stored: nothing sticky.
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        #expect(device?.recoveryOpenEverUnanswered == false)
        // An open that got no answer is sticky; a later readable `wrong` clears the hint, not the mark.
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: "222222", password: password) }
        #expect(device?.recoveryOpenEverUnanswered == true)
        #expect(try await m.recoveryOpen(pin: "333333", password: password).code == "wrong")
        #expect(m.record.value.recoveryOpenUnanswered && device?.recoveryOpenEverUnanswered == true)
        // So a start over is still refused (the key may be the vault's), and it survives a restart.
        #expect(await vaultFailure { try await m.abandonRecovery() } != nil)
        try await phone.restart()
        #expect(try await m.openSession().device.recoveryOpenEverUnanswered)
    }

    @Test func anUnansweredOpenThenAReadableWrongThenTheRecoveryEndingIsANewIdentityNotAReRegister() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let second = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(second))
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        #expect(m.record.value.recoveryOpenUnanswered)
        service.cancelRecoveryAtApi()
        // Entered by the sticky mark. The second identity may hold an invitation under its `recovery_id`: it is not dropped, and
        // the new code makes a third identity (no dead end).
        #expect(try await twoReads() == .newCode)
        let third = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(third)) == .registered(emailHint: service.emailHint))
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.identities == [.first, .second, IdentitySet(rawValue: 2)] && m.record.value.activeIdentity.rawValue == 2)
        #expect(service.recoveryRegisters.count == 3 && service.recoveryRegisters[2].apiKey == k)
        #expect(service.recoveryClaims.last?.appKey == k)
        let (a, b, c) = (service.recoveryRegisters[0], service.recoveryRegisters[1], service.recoveryRegisters[2])
        #expect(Set([a.ik, b.ik, c.ik]).count == 3 && Set([a.kem, b.kem, c.kem]).count == 3)
        // Every identity keeps its own `recovery_id`.
        try await m.selectIdentity(.second)
        #expect(try await m.openSession().device.recoveryID == second.recoveryID)
        try await m.selectIdentity(IdentitySet(rawValue: 2))
        #expect(try await m.openSession().device.recoveryID == third.recoveryID)
        try expectKept(k, secondToo: true)
        for slot in KeySlot.slots(of: IdentitySet(rawValue: 2)) { #expect(try phone.wrapped.get(slot) != nil) }
    }

    @Test func theHandshakeFallsBackThroughTheOlderIdentitiesNewestFirst() async throws {
        defer { phone.close() }
        phone.pairingWait = 3
        try await phone.restart()
        // The first identity's open stopped after step 2 (its invitation, under R1, stands); the second's was never processed.
        service.nextOpenStopsAfterStep2()
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let third = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(third)) == .registered(emailHint: service.emailHint))
        #expect(m.record.value.couldNotTell?.identities.count == 3)
        // The third identity's open answers `ok` (the vault repeats the stopped recovery) but its handshake gets nothing; the
        // second identity's unlock is not the vault's, the first's is.
        let out = try await m.recoveryOpen(pin: pin, password: password)
        #expect(out.ok)
        #expect(service.recoveryHandshakeContexts == [third.recoveryID, first.recoveryID])
        #expect(phone.attester.assertionIdentities.suffix(2) == [1, 0])
        #expect(m.record.value.activeIdentity == .first && m.record.value.couldNotTell == nil)
        for set in IdentitySet.all.dropFirst() { for slot in KeySlot.slots(of: set) { #expect(try phone.wrapped.get(slot) == nil) } }
        try await m.finishRecoveryOpen()
    }

    @Test func theNewIdentityKeepsGoingWhenNoOlderIdentityIsTheVaultsAndItsHandshakeWasLostOnce() async throws {
        defer { phone.close() }
        phone.pairingWait = 3
        try await phone.restart()
        try await endedForGood()
        let second = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(second))
        // The vault takes the new identity, its first handshake is lost on the way, and the earlier identity's unlock is refused:
        // the new identity's own unlock and handshake then succeed in the same call.
        service.dropNextRecoveryHandshakes(1)
        let out = try await m.recoveryOpen(pin: pin, password: password)
        #expect(out.ok)
        #expect(service.recoveryHandshakeContexts == [second.recoveryID, second.recoveryID])
        #expect(m.record.value.activeIdentity == .second && m.record.value.couldNotTell == nil && device?.deviceID != nil)
        try await m.finishRecoveryOpen()
        #expect(m.phase == .unlocked)
    }

    @Test func aWrongPinInTheEarlierIdentitysFallbackKeepsTheIdentityThatHasTheOk() async throws {
        defer { phone.close() }
        phone.pairingWait = 3
        try await phone.restart()
        service.nextOpenStopsAfterStep2()
        try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        // The new open answers `ok`, its handshake is not answered, and the earlier identity's unlock is answered `bad_pin`.
        service.unlockAnswers(.sealed("bad_pin"))
        let out = try await m.recoveryOpen(pin: pin, password: password)
        #expect(out.code == "bad_pin" && out.opened)
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.returnTo == nil && m.record.value.activeIdentity == .second)
        // After a restart the identity with the `ok` is still the one that finishes.
        try await phone.restart()
        #expect(try await m.recoveryOpened())
        #expect(m.record.value.activeIdentity == .second)
    }

    @Test func aTrialThatWasNotSettledAtTheStartIsSettledWhenTheStageIsAsked() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.loseAnswers(["credential.get"])
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        try m.persistRecord(m.record.generation) {
            $0.couldNotTell?.returnTo = .second
            $0.activeIdentity = .first
        }
        _ = try await m.openSession()
        #expect(try await m.couldNotTellStage() == .none)
        #expect(m.record.value.activeIdentity == .second && m.record.value.couldNotTell?.returnTo == nil)
    }

    @Test func theStatusIsReadAgainEvenAfterTheOpenMarkWasClearedByADeviceSecretAnswer() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.recoveryStatusShows("available")
        #expect(try await twoReads() == .finishWithPin)
        service.registeredPhoneHoldsUnlockKey()
        service.unlockAnswers(.sealed("device_secret"))
        _ = try await m.resumeLostOk(pin: pin)
        #expect(!m.record.value.recoveryOpenUnanswered)
        service.cancelRecoveryAtApi()
        let reads = service.statusReads
        #expect(try await twoReads() == .newCode)
        #expect(service.statusReads > reads)
    }
}
