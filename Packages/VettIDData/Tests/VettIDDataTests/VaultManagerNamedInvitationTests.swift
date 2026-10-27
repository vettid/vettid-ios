import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The pairing with the invitation the vault names (IOS-PLAN 0.1.40 §4.9 "Pairing"; VAULT-MESSAGING 0.67.0 §11.14.6 "Pairing"):
/// when an unlock's `ok` carries `invitation_recovery_id` and one of the phone's identities registered it, that identity sends a
/// single `hs.init` with it; unanswered, the lost-ok unlock again and one more `hs.init` with the id it names, then the walk. An id
/// no identity registered, a result without it, or an older vault: the walk. Against the fake vault (continues
/// ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    /// E's `recovery_id`, read from its stored state.
    func earlierRecoveryID() throws -> String {
        let bytes = try #require(try m.config.file(VaultFiles.device(of: .first)).load())
        return try #require(try VaultDevice.registeredRecoveryIDs(state: bytes).first)
    }

    // MARK: - One identity

    @Test func aLostOkWhoseResultNamesTheInvitationSendsOneHsInitWithIt() async throws {
        defer { phone.close() }
        let made = try await registered()
        service.namesInvitation()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [made.recoveryID] && service.unlocks.count == 1)
        #expect(device?.deviceID != nil && device?.recovering == false)
    }

    @Test func anUnansweredNamedHsInitIsFollowedByTheLostOkUnlockAgainAndOneMoreHsInit() async throws {
        defer { phone.close() }
        phone.pairingWait = 4
        try await phone.restart()
        let made = try await registered()
        service.namesInvitation()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // The relay loses the first `hs.init`: the unlock again (no attempt used), then the `hs.init` with the id it names.
        service.dropNextRecoveryHandshakes(1)
        let attempts = service.recoveryAttemptsUsed
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [made.recoveryID, made.recoveryID] && service.unlocks.count == 2)
        #expect(service.unlocks.allSatisfy { $0.pin == pin } && service.recoveryAttemptsUsed == attempts)
    }

    // MARK: - N registered again

    @Test func theNamedInvitationOfNsEarlierRegistrationIsPairedAloneAndBindsItsKey() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        service.namesInvitation()
        let unlocks = service.unlocks.count
        // R2's open never reached the vault: the invitation is R1's, and A1's `ok` names it. One `hs.init`, with R1, no walk.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [n.r1.recoveryID] && service.unlocks.count == unlocks + 1)
        // The binding is R1's attested key, A1, which is kept; A2 and E's go.
        #expect(service.recoveryBoundKey == raw(n.a1) && phone.attester.settledRegistrations == [n.r1.recoveryID])
        try expectOnlyKey(n.a1)
        try await m.finishRecoveryOpen()
        #expect(m.phase == .unlocked && m.record.value.activeIdentity == .second)
    }

    @Test func anIdNoIdentityRegisteredIsIgnoredAndTheWalkFollows() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        service.namesInvitation(as: Ulid.new())
        let asserted = phone.attester.assertionIdentities.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        // No `hs.init` with the unknown id: R2, then R1, as without the member; E did not unlock.
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID, n.r1.recoveryID])
        #expect(!phone.attester.assertionIdentities.dropFirst(asserted).contains(0))
        try expectOnlyKey(n.a1)
    }

    @Test func anIdOfTheEarlierIdentityIsItsToPairAndWhenItIsNotTheVaultsKeyTheWalkFollows() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        service.namesInvitation(as: try earlierRecoveryID())
        let asserted = phone.attester.assertionIdentities.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        // E unlocked for its id; the vault does not hold E's key, so no `hs.init` with E's id: the walk from N.
        #expect(phone.attester.assertionIdentities.dropFirst(asserted).contains(0))
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID, n.r1.recoveryID])
        #expect(m.record.value.activeIdentity == .second && m.record.value.couldNotTell == nil)
        try expectOnlyKey(n.a1)
    }

    @Test func aReSentUnlockWithoutTheMemberGoesStraightToTheWalk() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        // Only the first result names R1; its `hs.init` is lost; the unlock again names none: the whole walk, R1 included.
        service.namesInvitation(results: 1)
        service.dropNextRecoveryHandshakes(1)
        let unlocks = service.unlocks.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [n.r1.recoveryID, n.r2.recoveryID, n.r1.recoveryID])
        #expect(service.unlocks.count == unlocks + 2)
        #expect(service.recoveryBoundKey == raw(n.a1))
        try expectOnlyKey(n.a1)
    }

    @Test func withoutTheMemberTheWalkIsUnchanged() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        // An older vault: no `invitation_recovery_id`.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [n.r2.recoveryID, n.r1.recoveryID])
        try expectOnlyKey(n.a1)
    }

    @Test func twoNamedHsInitsAtMostThenTheRemainingWalkAndAKillResumesWithTheUnlockFirst() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        service.namesInvitation()
        // Both `hs.init`s with R1 are lost: one unlock between them, never a third with R1 on its own; then R2 (the remaining one).
        service.dropNextRecoveryHandshakes(2)
        let unlocks = service.unlocks.count
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(service.recoveryHandshakeContexts == [n.r1.recoveryID, n.r1.recoveryID, n.r2.recoveryID])
        #expect(service.unlocks.count == unlocks + 2)
        // The app is killed. The named id and its sent `hs.init` are kept, and so are N's keys.
        try await phone.restart()
        #expect(try await m.recoveryOpened())
        #expect(try await m.openSession().device.namedInvitation == NamedInvitation(recoveryID: n.r1.recoveryID, sent: true))
        #expect((try keptKeys()["earlier"] as? [String])?.contains(n.a1) == true)
        // The resume unlocks first (that `hs.init` went), then one `hs.init` with the id it names.
        let seen = service.recoveryHandshakeContexts.count
        let before = service.unlocks.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(Array(service.recoveryHandshakeContexts.dropFirst(seen)) == [n.r1.recoveryID])
        #expect(service.unlocks.count == before + 1)
        try expectOnlyKey(n.a1)
    }

    @Test func aKillBetweenTheUnlocksResultAndItsHsInitSendsItOnTheResumeWithoutAnotherUnlock() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        service.namesInvitation()
        service.dropNextRecoveryHandshakes(2)
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        // As a kill after the unlock's result was saved and before its `hs.init` went: the named id, not sent.
        phone.close()
        let file = m.config.file(VaultFiles.device(of: .second))
        let bytes = try #require(try file.load())
        var state = try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        var recovery = try #require(state["recovery"] as? [String: Any])
        #expect(recovery["invitation"] as? String == n.r1.recoveryID && recovery["invitationSent"] as? Bool == true)
        recovery.removeValue(forKey: "invitationSent")
        state["recovery"] = recovery
        try file.save(Array(try JSONSerialization.data(withJSONObject: state)))
        try await phone.restart()
        let seen = service.recoveryHandshakeContexts.count
        let before = service.unlocks.count
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(Array(service.recoveryHandshakeContexts.dropFirst(seen)) == [n.r1.recoveryID] && service.unlocks.count == before)
        try expectOnlyKey(n.a1)
    }

    // MARK: - The PIN kept for the pairing

    @Test func aPinForgottenWhenTheAppLeftTheForegroundIsAskedForAgainAndAWrongOneIsAnOrdinaryBadPin() async throws {
        defer { phone.close() }
        let n = try await nRegisteredAgainAfterStep2()
        service.namesInvitation()
        service.dropNextRecoveryHandshakes(1)
        let unlocks = service.unlocks.count
        let run = Task { try await m.resumeLostOk(pin: pin) }
        #expect(await eventually { service.recoveryHandshakeContexts.count == 1 })
        // The app leaves the foreground while the first `hs.init` waits: the kept PIN goes, and the unlock again needs it.
        await m.onBackground(budget: .milliseconds(10))
        m.onForeground()
        let out = try await run.value
        #expect(out.code == VaultManager.codePinNeeded && out.opened && out.attemptUsed == false)
        #expect(service.recoveryHandshakeContexts == [n.r1.recoveryID] && service.unlocks.count == unlocks + 1)
        #expect(m.moveFlags.book.pairingPin == nil && m.record.value.activeIdentity == .second)
        // A wrong PIN: an ordinary `bad_pin`, no `hs.init`.
        let bad = try await m.resumeLostOk(pin: "000000")
        #expect(bad.code == "bad_pin" && bad.opened && service.recoveryHandshakeContexts.count == 1)
        // The PIN again: the unlock first (the `hs.init` with R1 went), then one `hs.init` with R1.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(service.recoveryHandshakeContexts == [n.r1.recoveryID, n.r1.recoveryID])
        #expect(m.moveFlags.book.pairingPin == nil)
        try expectOnlyKey(n.a1)
    }

    // MARK: - The earlier identity

    @Test func theMemberNamingEsRecoveryIdLetsEPairWithASingleHsInit() async throws {
        defer { phone.close() }
        service.nextOpenStopsAfterStep2()
        let first = try await openGotNoAnswer(.answerLost)
        service.statusUnauthorized = true
        #expect(try await twoReads() == .newCode)
        service.statusUnauthorized = false
        let made = try secondRecovery()
        _ = try await m.registerRecovery(try scanned(made))
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(try await twoReads() == .finishWithPin)
        service.namesInvitation()
        let seen = service.recoveryHandshakeContexts.count
        // N's unlock is not the vault's key; E's `ok` names E's invitation: one `hs.init`, by E, with E's `recovery_id`.
        #expect(try await m.resumeLostOk(pin: pin).ok)
        #expect(Array(service.recoveryHandshakeContexts.dropFirst(seen)) == [first.recoveryID])
        #expect(m.record.value.activeIdentity == .first && m.record.value.couldNotTell == nil)
    }
}
