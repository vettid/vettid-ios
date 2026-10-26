import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The history of each identity's opens (IOS-PLAN 0.1.38 §4.9, §4.10: written before the post, sticky, per open), the return marker of
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

    @Test func aPostFailureOfAnyKindKeepsTheOpensEntry() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        _ = try await registered()
        // The POST's own `4xx` (IOS-PLAN 0.1.38 §4.9): a re-sent POST can be queued, so the entry stays unanswered.
        service.recoveryOpenAnswers(.apiRefused(429))
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(device?.recoveryOpens.map(\.state) == [.unanswered] && device?.recoveryOpenEverUnanswered == true)
        service.recoveryOpenAnswers(.apiRefused(400), .apiRefused(409), .apiRefused(503))
        for _ in 0..<3 { _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) } }
        #expect(device?.recoveryOpens.map(\.state) == Array(repeating: .unanswered, count: 4))
        // Nothing after the post removes one: a later answer settles its own open only, and a start over is refused.
        service.recoveryOpenAnswers(.refused("busy"))
        #expect(try await m.recoveryOpen(pin: pin, password: password).code == "busy")
        #expect(device?.recoveryOpens.prefix(4).allSatisfy { $0.state == .unanswered } == true)
        #expect(await vaultFailure { try await m.abandonRecovery() } != nil)
        try expectKept(k)
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

/// The bound, the nested switches, the pairing that wins, and the record that cannot be read (continues
/// ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    @Test func aRefusalBeforeTheOpenIsBuiltNeverTouchesAnEarlierOpensEntry() async throws {
        defer { phone.close() }
        _ = try await registered()
        // The first open is answered `503` by the member API: unanswered.
        service.recoveryOpenAnswers(.apiRefused(503))
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        let first = try #require(device?.recoveryOpens.first)
        #expect(first.state == .unanswered)
        // The next open's descriptor fetch is refused with a `4xx` before the request is built: it has no entry, and the first
        // one is unchanged (so a start over is still refused).
        service.enclaveRefusals(429)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(device?.recoveryOpens == [first] && device?.recoveryOpenEverUnanswered == true)
        #expect(await vaultFailure { try await m.abandonRecovery() } != nil)
    }

    @Test func aWrongAnswerOnALaterIdentityIsNotAProofWhileAnEarlierIdentitysOpenIsUnanswered() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        // The first identity's open is unanswered: per phone, `wrong` proves nothing.
        #expect(device?.recoveryOpenEverUnanswered == true)
    }

    @Test func aNestedSwitchPutsTheOuterReturnMarkerBackNotNil() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        // The unlock with each identity is at its first identity; inside it the fallback tries the older identities and finds none.
        try m.persistRecord(m.record.generation) { $0.couldNotTell?.returnTo = .first }
        m.moveFlags.book.trialDepth = 1
        let none = try await m.pairEarlierIdentity(pin: pin)
        m.moveFlags.book.trialDepth = 0
        #expect(none == nil && m.record.value.activeIdentity == .second)
        #expect(m.record.value.couldNotTell?.returnTo == .first)
        // A kill with both markers goes back to the outer one (the loop's), and a read waits while a switch is running.
        m.moveFlags.book.trialDepth = 1
        let reads = service.statusReads
        _ = try await m.checkCouldNotTell()
        #expect(service.statusReads == reads)
        m.moveFlags.book.trialDepth = 0
    }

    @Test func aPairingThatCompletedWinsOverAStaleMarker() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .second)
        // A write that failed after the pairing would have left the rule with a marker that points at an identity that is gone:
        // brought back here by hand, with the keys and files of the winner only.
        try m.persistRecord(m.record.generation) {
            var ct = CouldNotTell(earlier: .first)
            ct.identities = [.first, .second]
            ct.returnTo = .first
            $0.couldNotTell = ct
            $0.activeIdentity = .first
        }
        try await phone.restart()
        _ = try await m.couldNotTellStage()
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .second)
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) != nil) }
        #expect(try phone.appKeys.getOrCreate().spki() == k)
        #expect(try await m.openSession().device.deviceID != nil)
    }

    @Test func aRecordThatCannotBeReadNeverReplacesKWhenAnIdentityOtherThanTheFirstHoldsTheDevice() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        // The winner is the second identity: `vault-device` is gone.
        #expect(!FileManager.default.fileExists(atPath: phone.directory.appendingPathComponent(VaultFiles.device).path))
        phone.close()
        try Data("not a record".utf8).write(to: phone.directory.appendingPathComponent(VaultFiles.account))
        try await phone.restart()
        var threw = false
        do { try await m.forgetSetupCode() } catch { threw = true }
        let kept = try phone.appKeys.getOrCreate().spki()
        #expect(threw && kept == k)
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) != nil) }
    }

    @Test func theFloorsAreWrittenWithTheSwitchToANewIdentity() async throws {
        defer { phone.close() }
        try await endedForGood()
        var floors = AltState()
        floors.stateSeq = 9
        floors.manifestSerial = 4
        try await m.openSession().device.seedFloors(from: floors)
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        #expect(m.record.value.couldNotTell?.floors?.stateSeq == 9 && m.record.value.couldNotTell?.floors?.manifestSerial == 4)
        #expect(try await m.openSession().device.altState.stateSeq >= 9)
    }
}

