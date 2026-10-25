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
        #expect(!m.record.value.recoveryOpenUnanswered && device?.recoveryOpenEverUnanswered == true)
        // So a start over is still refused (the key may be the vault's), and it survives a restart.
        #expect(await vaultFailure { try await m.abandonRecovery() } != nil)
        try await phone.restart()
        #expect(try await m.openSession().device.recoveryOpenEverUnanswered)
    }

    @Test func anUnansweredOpenThenAReadableWrongThenTheRecoveryEndingIsTheUnlockNotAReRegister() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let second = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(second))
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        #expect(!m.record.value.recoveryOpenUnanswered)
        service.cancelRecoveryAtApi()
        // Entered by the sticky mark: the unlock with either identity, no re-register, no `recovery_id` dropped.
        #expect(try await twoReads() == .finishWithPin)
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.unlock && !ct.ended)
        let registers = service.recoveryRegisters.count
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(try secondRecovery())) }
        #expect(f?.code == VaultManager.codeRecoveryOpenSent && service.recoveryRegisters.count == registers)
        #expect(try await m.openSession().device.recoveryID == second.recoveryID)
        try expectKept(k, secondToo: true)
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
        #expect(ct.opened == .second && !ct.trial && m.record.value.activeIdentity == .second)
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
            $0.couldNotTell?.trial = true
            $0.activeIdentity = .first
        }
        _ = try await m.openSession()
        #expect(try await m.couldNotTellStage() == .none)
        #expect(m.record.value.activeIdentity == .second && m.record.value.couldNotTell?.trial == false)
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
