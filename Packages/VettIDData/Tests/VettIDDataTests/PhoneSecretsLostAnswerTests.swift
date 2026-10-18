import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// Every lost-answer case of IOS-PLAN §6.3 (the unit tests of IOS-PLAN §8 row I1.4) with the software phone key and a
/// vault that follows vettid-vault `vault/opendek.go`; after each, the vault is reachable with the PIN.
@Suite struct PhoneSecretsLostAnswerTests {
    let t: TestPhone
    let vault = OpenDEKVault()

    init() throws {
        t = try TestPhone()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
    }

    func expectReachable(_ comment: Comment? = nil) async throws {
        #expect(try await t.secrets.unlock(vault) == .opened, comment)
        #expect(try t.records.candidates.isEmpty, comment)
    }

    /// A renew whose answer was lost after the vault stored it: the next unlock gets `device_secret` with the current
    /// record, tries the candidate, and the candidate becomes current.
    @Test func aRenewsAnswerLostThenAnUnlock() async throws {
        let before = try #require(try t.records.current)
        #expect(try await t.secrets.renew(vault, operation: "renew-1", .lostAfterStoring) == nil)
        #expect(try t.records.current == before)
        #expect(try t.records.candidates.count == 1)
        let unlocksBefore = vault.unlocks
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(vault.unlocks - unlocksBefore == 2)
        #expect(try t.records.current?.epoch == 2)
        #expect(try t.records.replaced.map(\.entry) == [before])
        try await expectReachable()
    }