/// The identity that registers again, the identities that cannot be opened, the rule of a vault that is gone, the stale session,
/// and a state from a build before the history (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    @Test func oneIdentityThatCannotBeOpenedDoesNotStopTheUnlockOfTheOlderOne() async throws {
        defer { phone.close() }
        service.nextOpenStopsAfterStep2()
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        try m.persistRecord(m.record.generation) { $0.couldNotTell?.unlock = true; $0.couldNotTell?.ended = false }
        // The second identity's state cannot be decrypted after a restart; the first one holds the vault's key.
        phone.close()
        try Data("not a state".utf8).write(to: phone.directory.appendingPathComponent(VaultFiles.device(of: .second)))
        try await phone.restart()
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.ok)
        #expect(service.recoveryHandshakeContexts == [first.recoveryID])
    }

    @Test func aGoneVaultClearsTheRuleBeforeAnyKeyIsForgottenAndOnlyARegistrationCarriesIt() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        #expect(m.record.value.couldNotTell != nil)
        // A record of its own carries nothing of the rule unless it is a new recovery's registration.
        try m.resetRecord(LocalAccount())
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .first)
    }

    @Test func theRuleIsClearedInASaveOfItsOwnWhenTheVaultIsGone() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        let a = await vaultFailure { try await m.dropSession(forget: true) }
        #expect(a?.code == VaultManager.codeRecoveryOpenSent && m.record.value.couldNotTell != nil)
        try await m.dropSession(forget: true, vaultGone: true)
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .first)
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) == nil) }
    }

    @Test func aSessionOfAnotherIdentityThanTheRecordsIsDroppedAndTheWinnerIsTheSessionsIdentity() async throws {
        defer { phone.close() }
        try await endedForGood()
        let second = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(second))
        let atSecond = try await m.openSession()
        #expect(atSecond.identity == .second)
        // The record moves to the first identity while the session stays: the next session is the first's.
        try m.persistRecord(m.record.generation) { $0.activeIdentity = .first }
        let atFirst = try await m.openSession()
        #expect(atFirst.identity == .first && atFirst.device.recoveryID != second.recoveryID)
        // The identity that paired is the session's, whatever the record says when the rule is settled.
        try await m.selectIdentity(.second)
        try m.persistRecord(m.record.generation) { $0.activeIdentity = .first }
        m.settleCouldNotTell(winner: .second)
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .second)
        for slot in KeySlot.slots(of: .second) { #expect(try phone.wrapped.get(slot) != nil) }
    }

    @Test func noDecisionIsReadWhileAnOkIsStillToBeFinished() async throws {
        defer { phone.close() }
        try await endedForGood()
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        service.loseAnswers(["credential.get"])
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(try await m.recoveryOpened())
        service.cancelRecoveryAtApi()
        let reads = service.statusReads
        let (wall, up) = (phone.clockAhead, phone.uptimeAhead)
        later(301)
        _ = try await m.checkCouldNotTell()
        _ = try await m.checkCouldNotTell()
        (phone.clockAhead, phone.uptimeAhead) = (wall, up)
        #expect(service.statusReads == reads && m.record.value.couldNotTellRead == nil)
    }

    @Test func anOpenFromABuildBeforeTheHistoryIsKeptAsUnansweredWhateverComesAfter() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        _ = try await registered()
        // The account record says an open went out; the device state has no history of it.
        try m.persistRecord(m.record.generation) { $0.recoveryOpenUnanswered = true }
        #expect(device?.recoveryOpens.isEmpty == true)
        // A later open is answered `wrong` (a proof only when no earlier open is unanswered), and the record's mark goes.
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        #expect(device?.recoveryOpens.first?.id == "legacy" && device?.recoveryOpens.first?.state == .unanswered)
        #expect(device?.recoveryOpenEverUnanswered == true)
        let f = await vaultFailure { try await m.abandonRecovery() }
        #expect(f != nil && device?.recovering == true)
        #expect(try phone.appKeys.getOrCreate().spki() == k)
        // The register of a new code drops the record's mark; the history of the device keeps it.
        try await phone.restart()
        #expect(try await m.openSession().device.recoveryOpenEverUnanswered)
    }

    @Test func theLegacyEntryIsWrittenBeforeARegistrationResetsTheRecord() async throws {
        defer { phone.close() }
        _ = try await registered()
        try m.persistRecord(m.record.generation) { $0.recoveryOpenUnanswered = true }
        service.cancelRecoveryAtApi()
        // (The rule is entered by the record's mark alone, from a build before the history.)
        #expect(try await twoReads() == .newCode)
        _ = try await m.registerRecovery(try scanned(try secondRecovery()))
        try await m.selectIdentity(.first)
        #expect(try await m.openSession().device.recoveryOpens.map(\.id) == ["legacy"])
    }
}
