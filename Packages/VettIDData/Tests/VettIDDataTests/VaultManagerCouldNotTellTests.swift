import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// swiftlint:disable line_length

/// A phone that could not tell (IOS-PLAN 0.1.33 §4.9; VAULT-MESSAGING 0.59.0 §11.14.6): when the rule applies, how the two
/// status reads decide, and what is kept. Continues ``VaultManagerRecoveryTests``; the new recovery itself is in
/// ``VaultManagerCouldNotTellRegisterTests``.
extension VaultManagerRecoveryTests {
    /// Both clocks of the phone move together.
    func later(_ seconds: TimeInterval) {
        phone.clockAhead += seconds
        phone.uptimeAhead += seconds
    }

    /// The registered phone's open was taken by the member API and got no answer.
    @discardableResult
    func openGotNoAnswer(_ answer: FakeVaultService.RecoveryOpenAnswer = .neverProcessed) async throws -> FakeVaultService.RecoveryCodeMade {
        let made = try await registered()
        service.recoveryOpenAnswers(answer)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(m.record.value.recoveryOpenUnanswered)
        return made
    }

    /// Two reads of the same kind, the second 5 minutes and a second after the first: [stage] is the second's.
    func twoReads() async throws -> CouldNotTellStage {
        guard case .waiting = try await m.checkCouldNotTell() else {
            Issue.record("the first read decided")
            return .none
        }
        let (wall, up) = (phone.clockAhead, phone.uptimeAhead)
        later(301)
        let stage = try await m.checkCouldNotTell()
        // The phone's clocks also set the timestamps it sends the vault: they go back for what follows.
        (phone.clockAhead, phone.uptimeAhead) = (wall, up)
        return stage
    }

    /// The registered phone's open got no answer, and its recovery ended: both reads said so.
    @discardableResult
    func endedForGood(_ answer: FakeVaultService.RecoveryOpenAnswer = .neverProcessed) async throws -> FakeVaultService.RecoveryCodeMade {
        let made = try await openGotNoAnswer(answer)
        service.cancelRecoveryAtApi()
        #expect(try await twoReads() == .newCode)
        return made
    }

