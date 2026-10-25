import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The history of each identity's opens (IOS-PLAN 0.1.34 §4.10: written before the post, sticky, per open), the return marker of
/// the unlock with each identity, the reads of the rule and the setup code (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    // MARK: - The history of the opens

    @Test func anOpenIsWrittenUnansweredBeforeItIsPostedAndAFailedSavePostsNothing() async throws {
        defer { phone.close() }
        _ = try await registered()
        _ = try await m.openSession()
        let posts = service.recoveryOpens.count
        // The data directory cannot be written: the save of the history fails, and the open is not posted.
        let path = phone.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        let f = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        #expect(f != nil && service.recoveryOpens.count == posts)
        #expect(device?.recoveryOpens.isEmpty == true && device?.recoveryOpenEverUnanswered == false)
        // With the directory writable the entry is there, unanswered, as soon as the open went out.
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(device?.recoveryOpens.map(\.state) == [.unanswered] && device?.recoveryOpenEverUnanswered == true)
    }

    @Test func anOpenTheMemberApiTookWhoseResponseWasLostStaysUnansweredAndTheRuleIsReachable() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        _ = try await registered()
        service.recoveryOpenAnswers(.acceptedResponseLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // `onSent` never ran, so the hint is not set; the history is, and a start over is refused.
        #expect(!m.record.value.recoveryOpenUnanswered && device?.recoveryOpenEverUnanswered == true)
        let a = await vaultFailure { try await m.abandonRecovery() }
        #expect(a != nil && device?.recovering == true)
        try await phone.restart()
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .newCode)
        try expectKept(k)
    }

    @Test func aDefiniteNonAcceptanceIsNoUnansweredOpen() async throws {
        defer { phone.close() }
        _ = try await registered()
        // A `4xx` to the POST itself: nothing was taken.
        service.recoveryOpenAnswers(.apiRefused(429))
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(device?.recoveryOpens.map(\.state) == [.refused("not_accepted")] && device?.recoveryOpenEverUnanswered == false)
        // A `5xx` proves nothing.
        service.recoveryOpenAnswers(.apiRefused(503))
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(device?.recoveryOpenEverUnanswered == true)
    }

    @Test func aRefusalAfterAnEarlierUnansweredOpenNeverChangesTheEarlierEntry() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        let first = try #require(device?.recoveryOpens.first?.id)
        // `busy` proves no step 1 for this open only; `wrong` does not even do that.
        service.recoveryOpenAnswers(.refused("busy"), .refused("wrong_again"))
        #expect(try await m.recoveryOpen(pin: pin, password: password).code == "busy")
        #expect(try await m.recoveryOpen(pin: pin, password: password).code == "wrong_again")
        let entries = try #require(device?.recoveryOpens)
        #expect(entries.count == 3 && entries[0].id == first && entries[0].state == .unanswered)
        #expect(entries[1].state == .refused("busy") && entries[2].state == .refused("wrong_again"))
        #expect(device?.recoveryOpenEverUnanswered == true)
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        #expect(device?.recoveryOpens.last?.state == .unanswered && device?.recoveryOpenEverUnanswered == true)
    }

    @Test func everyUnansweredOpenIsReadOnceNotOnlyTheNewest() async throws {
        defer { phone.close() }
        // The first open stopped after step 2 and its answer is lost (K is only the pending key); a second never got processed.
        service.nextOpenStopsAfterStep2()
        _ = try await registered()
        service.recoveryOpenAnswers(.answerLost, .neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let made = try secondRecovery()
        // The older open's slot is readable after all: `ok` decides it, though the newest one's is not.
        service.answerReadable(try #require(service.recoveryOpens.first?.requestID))
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: VaultManager.codeRecoveryOpenSent))
        #expect(m.record.value.couldNotTell?.identities.count == 1 && m.record.value.couldNotTell?.unlock == true)
        #expect(try await m.resumeLostOk(pin: pin).ok)
    }

    // MARK: - The unlock with each identity

    @Test func anErrorDuringTheUnlockWithEachIdentityGoesBackToTheIdentityItStartedWith() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(try await twoReads() == .finishWithPin)
        // The network fails for both unlocks: nothing is a refusal, and the identity in use is the one it was.
        service.unlockAnswers(.offline, .offline)
        let f = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(f != nil && m.record.value.activeIdentity == .second && m.record.value.couldNotTell?.returnTo == nil)
        // A kill with the marker written goes back to it.
        try m.persistRecord(m.record.generation) {
            $0.couldNotTell?.returnTo = .second
            $0.activeIdentity = .first
        }
        try await phone.restart()
        _ = try await m.couldNotTellStage()
        #expect(m.record.value.activeIdentity == .second && m.record.value.couldNotTell?.returnTo == nil)
    }

    // MARK: - The reads

    @Test func aReadOfTheRuleWaitsWhileIdentitiesAreSwitched() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.cancelRecoveryAtApi()
        m.moveFlags.book.ruleSwitching = 1
        let reads = service.statusReads
        #expect(try await m.checkCouldNotTell() == .none && service.statusReads == reads)
        m.moveFlags.book.ruleSwitching = 0
        guard case .waiting = try await m.checkCouldNotTell() else { Issue.record("no read"); return }
        #expect(service.statusReads > reads)
    }

    @Test func aNewIdentityStartsFromTheFloorsTheOneBeforeHasSeen() async throws {
        defer { phone.close() }
        try await endedForGood()
        var floors = AltState()
        floors.stateSeq = 7
        floors.headerSeq = ["abc": 5]
        floors.manifestSerial = 3
        try await m.openSession().device.seedFloors(from: floors)
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        let seen = try await m.openSession().device.altState
        #expect(seen.stateSeq >= 7 && seen.headerSeq["abc"] == 5 && seen.manifestSerial >= 3)
    }

    // MARK: - The setup code and the record

    @Test func aRecordThatCannotBeReadDoesNotChangeWhatStoredSessionAnswered() async throws {
        defer { phone.close() }
        // A fresh phone whose protected data is not available: the device file cannot be read, as before the identity of the record
        // was asked (the record is not required for it).
        phone.protectedData.set(false)
        var threw = false
        do { _ = try await m.storedSession() } catch { threw = true }
        phone.protectedData.set(true)
        #expect(threw)
        // And the setup code's forget is refused only by what the record says, when it can be read.
        #expect(try await m.storedSession() == nil)
    }
}
