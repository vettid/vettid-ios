import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// Two identities at most (owner decision of 2026-10-25): when the second identity's recovery ends too, the phone keeps both and
/// goes on with the unlock; a code of another vault drives nothing (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    /// The second identity registers a new code, optionally opens, and its recovery ends too; two reads said so.
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
        #expect(try await twoReads() == .finishWithPin)
        return (first, second)
    }

    typealias Codes = (first: FakeVaultService.RecoveryCodeMade, second: FakeVaultService.RecoveryCodeMade)

    func expectBothKept(_ k: [UInt8], _ ids: Codes) async throws {
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.couldNotFinish && ct.unlock && !ct.unlockByReads && !ct.ended && ct.identities == [.first, .second])
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

    @Test func noThirdIdentityAndNoSecondRegistrationAfterThat() async throws {
        defer { phone.close() }
        _ = try await secondEnded(.neverProcessed)
        let (claims, registers) = (service.recoveryClaims.count, service.recoveryRegisters.count)
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(try secondRecovery())) }
        let t = await vaultFailure { _ = try await m.registerTypedRecovery(try typed(try secondRecovery())) }
        #expect(f?.code == VaultManager.codeRecoveryOpenSent && t?.code == VaultManager.codeRecoveryOpenSent)
        #expect(service.recoveryClaims.count == claims && service.recoveryRegisters.count == registers)
        #expect(m.record.value.couldNotTell?.identities.count == 2 && IdentitySet.limit == 2)
        // The stage stays the unlock, however often the status is read.
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .finishWithPin)
    }

    @Test func aDayOfRefusalsShowsTheOtherTextNotTheOneOfAVaultThatTookThePhone() async throws {
        defer { phone.close() }
        _ = try await secondEnded(.neverProcessed)
        // The network not answering is no refusal.
        service.unlockAnswers(.offline, .offline)
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(m.record.value.couldNotTell?.refusalsSinceMs == nil)
        // Both unlocks are refused (the recoveries ended): the run begins, and a day later the text is the third one.
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(m.record.value.couldNotTell?.refusalsSinceMs != nil)
        #expect(try await m.couldNotTellStage() == .finishWithPin)
        later(86_500)
        #expect(try await m.couldNotTellStage() == .couldNotFinish)
        try await phone.restart()
        #expect(try await m.couldNotTellStage() == .couldNotFinish)
        // A key in use is the other case: its text stays `contact`.
        var ct = try #require(m.record.value.couldNotTell)
        ct.couldNotFinish = false
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
        #expect(try await twoReads() == .finishWithPin)
        service.statusUnauthorized = false
        #expect(m.record.value.couldNotTell?.couldNotFinish == true)
        // The vault took the first identity: the second's unlock is not its key, the first's is.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(phone.attester.assertionIdentities.suffix(2) == [1, 0])
        #expect(service.recoveryHandshakeContexts == [first.recoveryID] && m.record.value.couldNotTell == nil)
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

    @Test func aStatusOfAnotherVaultDrivesNothing() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.statusShowsVault("someone-elses-vault")
        let reads = service.statusReads
        _ = try await m.checkCouldNotTell()
        _ = try await m.checkCouldNotTell()
        #expect(service.statusReads > reads && m.record.value.couldNotTell == nil && m.record.value.couldNotTellRead == nil)
    }

    @Test func aTypedCodeOfAnotherVaultIsRefusedAsSoonAsItsVaultIsKnown() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        let made = try secondRecovery()
        service.recoveryClaimAnswers(.otherVault)
        let registers = service.recoveryRegisters.count
        let f = await vaultFailure { _ = try await m.registerTypedRecovery(try typed(made)) }
        #expect(f?.code == VaultManager.codeRecoveryOpenUnknown && service.recoveryRegisters.count == registers)
        #expect(m.record.value.couldNotTell?.identities == [.first] && m.record.value.couldNotTell?.ended == true)
        try expectKept(k)
        // The status of that vault, read meanwhile, drives nothing.
        service.statusShowsVault("someone-elses-vault")
        service.cancelRecoveryAtApi()
        #expect(try await m.couldNotTellStage() == .newCode)
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
