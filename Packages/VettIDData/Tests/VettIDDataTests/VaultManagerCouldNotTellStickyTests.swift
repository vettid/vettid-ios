import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The sticky mark of an unanswered open (IOS-PLAN 0.1.35 §4.9, §4.10), the trial's wrong PIN, and the reads that go on (continues
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

    @Test(arguments: ["exhausted", "not_armed", "wrong_again", "busy", "closed"])
    func aCodeThatProvesNoStepOneSettlesOnlyTheOpenItAnswers(_ code: String) async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.neverProcessed, .refused(code))
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(try await m.recoveryOpen(pin: pin, password: password).code == code)
        // IOS-PLAN 0.1.35 §4.9: the second open is settled; the first stays unanswered, and so does the phone.
        #expect(device?.recoveryOpens.map(\.state) == [.unanswered, .refused(code)])
        #expect(device?.recoveryOpenEverUnanswered == true && VaultManager.refusalProves(code, earlierUnanswered: true))
        #expect(await vaultFailure { try await m.abandonRecovery() } != nil)
    }

    /// Registered with the vault's binding on the first copy's key A while the key in use is a later one, B (the first copy's slot
    /// said `expired`, the second copy was taken and its answer lost, a third was answered `used`).
    func registeredOnTheFirstCopysKey() async throws {
        phone.attester.modelKeys()
        service.checkAttestationKeys()
        let made = try armed()
        service.recoveryRegisterAnswers(.slotExpiredAfterRegistering, .answerLostAfterRegistering)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        _ = try? await m.registerRecovery(try scanned(made))
        #expect(try await m.openSession().device.recovering)
    }

    @Test func anOpenRefusedForItsKeyIsSettledAndAnEndedRecoveryIsNoPhoneThatCouldNotTell() async throws {
        defer { phone.close() }
        try await registeredOnTheFirstCopysKey()
        // The open with B is refused `attestation` (no attempt used), the one with A is answered `wrong`: both are settled.
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        #expect(device?.recoveryOpens.map(\.state) == [.refused("attestation"), .refused("wrong")])
        #expect(device?.recoveryOpenEverUnanswered == false && !m.record.value.recoveryOpenUnanswered)
        // The recovery ends: an ordinary ended recovery, not the rule.
        service.cancelRecoveryAtApi()
        let reads = service.statusReads
        #expect(try await m.checkCouldNotTell() == .none)
        #expect(m.record.value.couldNotTell == nil && service.statusReads == reads)
    }

    @Test func anEarlierOpenThatGotNoAnswerStillKeepsTheRuleAfterAnOpenRefusedForItsKey() async throws {
        defer { phone.close() }
        try await registeredOnTheFirstCopysKey()
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // B is refused for its key (that open alone is settled), A is answered `wrong` (no proof after an unanswered open).
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        #expect(device?.recoveryOpens.map(\.state) == [.unanswered, .refused("attestation"), .unanswered])
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .newCode)
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
        // (The second identity holds an `ok` still to be finished: the PIN finishes it.)
        #expect(try await m.couldNotTellStage() == .finishWithPin)
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
