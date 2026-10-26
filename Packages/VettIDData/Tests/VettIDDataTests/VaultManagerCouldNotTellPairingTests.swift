import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The pairing of a re-registered N after an `ok` to an unlock (IOS-PLAN 0.1.39 §4.9; VAULT-MESSAGING 0.63.2 §11.14.2, §11.14.6
/// "Pairing"): `hs.init` with each `recovery_id` N registered for, newest first, then E; the binding after the handshake is the
/// attested key of the registration whose `recovery_id` was the `ctx` that completed, and that is the key kept. Against a fake vault
/// that models vettid-vault #150 and #151 (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    struct Rebind {
        let r1: FakeVaultService.RecoveryCodeMade
        let r2: FakeVaultService.RecoveryCodeMade
        let a1: String
        let a2: String
    }

    /// E's open got no answer and its recovery ended; N registered for R1 (App Attest key A1), and its open stored step 2 at the vault
    /// (the invitation R1, the header's binding A1) and its answer was lost; R1 ended too, and N registered again for R2 with A2.
    func nRegisteredAgainAfterStep2() async throws -> Rebind {
        phone.attester.modelKeys()
        service.checkAttestationKeys()
        // The handshake the vault does not answer is seen within seconds here (90 s after `ok` otherwise).
        phone.pairingWait = 4
        try await phone.restart()
        try await endedForGood()
        let r1 = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(r1)) == .registered(emailHint: service.emailHint))
        let a1 = try #require(phone.attester.attestedKeyIDs.last)
        service.nextOpenStopsAfterStep2()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        service.statusUnauthorized = true
        #expect(try await twoReads() == .unlockOrNewCode)
        service.statusUnauthorized = false
        let r2 = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(r2)) == .registered(emailHint: service.emailHint))
        let a2 = try #require(phone.attester.attestedKeyIDs.last)
        #expect(a1 != a2 && service.recoveryBoundKey == raw(a1))
        // Every recovery N registered for is kept, and each key with the registration that attested it, before its POST.
        #expect(device?.registeredRecoveryIDs == [r2.recoveryID, r1.recoveryID])
        #expect(phone.attester.tagged.suffix(2).map(\.registration) == [r1.recoveryID, r2.recoveryID])
        #expect(phone.attester.tagged.suffix(2).map { Data($0.keyID).base64EncodedString() } == [a1, a2])
        return Rebind(r1: r1, r2: r2, a1: a1, a2: a2)
    }

    func raw(_ id: String) -> [UInt8]? { Data(base64Encoded: id).map { Array($0) } }

    /// The modelled App Attest record as kept.
    func keptKeys() throws -> [String: Any] {
        let json = try #require(phone.attester.keptRecord)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// N's key [key] is the one kept, the only one of any identity.
    func expectOnlyKey(_ key: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let kept = try keptKeys()
        #expect(kept["current"] as? String == key, sourceLocation: sourceLocation)
        #expect((kept["pending"] as? [String])?.isEmpty == true, sourceLocation: sourceLocation)
        #expect(kept["earlier"] == nil && kept["parked"] == nil && kept["registrations"] == nil, sourceLocation: sourceLocation)
    }

    @Test func theBindingIsTheKeyOfTheRegistrationTheCompletedCtxNamedNotTheKeyThatAnsweredTheOk() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        // R2's open repeats R1's stored step 2: the vault sets N's invitation again from R2 (A2), and its header write fails.
        service.nextRepeatHeaderWriteFails()
        let (attempts, asserted) = (service.recoveryAttemptsUsed, phone.attester.assertedKeys.count)
        #expect(try await m.recoveryOpen(pin: pin, password: password).code == "retry")
        #expect(service.recoveryAttemptsUsed == attempts && phone.attester.assertedKeys.dropFirst(asserted).first == n.a2)
        // The lost-ok unlock: A2 is refused for its key (the header still binds A1), A1 answers `ok` and finishes step 3.
        let before = phone.attester.assertedKeys.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(Array(phone.attester.assertedKeys.dropFirst(before).prefix(2)) == [n.a2, n.a1])
        // The handshake with R2 (newest first) completes: the binding is A2, which is kept; A1 and E's key go.
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID])
        #expect(phone.attester.settledRegistrations == [n.r2.recoveryID] && phone.attester.settled == [1])
        #expect(service.recoveryBoundKey == raw(n.a2) && m.record.value.couldNotTell == nil)
        try expectOnlyKey(n.a2)
        #expect(service.recoveryAttemptsUsed == attempts)
    }

    @Test func afterAnUnlocksOkNPairsWithEachRecoveryItRegisteredForNewestFirst() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        // R2's open never reached the vault: the invitation is still R1's. The unlock with A1 finishes R1's step 3 and ends R2.
        let before = phone.attester.assertedKeys.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(Array(phone.attester.assertedKeys.dropFirst(before).prefix(2)) == [n.a2, n.a1])
        // R2 first, unanswered; then R1, which completes: the binding is A1, kept; A2 goes.
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID, n.r1.recoveryID])
        #expect(phone.attester.settledRegistrations == [n.r1.recoveryID] && phone.attester.settled == [1])
        #expect(service.recoveryBoundKey == raw(n.a1) && service.recoveryCompleted)
        try expectOnlyKey(n.a1)
        try await m.finishRecoveryOpen()
        #expect(m.phase == .unlocked && m.record.value.activeIdentity == .second)
    }

    @Test func aLaterOpenOfTheRecoveryAnUnlockEndedIsAnsweredNoRecoveryWithNoAttemptAndTheUnlockStillPairs() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        // The unlock with A1 finishes step 3 at the vault (the record goes, R2's too), but its answer is lost.
        service.unlockAnswers(.vault, .answerLost)
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(service.recoveryCompleted && m.record.value.couldNotTell != nil)
        // An open of R2 now: refused at step 1 (`no_recovery`), nothing used, and it proves nothing (its entry stays unanswered).
        let attempts = service.recoveryAttemptsUsed
        let out = try await m.recoveryOpen(pin: pin, password: password)
        #expect(out.code == "no_recovery" && !out.ok && service.recoveryAttemptsUsed == attempts)
        #expect(device?.recoveryOpens.last?.state == .unanswered && device?.recoveryID == n.r2.recoveryID)
        // The lost-ok unlock again: the bundle, and the pairing with R2, then R1, whose invitation it is.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID, n.r1.recoveryID])
        try expectOnlyKey(n.a1)
        #expect(service.recoveryAttemptsUsed == attempts)
    }

    @Test func theRecoveriesNRegisteredForAndTheirKeysSurviveARestart() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        try await phone.restart()
        #expect(try await m.openSession().device.registeredRecoveryIDs == [n.r2.recoveryID, n.r1.recoveryID])
        #expect(try keptKeys()["registrations"] as? [String: String] == [n.a1: n.r1.recoveryID, n.a2: n.r2.recoveryID])
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID, n.r1.recoveryID])
        try expectOnlyKey(n.a1)
    }

    @Test func aKillAfterTheUnlocksOkAndBeforeThePairingStillTriesEachRecoveryNewestFirst() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        // No handshake with R1 is answered (the relay loses two): the `ok` is kept, and the app is killed.
        service.dropNextRecoveryHandshakes(2)
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(service.recoveryHandshakeContexts.filter { $0 == n.r1.recoveryID }.count == 2)
        try await phone.restart()
        #expect(try await m.recoveryOpened())
        // Nothing of N's keys went, and the next pairing is again R2's, then R1's, which completes.
        #expect((try keptKeys()["earlier"] as? [String])?.contains(n.a1) == true)
        let seen = service.recoveryHandshakeContexts.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(Array(service.recoveryHandshakeContexts.dropFirst(seen)) == [n.r2.recoveryID, n.r1.recoveryID])
        try expectOnlyKey(n.a1)
    }

    @Test func aKillBetweenTheHandshakeAndForgettingTheKeysKeepsThemAndTheResumeKeepsTheCompletedCtxsKey() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        service.nextRepeatHeaderWriteFails()
        _ = try await m.recoveryOpen(pin: pin, password: password)
        // The handshake with R2 completes, then the credential never comes, and the app is killed.
        service.loseAnswers(["credential.get"])
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID])
        try await phone.restart()
        #expect(try await m.recoveryOpened())
        #expect(try await m.openSession().device.recoveryPairedCtx == n.r2.recoveryID)
        // Every key is still there: N's both and E's.
        let kept = try keptKeys()
        #expect(kept["current"] as? String == n.a2 && (kept["earlier"] as? [String])?.contains(n.a1) == true && kept["parked"] != nil)
        #expect(m.record.value.couldNotTell != nil && phone.attester.settled.isEmpty)
        // The resume fetches the credential and settles on the completed `ctx`'s key, A2, whichever key unlocks meanwhile.
        service.loseAnswers([])
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        #expect(phone.attester.settledRegistrations == [n.r2.recoveryID] && m.record.value.couldNotTell == nil)
        try expectOnlyKey(n.a2)
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID])
    }

    @Test func aRecordOfTheBuildBeforeTheListPairsWithTheRegistrationItReplacedAndForgetsNoneOfNsKeys() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        // As the build before the list and the tags left them: N's state names R2 and the registration it replaced (R1), no list;
        // no key names its registration.
        phone.close()
        let file = m.config.file(VaultFiles.device(of: .second))
        let bytes = try #require(try file.load())
        var state = try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        var recovery = try #require(state["recovery"] as? [String: Any])
        #expect(recovery["earlier"] != nil && (recovery["replaced"] as? [String: Any])?["recoveryID"] as? String == n.r1.recoveryID)
        recovery.removeValue(forKey: "earlier")
        state["recovery"] = recovery
        try file.save(Array(try JSONSerialization.data(withJSONObject: state)))
        try phone.attester.dropTags()
        try await phone.restart()
        #expect(try await m.openSession().device.registeredRecoveryIDs == [n.r2.recoveryID, n.r1.recoveryID])
        // R2's open never reached the vault: A1's unlock finishes R1's step 3; R2 gets no answer, R1 pairs.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID, n.r1.recoveryID])
        #expect(phone.attester.settledRegistrations == [n.r1.recoveryID] && service.recoveryBoundKey == raw(n.a1))
        // No key names R1: none of N's keys goes (E's do), so the bound A1 is still there, tried after A2.
        let kept = try keptKeys()
        #expect(kept["current"] as? String == n.a2 && kept["earlier"] as? [String] == [n.a1] && kept["parked"] == nil)
    }

    @Test func aRegisterOfNThatDidNotRegisterIsNoRecoveryNRegisteredFor() async throws {
        defer { phone.close() }
        phone.attester.modelKeys()
        let ids = try await secondEnded(.neverProcessed)
        #expect(device?.registeredRecoveryIDs == [ids.second.recoveryID])
        // A readable refusal: N's registration for the earlier recovery is put back, and the refused one is not listed.
        let refused = try secondRecovery()
        service.recoveryRegisterAnswers(.refused("bad_code"))
        #expect(try await m.registerRecovery(try scanned(refused)) == .refused(code: "bad_code"))
        #expect(device?.registeredRecoveryIDs == [ids.second.recoveryID])
        #expect(try keptKeys()["registrations"] as? [String: String] == [phone.attester.attestedKeyIDs[1]: ids.second.recoveryID])
        let next = try secondRecovery()
        #expect(try await m.registerRecovery(try scanned(next)) == .registered(emailHint: service.emailHint))
        #expect(device?.registeredRecoveryIDs == [next.recoveryID, ids.second.recoveryID])
    }

    @Test func afterAnOpensOkTheNewIdentityPairsOnlyWithItsLastRecoveryThenTheEarlierIdentity() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        // R2's open repeats and completes: the invitation is set again from R2, and only R2 is tried.
        #expect(try await m.recoveryOpen(pin: pin, password: password).ok)
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID])
        #expect(phone.attester.settledRegistrations == [n.r2.recoveryID] && service.recoveryBoundKey == raw(n.a2))
        try expectOnlyKey(n.a2)
    }
}