    /// K, both identities' keys if there are two, the earlier device state and the phone-secret record are all still there.
    func expectKept(_ k: [UInt8], earlier: IdentitySet = .first, secondToo: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try phone.appKeys.getOrCreate().spki() == k, sourceLocation: sourceLocation)
        for slot in KeySlot.slots(of: earlier) {
            #expect(try phone.wrapped.get(slot) != nil, "\(slot) kept", sourceLocation: sourceLocation)
        }
        #expect(try m.config.file(VaultFiles.device(of: earlier)).load() != nil, sourceLocation: sourceLocation)
        if secondToo {
            for slot in KeySlot.slots(of: earlier.next!) {
                #expect(try phone.wrapped.get(slot) != nil, "\(slot) kept", sourceLocation: sourceLocation)
            }
        }
        #expect(pendingRecord || hasCurrentRecord, sourceLocation: sourceLocation)
    }

    /// The vault adopted this phone (K is its app key), two reads said `401`, and the claim of a new code is a key in use: the
    /// unlock is what is left (the vault took this phone).
    @discardableResult
    func keyInUseUnlock() async throws -> FakeVaultService.RecoveryCodeMade {
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        #expect(try await m.registerRecovery(try scanned(try secondRecovery())) == .refused(code: VaultManager.codeKeyInUse))
        return first
    }

    // MARK: - When

    @Test func theRuleIsNotThereWithoutAnOpenThatGotNoAnswer() async throws {
        defer { phone.close() }
        _ = try await registered()
        let reads = service.statusReads
        let (check, stage) = (try await m.checkCouldNotTell(), try await m.couldNotTellStage())
        #expect(check == .none && stage == .none)
        #expect(m.record.value.couldNotTellRead == nil && m.record.value.couldNotTell == nil && service.statusReads == reads)
        // An open that was answered (a wrong entry) is no open that could not be told.
        _ = try await m.recoveryOpen(pin: "111111", password: password)
        service.cancelRecoveryAtApi()
        #expect(try await m.checkCouldNotTell() == .none && service.statusReads == reads)
    }

    @Test func aRecoveryThatStillShowsRegisteredOpensAgain() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        // `registered`: never the rule, however often it is read; nothing is kept as a first read.
        #expect(try await m.checkCouldNotTell() == .none)
        later(301)
        #expect(try await m.checkCouldNotTell() == .none)
        #expect(m.record.value.couldNotTellRead == nil && m.record.value.couldNotTell == nil)
        // The open is sent again as before.
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
    }

    @Test func aReadThatDecidesNothingIsNotARead() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        // No vault (`vault: null`), a `401` the phone's clock explains, and the network: undecided, nothing kept.
        service.status("unlocked", noVault: true)
        #expect(try await m.checkCouldNotTell() == .none)
        service.status("unlocked")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        service.cancelRecoveryAtApi(headers: ["Date": formatter.string(from: Date().addingTimeInterval(3600))])
        #expect(try await m.checkCouldNotTell() == .none)
        #expect(m.record.value.couldNotTellRead == nil && m.record.value.couldNotTell == nil)
    }

    @Test func theRequestIdOfEveryOpenIsKeptBeforeItIsPostedAndSurvivesARestart() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        let seen = try #require(service.recoveryOpens.first?.requestID)
        try await phone.restart()
        let d = try await m.openSession().device
        #expect(d.recoveryOpenRequestIDs == [seen])
        // A second open adds its own, newest first.
        service.recoveryOpenAnswers(.neverProcessed)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        let second = try #require(service.recoveryOpens.last?.requestID)
        #expect(d.recoveryOpenRequestIDs == [second, seen])
    }

    // MARK: - The two reads

    @Test func twoReadsOfAnEndedRecoveryFiveMinutesApartAllowANewRecovery() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.cancelRecoveryAtApi()
        let first = try await m.checkCouldNotTell()
        guard case .waiting(let until) = first else { Issue.record("not waiting: \(first)"); return }
        let mark = m.record.value.couldNotTellRead
        #expect(mark?.ended == true && until.timeIntervalSinceNow > 290)
        // At once, and a minute before the time: nothing is sent, and the first read stands.
        let reads = service.statusReads
        #expect(try await m.checkCouldNotTell() == first)
        later(239)
        #expect(try await m.checkCouldNotTell() == .waiting(until: until) && service.statusReads == reads)
        #expect(m.record.value.couldNotTellRead == mark && m.record.value.couldNotTell == nil)
        // 5 minutes after the first: the second read decides.
        later(62)
        #expect(try await m.checkCouldNotTell() == .newCode)
        // (A `401` is asked again with a new signature, so the deciding read is two requests.)
        #expect(service.statusReads > reads && m.record.value.couldNotTellRead == nil)
        #expect(m.record.value.couldNotTell == CouldNotTell(earlier: .first, ended: true))
        // It survives a restart.
        try await phone.restart()
        #expect(try await m.couldNotTellStage() == .newCode)
    }

    @Test func aGoneRecoveryReadAs410IsTheSame() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.cancelRecoveryAtApi(as410: true)
        #expect(try await twoReads() == .newCode)
    }

    @Test func theRuleNeverForgetsKWhileItIsUndecided() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await openGotNoAnswer()
        service.cancelRecoveryAtApi(as410: true)
        // Even on a 410, and with two reads that said "ended", a start over is refused and nothing is forgotten.
        #expect(try await twoReads() == .newCode)
        let f = await vaultFailure { try await m.abandonRecovery() }
        #expect(f?.code == VaultManager.codeRecoveryOpenSent && m.phase != .signedOut)
        try expectKept(k)
        #expect(device?.recovering == true)
    }

    @Test func aReadOfAnotherKindStartsTheTwoReadsAgain() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.cancelRecoveryAtApi()
        guard case .waiting = try await m.checkCouldNotTell() else { Issue.record("decided"); return }
        later(301)
        // The second read is a `200` that is not `registered`: it is the first of the next pair, nothing is decided.
        service.statusUnauthorized = false
        service.recoveryStatusShows("available")
        service.uncancelRecoveryAtApi()
        guard case .waiting = try await m.checkCouldNotTell() else { Issue.record("decided on two different reads"); return }
        #expect(m.record.value.couldNotTellRead?.ended == false && m.record.value.couldNotTell == nil)
        later(301)
        #expect(try await m.checkCouldNotTell() == .finishWithPin)
    }

    @Test func theClockIsCheckedBeforeTheSecondReadCounts() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.cancelRecoveryAtApi()
        guard case .waiting = try await m.checkCouldNotTell() else { Issue.record("decided"); return }
        let first = m.record.value.couldNotTellRead
        // The phone's clock was set 10 minutes ahead; the monotonic clock did not move: the first read counts for nothing.
        phone.clockAhead += 600
        guard case .waiting = try await m.checkCouldNotTell() else { Issue.record("decided on a set clock"); return }
        #expect(m.record.value.couldNotTell == nil && m.record.value.couldNotTellRead != first)
        // Set back: the same.
        phone.clockAhead -= 2000
        guard case .waiting = try await m.checkCouldNotTell() else { Issue.record("decided on a clock set back"); return }
        #expect(m.record.value.couldNotTell == nil)
        // Only the monotonic clock moved (a phone restarted shows a smaller one): the same.
        phone.uptimeAhead += 900
        guard case .waiting = try await m.checkCouldNotTell() else { Issue.record("decided on a monotonic clock that jumped"); return }
        #expect(m.record.value.couldNotTell == nil)
        // Both clocks agreeing, 5 minutes later: decided.
        later(301)
        #expect(try await m.checkCouldNotTell() == .newCode)
    }

    // MARK: - A 200 is not proof of adoption

    @Test func aTwoHundredAloneIsNeverAdoptionAndSendsTheLostOkUnlock() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        // K reads the status (the vault's pending next key, say) but the vault did not adopt this phone.
        try await openGotNoAnswer()
        service.recoveryStatusShows("available")
        #expect(try await twoReads() == .finishWithPin)
        #expect(m.record.value.couldNotTell == CouldNotTell(earlier: .first, unlock: true, byReads: true) && m.record.value.recoveryOpenUnanswered)
        // The unlock is refused: everything is kept and the stage stays.
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.code == VaultManager.codeNoBundle && out.opened)
        try expectKept(k)
        // K may be only an orphaned pending key: a refusal here is no "Contact VettID" (that is for a vault that took this phone).
        #expect(try await m.couldNotTellStage() == .finishWithPin && device?.recovering == true)
        #expect(m.record.value.couldNotTell?.refusalsSinceMs == nil)
        // No new recovery: the code is not registered over it.
        let made = try armed()
        let claims = service.recoveryClaims.count
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(f?.code == VaultManager.codeRecoveryOpenSent && service.recoveryClaims.count == claims)
    }

    @Test func aTwoHundredFollowedByTheUnlockThatOpensPairsWithTheEarlierRecoveryId() async throws {
        defer { phone.close() }
        let made = try await openGotNoAnswer(.answerLost)
        // The vault adopted this phone (K is its app key): the status reads `200` with no recovery.
        #expect(try await twoReads() == .finishWithPin)
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.ok)
        #expect(service.recoveryHandshakeContexts == [made.recoveryID] && device?.deviceID != nil && device?.recovering == false)
        // The rule is over, nothing else was made.
        #expect(m.record.value.couldNotTell == nil && m.record.value.activeIdentity == .first)
        #expect(try phone.wrapped.get(.identity2) == nil && !FileManager.default.fileExists(atPath: phone.directory.appendingPathComponent(VaultFiles.device(of: .second)).path))
    }

    @Test func aTransferIncompleteOpensAgainWhileTheRecoveryShowsRegistered() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.registeredPhoneHoldsUnlockKey()
        service.unlockAnswers(.sealed("transfer_incomplete"))
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.code == "transfer_incomplete" && out.opened)
        // `registered`: the phone opens again, and the rule does not apply.
        #expect(try await m.couldNotTellStage() == .none && m.record.value.couldNotTell == nil)
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
    }

    @Test func aTransferIncompleteWithoutARegisteredRecoveryIsTheRule() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        // From an active rule state: two reads of `200` made the unlock what is left.
        try await openGotNoAnswer(.answerLost)
        #expect(try await twoReads() == .finishWithPin && m.record.value.couldNotTell?.unlockByReads == true)
        // The vault completed the recovery, so the status shows none; the state is still under DEK_0.
        service.unlockAnswers(.sealed("transfer_incomplete"))
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.code == "transfer_incomplete")
        // The unlock is given up for the rule, which is decided by two reads as any other.
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.transferIncomplete && !ct.unlock && !ct.ended && ct.refusalsSinceMs == nil)
        // (The first read was made with the answer.)
        #expect(m.record.value.couldNotTellRead?.ended == true)
        let (wall, up) = (phone.clockAhead, phone.uptimeAhead)
        later(301)
        #expect(try await m.checkCouldNotTell() == .newCode)
        (phone.clockAhead, phone.uptimeAhead) = (wall, up)
        #expect(m.record.value.couldNotTell?.ended == true && m.record.value.couldNotTell?.transferIncomplete == false)
        try expectKept(k)
    }

    @Test func aTwoHundredUnlockThatIsRefusedReadsTheStatusAgainAndAnEndedRecoveryIsANewCode() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        // K was only the vault's orphaned pending key: two reads of `200`, the unlock refused.
        try await openGotNoAnswer()
        service.recoveryStatusShows("available")
        #expect(try await twoReads() == .finishWithPin)
        #expect(try await m.resumeLostOk(pin: pin).opened)
        #expect(m.record.value.couldNotTell?.refusalsSinceMs == nil)
        // The host clears the orphan: the status is `401`. The phone reads it again, on the same two reads.
        service.cancelRecoveryAtApi()
        let reads = service.statusReads
        #expect(try await twoReads() == .newCode)
        #expect(service.statusReads > reads)
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.ended && !ct.unlock && !ct.unlockByReads && ct.refusalsSinceMs == nil)
        try expectKept(k)
        // And the day of refusals no longer applies.
        later(90_000)
        #expect(try await m.couldNotTellStage() == .newCode)
    }

    @Test func anUnlockThatAKeyInUseLedToIsReadAgainButNeverGivenUpForEndedReads() async throws {
        defer { phone.close() }
        try await keyInUseUnlock()
        #expect(m.record.value.couldNotTell?.unlock == true && m.record.value.couldNotTell?.unlockByReads == false)
        // K is the vault's app key: two reads of `401` (a fault, say) do not make it a new recovery.
        service.statusUnauthorized = true
        #expect(try await twoReads() == .finishWithPin)
        let ct = try #require(m.record.value.couldNotTell)
        #expect(ct.unlock && !ct.ended)
    }

    @Test func anyOtherRefusalKeepsEverythingAndReadsAgainLater() async throws {
        defer { phone.close() }
        let k = try phone.appKeys.getOrCreate().spki()
        try await openGotNoAnswer(.answerLost)
        #expect(try await twoReads() == .finishWithPin)
        service.unlockAnswers(.sealed("unknown_device"))
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.code == "unknown_device" && out.opened)
        try expectKept(k)
        #expect(device?.recovering == true && m.record.value.recoveryOpenUnanswered)
        // The status is read again (the unlock came from reads), not given up.
        let reads = service.statusReads
        let (wall, up) = (phone.clockAhead, phone.uptimeAhead)
        later(301)
        _ = try await m.checkCouldNotTell()
        #expect(service.statusReads > reads)
        (phone.clockAhead, phone.uptimeAhead) = (wall, up)
        // Later it opens.
        #expect(try await m.resumeLostOk(pin: pin).ok)
    }

    // MARK: - A day of refusals

    @Test func aDayOfRefusalsShowsTheSecondText() async throws {
        defer { phone.close() }
        try await keyInUseUnlock()
        service.unlockAnswers(.sealed("unknown_device"))
        _ = try await m.resumeLostOk(pin: pin)
        let since = try #require(m.record.value.couldNotTell?.refusalsSinceMs)
        later(86_000)
        service.unlockAnswers(.sealed("unknown_device"))
        _ = try await m.resumeLostOk(pin: pin)
        #expect(try await m.couldNotTellStage() == .finishWithPin && m.record.value.couldNotTell?.refusalsSinceMs == since)
        later(500)
        #expect(try await m.couldNotTellStage() == .contact)
        // Kept: the PIN still tries, and nothing is forgotten.
        service.unlockAnswers(.sealed("unknown_device"))
        let again = try await m.resumeLostOk(pin: pin)
        #expect(again.opened && !again.ok && device?.recovering == true)
        try await phone.restart()
        #expect(try await m.couldNotTellStage() == .contact)
    }

    @Test func theSecondTextIsNeverForAnUnlockThatTwoReadsOf200LedTo() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.recoveryStatusShows("available")
        #expect(try await twoReads() == .finishWithPin)
        _ = try await m.resumeLostOk(pin: pin)
        later(200_000)
        _ = try await m.resumeLostOk(pin: pin)
        #expect(try await m.couldNotTellStage() == .finishWithPin)
    }

    @Test func afterAKeyInUseTheStatusIsStillReadAgainLater() async throws {
        defer { phone.close() }
        try await keyInUseUnlock()
        let reads = service.statusReads
        let (wall, up) = (phone.clockAhead, phone.uptimeAhead)
        later(301)
        _ = try await m.checkCouldNotTell()
        (phone.clockAhead, phone.uptimeAhead) = (wall, up)
        #expect(service.statusReads > reads && m.record.value.couldNotTell?.unlock == true)
    }

    @Test func aWrongPinIsNoRefusalOfThePhone() async throws {
        defer { phone.close() }
        try await openGotNoAnswer(.answerLost)
        #expect(try await twoReads() == .finishWithPin)
        let out = try await m.resumeLostOk(pin: "000000")
        #expect(out.code == "bad_pin" && m.record.value.couldNotTell?.refusalsSinceMs == nil)
        #expect(try await m.resumeLostOk(pin: pin).ok)
    }

    @Test func anUnreachableServiceIsNoRefusalEither() async throws {
        defer { phone.close() }
        try await openGotNoAnswer()
        service.recoveryStatusShows("available")
        #expect(try await twoReads() == .finishWithPin)
        service.unlockAnswers(.offline)
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(m.record.value.couldNotTell?.refusalsSinceMs == nil)
    }
}

extension CouldNotTell {
    init(earlier: IdentitySet, ended: Bool = false, unlock: Bool = false, byReads: Bool = false) {
        self.init(earlier: earlier)
        self.ended = ended
        self.unlock = unlock
        unlockByReads = byReads
    }
}

// swiftlint:enable line_length