    /// The same, with the vault's state write never done (the header holds the `next` part): the current record opens,
    /// the vault drops `next`, and the candidate becomes a replaced record.
    @Test func aRenewsAnswerLostMidwayThenAnUnlock() async throws {
        let before = try #require(try t.records.current)
        try await t.secrets.renew(vault, operation: "renew-1", .lostMidway)
        let cand = try #require(try t.records.candidates.first?.entry)
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.current == before)
        #expect(try t.records.replaced.map(\.entry) == [cand])
        try await expectReachable()
    }

    /// A renew whose answer was lost, then retried: the retry reuses its record (the same secret), and its answer makes
    /// it current.
    @Test func aRenewsAnswerLostThenARetry() async throws {
        var sent: [[UInt8]] = []
        let lost = try? await t.secrets.change(operation: "renew-1", send: { s -> UnlockAnswer in
            sent.append(s)
            return try vault.change(s, .lostAfterStoring)
        }, confirmed: { $0.ok })
        #expect(lost == nil)
        let answer = try await t.secrets.change(operation: "renew-1", send: { s -> UnlockAnswer in
            sent.append(s)
            return try vault.change(s, .answered)
        }, confirmed: { $0.ok })
        #expect(answer == .opened)
        #expect(sent.count == 2 && sent[0] == sent[1])
        #expect(try t.records.current?.epoch == 2)
        #expect(try t.records.candidates.isEmpty)
        try await expectReachable()
    }

    /// Two renews, the first answer lost: the second (a new operation) makes a new candidate and keeps the first; its
    /// answer confirms it, and the first becomes a replaced record.
    @Test func twoRenewsWithTheFirstAnswerLost() async throws {
        let first = try #require(try t.records.current)
        try await t.secrets.renew(vault, operation: "renew-1", .lostAfterStoring)
        let lostCandidate = try #require(try t.records.candidates.first?.entry)
        try await t.secrets.renew(vault, operation: "renew-2", .answered)
        let recs = try t.records
        #expect(recs.current != lostCandidate && recs.current != first)
        #expect(Set(recs.replaced.map(\.entry.record.check)) == Set([first.check, lostCandidate.check]))
        try await expectReachable()
    }

    /// Two renews, both answers lost, the vault holding the first: the unlock tries the newest candidate first, then the
    /// older one, which becomes current.
    @Test func twoRenewsBothLostTheVaultHoldingTheFirst() async throws {
        try await t.secrets.renew(vault, operation: "renew-1", .lostAfterStoring)
        try await t.secrets.renew(vault, operation: "renew-2", .neverArrived)
        let (older, newer) = (try t.records.candidates[0].entry, try t.records.candidates[1].entry)
        var tried: [[UInt8]] = []
        let answer = try await t.secrets.unlock { s in
            tried.append(s)
            return vault.unlock(s)
        }
        #expect(answer == .opened)
        #expect(tried.count == 3)
        #expect(try t.records.current == older)
        #expect(try t.records.replaced.map(\.entry).contains(newer))
        try await expectReachable()
    }

    /// A crash between storing the record and sending: the record is there after the restart, harmless; the next unlock
    /// with the current record opens and the candidate becomes a replaced record. A retry after the restart reuses it.
    @Test func aCrashBetweenStoringAndSending() async throws {
        let before = try #require(try t.records.current)
        let stored = try t.secrets.beginChange(operation: "renew-1")
        t.reopen()
        #expect(try t.records.candidates.map(\.operation) == ["renew-1"])
        #expect(try t.secrets.beginChange(operation: "renew-1") == stored)
        t.secrets.endChange(operation: "renew-1")  // the retry is not sent either
        #expect(vault.changes == 0)
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.current == before)
        #expect(try t.records.replaced.count == 1)
        try await expectReachable()
    }

    /// While four changes are unconfirmed a fifth is refused before anything is made or sent, and no candidate is dropped;
    /// a retry of one of the four is still allowed. The vault holding the oldest: the unlock finds it.
    @Test func aFifthChangeIsRefusedAndNoCandidateIsDropped() async throws {
        try await t.secrets.renew(vault, operation: "renew-1", .lostAfterStoring)
        for i in 2 ... 4 { try await t.secrets.renew(vault, operation: "renew-\(i)", .neverArrived) }
        let four = try t.records.candidates
        #expect(four.count == 4)
        var sent = false
        let refused = await failureKind {
            try await t.secrets.change(operation: "renew-5", send: { _ -> UnlockAnswer in
                sent = true
                return .opened
            }, confirmed: { $0.ok })
        }
        #expect(refused == .unconfirmedChanges)
        #expect(!sent)
        #expect(try t.records.candidates == four)
        #expect(failureKind { try t.secrets.beginChange(operation: "renew-1") } == nil)
        t.secrets.endChange(operation: "renew-1")
        // The unlock confirms the oldest, the one the vault holds.
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.current == four[0].entry)
        #expect(try t.records.replaced.count == 4)
        try await expectReachable()
        // Now a new change is accepted.
        #expect(try await t.secrets.renew(vault, operation: "renew-5", .answered) == .opened)
        try await expectReachable()
    }

    /// A replaced record is kept 7 days after the confirmation and deleted then; a clock set back never extends them;
    /// candidates are never deleted for their age; a wipe deletes everything at once.
    @Test func replacedRecordsAreKeptSevenDays() async throws {
        let day = TestClock.day
        try await t.secrets.renew(vault, operation: "renew-1", .answered)
        let t0 = t.clock.nowMs
        #expect(try t.records.replaced.map(\.since) == [t0])
        t.clock.nowMs = t0 + 7 * day - 1
        try t.secrets.prune()
        #expect(try t.records.replaced.count == 1)
        #expect(try t.secrets.hasEarlierSecret())
        t.clock.nowMs = t0 + 7 * day
        try t.secrets.prune()
        #expect(try t.records.replaced.isEmpty)
        #expect(try !t.secrets.hasEarlierSecret())

        // A clock set back 3 days: the 7 days count from when that is noticed, never from the later confirmation time.
        try await t.secrets.renew(vault, operation: "renew-2", .answered)
        let t1 = t.clock.nowMs
        t.clock.nowMs = t1 - 3 * day
        try t.secrets.prune()
        #expect(try t.records.replaced.map(\.since) == [t1 - 3 * day])
        t.clock.nowMs = t1 + 4 * day - 1
        try t.secrets.prune()
        #expect(try t.records.replaced.count == 1)
        t.clock.nowMs = t1 + 4 * day
        try t.secrets.prune()
        #expect(try t.records.replaced.isEmpty)

        // Candidates stay whatever their age; nothing is deleted before a later record is confirmed.
        try await t.secrets.renew(vault, operation: "renew-3", .neverArrived)
        t.clock.advance(30 * day)
        try t.secrets.prune()
        #expect(try t.records.candidates.count == 1)
        try await expectReachable()

        // A wipe deletes every record and key at once.
        try await t.secrets.renew(vault, operation: "renew-4", .answered)
        #expect(try !t.records.replaced.isEmpty)
        try t.secrets.delete()
        #expect(try t.records == PhoneRecords())
        #expect(t.keys.keyVaults.isEmpty)
    }

    /// The earlier secret, only from the member's tap: an unlock never tries a replaced record by itself; the step tries
    /// them, newest first; `bad_pin` moves nothing; `ok` makes the record current again (with the History entry and the
    /// new-secret prompt to the caller), and the vault is reachable.
    @Test func theEarlierSecretOnlyFromTheMembersTap() async throws {
        let original = try #require(try t.records.current)
        let originalSecret = try t.secrets.currentSecret()
        try await t.secrets.renew(vault, operation: "renew-1", .answered)
        let renewed = try #require(try t.records.current)
        // An operator restores the state from before the renew (§11.14.2).
        vault.restore(to: originalSecret)
        let unlocks = vault.unlocks
        #expect(try await t.secrets.unlock(vault) == .refused(UnlockEpoch.deviceSecret))
        #expect(vault.unlocks - unlocks == 1)
        #expect(try t.records.current == renewed)
        #expect(try t.secrets.hasEarlierSecret())

        // The member taps, with a wrong PIN: nothing moves.
        let wrong = try await t.secrets.tryEarlierSecret { vault.unlock($0, pin: "000000") }
        guard case .unchanged(let last) = wrong else { Issue.record("moved on bad_pin"); return }
        #expect(last == .refused("bad_pin"))
        #expect(try t.records.current == renewed)

        // With the PIN: the earlier record is current again, the renewed one replaced.
        let right = try await t.secrets.tryEarlierSecret { vault.unlock($0) }
        guard case .restored(let answer, let opened) = right else { Issue.record("not restored"); return }
        #expect(answer == .opened && opened)
        #expect(try t.records.current == original)
        #expect(try t.records.replaced.map(\.entry).contains(renewed))
        try await expectReachable()
        // The prompt for a new phone secret: a renew works at once.
        #expect(try await t.secrets.renew(vault, operation: "renew-after-restore", .answered) == .opened)
        try await expectReachable()
    }

    /// `transfer_incomplete` also makes the earlier record current (an unfinished transfer), without the History entry.
    @Test func theEarlierSecretOnTransferIncomplete() async throws {
        let originalSecret = try t.secrets.currentSecret()
        let original = try #require(try t.records.current)
        try await t.secrets.renew(vault, operation: "renew-1", .answered)
        vault.restore(to: [UInt8](repeating: 9, count: 32))
        // The vault's header: the earlier secret as the pending `next` part of an unfinished transfer.
        _ = try? vault.change(originalSecret, .lostMidway)
        vault.transferIncomplete = true
        let outcome = try await t.secrets.tryEarlierSecret { vault.unlock($0) }
        guard case .restored(let answer, let opened) = outcome else { Issue.record("not restored"); return }
        #expect(answer == .refused(UnlockEpoch.transferIncomplete) && !opened)
        #expect(try t.records.current == original)
    }

    /// Answers decided before the secret check end the candidate tries with the records unchanged.
    @Test func anAnswerBeforeTheSecretCheckProvesNothing() async throws {
        try await t.secrets.renew(vault, operation: "renew-1", .lostAfterStoring)
        let recs = try t.records
        var calls = 0
        let answer = try await t.secrets.unlock { s -> UnlockAnswer in
            calls += 1
            return calls == 1 ? vault.unlock(s) : .refused("backoff")
        }
        #expect(answer == .refused("backoff"))
        #expect(try t.records == recs)
        try await expectReachable()
    }

    // MARK: - A lost answer to a PIN change (VAULT-MESSAGING §11.14.9)

    /// While a change is unresolved, an unlock's `ok` with the current record never demotes that change's candidate (its
    /// request may still reach the vault); another candidate, not in flight, becomes a replaced record as before.
    @Test func theUnresolvedChangesCandidateIsNeverDemoted() async throws {
        _ = try? await t.secrets.change(operation: "op-a", send: { s in try vault.change(s, .neverArrived) }, confirmed: { $0.ok })
        _ = try? await t.secrets.change(operation: "op-b", send: { s in try vault.change(s, .neverArrived) }, confirmed: { $0.ok })
        try t.secrets.setUnresolved(UnresolvedChange(type: .pin, id: "req-a", version: 1, exp: Date(), operation: "op-a"))
        #expect(try await t.secrets.unlock(attempt: { s in vault.unlock(s) }) == .opened)
        #expect(try t.records.candidates.map(\.operation) == ["op-a"])
        #expect(try t.records.replaced.compactMap(\.operation) == ["op-b"])
    }

    /// The new-PIN step tries only the unresolved change's candidate, not an older one nor a pending record.
    @Test func theNewPinStepTriesOnlyItsCandidate() async throws {
        _ = try? await t.secrets.change(operation: "op-a", send: { s in try vault.change(s, .neverArrived) }, confirmed: { $0.ok })
        _ = try? await t.secrets.change(operation: "op-b", send: { s in try vault.change(s, .neverArrived) }, confirmed: { $0.ok })
        var tries = 0
        let answer = try await t.secrets.unlock(tries: .candidate(operation: "op-a")) { s -> UnlockAnswer in
            tries += 1
            return vault.unlock(s)
        }
        #expect(answer == .refused(UnlockEpoch.deviceSecret) && tries == 1)
        #expect(try t.records.candidates.count == 2)
    }

    /// The marker is cleared, and a records file written, only when it matched: a confirmation for another id after a
    /// wipe writes nothing.
    @Test func aConfirmationClearsOnlyItsOwnMarker() throws {
        try t.secrets.delete()
        #expect(try t.secrets.confirmChange(operation: "op-x", clearing: "req-x") == false)
        #expect(!FileManager.default.fileExists(atPath: t.url.path))
    }
}
