import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// Lockout scenarios, each a regression test: after every one the vault stays reachable.
@Suite struct PhoneSecretsRegressionTests {
    /// An unlock in flight with the current record while a renew is sent and stored by the vault: the unlock's `ok`
    /// must not bury the renew's candidate, and the renew's own answer makes it current.
    @Test func anUnlockInFlightDoesNotBuryARenewTheVaultStored() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        let answer = try await t.secrets.unlock { s -> UnlockAnswer in
            let a = vault.unlock(s)
            let next = try t.secrets.beginChange(operation: "renew-1")
            _ = try? vault.change(next, .lostAfterStoring)
            return a
        }
        #expect(answer == .opened)
        #expect(try t.records.candidates.map(\.operation) == ["renew-1"])
        #expect(try t.secrets.confirmChange(operation: "renew-1"))
        #expect(try t.records.current?.epoch == 2)
        #expect(try await t.secrets.unlock(vault) == .opened)
        t.clock.advance(7 * TestClock.day)
        try t.secrets.prune()
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// The same, the renew's answer never arriving: the candidate stays, and the next unlock finds it.
    @Test func anUnlockInFlightLeavesALaterCandidateForTheNextUnlock() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        _ = try await t.secrets.unlock { s -> UnlockAnswer in
            let a = vault.unlock(s)
            _ = try? vault.change(try t.secrets.beginChange(operation: "renew-1"), .lostAfterStoring)
            return a
        }
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.current?.epoch == 2)
    }

    /// A renew's late answer finds its record even after an unlock made it a replaced record.
    @Test func aLateRenewAnswerPromotesItsReplacedRecord() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        let next = try t.secrets.beginChange(operation: "renew-1")
        t.secrets.endChange(operation: "renew-1")  // no answer: abandoned
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.replaced.map(\.operation) == ["renew-1"])
        _ = try vault.change(next, .answered)
        #expect(try t.secrets.confirmChange(operation: "renew-1"))
        #expect(try t.records.current?.epoch == 2)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// A new epoch 1 for the same `key_vault` whose record cannot be written: the old key is untouched (keys are never
    /// overwritten), the new one is deleted, and the vault still opens.
    @Test func aFailedCreateKeepsTheOldKey() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        let dir = t.url.deletingLastPathComponent()
        chmod(dir.path, 0o500)
        defer { chmod(dir.path, 0o700) }
        #expect(failureKind { try t.secrets.create(keyVault: vault.vaultID).secret } == .phoneLocked)
        chmod(dir.path, 0o700)
        #expect(t.keys.count == 1)
        #expect(t.secrets.keysUsable() == .usable)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// A new epoch 1 for the same `key_vault` makes a second key beside the first, never over it.
    @Test func aNewEpochOneNeverOverwritesAKey() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        _ = try t.secrets.create(keyVault: vault.vaultID).secret
        #expect(t.keys.count == 2)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// An operator restore, then a recovery that starts on this phone and never completes: the earlier-secret step is
    /// still there and works.
    @Test func anUnfinishedRecoveryKeepsTheEarlierSecret() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        let original = try t.secrets.currentSecret()
        try await t.secrets.renew(vault, operation: "renew-1", .answered)
        vault.restore(to: original)
        #expect(try t.secrets.hasEarlierSecret())
        _ = try t.secrets.reuseOrCreate(keyVault: vault.vaultID).secret
        #expect(try t.secrets.hasEarlierSecret())
        let outcome = try await t.secrets.tryEarlierSecret { vault.unlock($0) }
        guard case .restored(let answer, let opened) = outcome else { Issue.record("not restored"); return }
        #expect(answer == .opened && opened)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// A vault that arrived by transfer (`key_vault` ""), then an enrollment or recovery for another vault id that is
    /// never sent: the transferred vault's key stays and the vault opens.
    @Test func anUnsentCreateForAnotherKeyVaultKeepsTheTransferredKey() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: ""))
        let made = try t.secrets.create(keyVault: vault.vaultID)
        #expect(t.keys.keyVaults == ["", vault.vaultID])
        #expect(try await t.secrets.unlock(vault) == .opened)
        // Its own success drops nothing at once: the old record becomes a replaced one, its key deleted with it later.
        try t.secrets.confirmCreate(id: made.id)
        #expect(try t.records.replaced.map(\.entry.keyVault) == [""])
        t.clock.advance(7 * TestClock.day)
        try t.secrets.prune()
        #expect(t.keys.keyVaults == [vault.vaultID])
    }

    /// An enrollment whose success was never recorded: the first unlock proves the pending record.
    @Test func theFirstUnlockProvesAPendingEnrollment() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.create(keyVault: vault.vaultID).secret)
        #expect(try t.records.current == nil)
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.current?.keyVault == vault.vaultID)
        #expect(try t.records.pendings.isEmpty)
    }

    /// A records file whose blob format byte this app does not know: refused (`localState`), never used, never written
    /// over, and the "keys usable" check says so rather than "lost".
    @Test func anUnknownFileFormatIsRefusedAndKept() throws {
        let t = try TestPhone()
        _ = try t.secrets.createConfirmed(keyVault: "v1")
        var raw = try Array(Data(contentsOf: t.url))
        raw[0] = 0x02
        try Data(raw).write(to: t.url)
        #expect(failureKind { try t.secrets.currentSecret() } == .localState)
        #expect(failureKind { try t.secrets.create(keyVault: "v1").secret } == .localState)
        #expect(failureKind { try t.secrets.reuseOrCreate(keyVault: "v1").secret } == .localState)
        #expect(t.secrets.keysUsable() == .unknownFormat)
        #expect(try Array(Data(contentsOf: t.url)) == raw)
        #expect(t.keys.count == 1)
    }

    /// Two instances over the same records file never lose each other's writes.
    @Test func twoInstancesOverOneFileDoNotInterleave() throws {
        let t = try TestPhone()
        _ = try t.secrets.createConfirmed(keyVault: "v1")
        let a = t.secrets
        t.reopen()
        let b = t.secrets
        DispatchQueue.concurrentPerform(iterations: 4) { i in
            let s = i.isMultiple(of: 2) ? a : b
            // One change in flight at a time: wait for the slot, then give it back (an abandoned send).
            while (try? s.beginChange(operation: "op-\(i)")) == nil {}
            s.endChange(operation: "op-\(i)")
        }
        #expect(try Set(t.records.candidates.map(\.operation)) == ["op-0", "op-1", "op-2", "op-3"])
    }

    /// A repeated answer of an older change after a newer one was confirmed never brings the older record back.
    @Test func aRepeatedOlderAnswerNeverDemotesTheNewerRecord() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        try await t.secrets.renew(vault, operation: "renew-1", .answered)
        try await t.secrets.renew(vault, operation: "renew-2", .answered)
        #expect(try !t.secrets.confirmChange(operation: "renew-1"))
        #expect(try t.records.current?.epoch == 3)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// Two changes whose answers could arrive in the other order than the vault stored them can no longer both be in
    /// flight: while one is sent and unanswered, a second is refused before anything is made or sent; a retry of the
    /// first is still allowed, and the slot is free again once it is answered or abandoned.
    @Test func aSecondChangeWhileOneIsInFlightIsRefused() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        let s1 = try t.secrets.beginChange(operation: "renew-1")
        let before = try t.records
        #expect(failureKind { try t.secrets.beginChange(operation: "renew-2") } == .busy)
        #expect(try t.records == before)
        #expect(try t.secrets.beginChange(operation: "renew-1") == s1)
        _ = try? vault.change(s1, .lostAfterStoring)
        // Its answer arrives (or it is abandoned): the slot is free.
        #expect(try t.secrets.confirmChange(operation: "renew-1"))
        let s2 = try t.secrets.beginChange(operation: "renew-2")
        _ = try vault.change(s2, .answered)
        #expect(try t.secrets.confirmChange(operation: "renew-2"))
        #expect(try await t.secrets.unlock(vault) == .opened)
        // Abandonment frees it too, and so does a restart.
        _ = try t.secrets.beginChange(operation: "renew-3")
        t.secrets.endChange(operation: "renew-3")
        _ = try t.secrets.beginChange(operation: "renew-4")
        t.reopen()
        #expect(failureKind { try t.secrets.beginChange(operation: "renew-5") } == nil)
    }

    /// Two epoch-1 records in a row, the vault holding the first (a transfer's `hs.init` stored, its answer lost) and the
    /// second never sent: the unlock tries both pending records and finds the first; nothing is lost after 7 days.
    @Test func twoCreatesTheVaultHoldsTheFirst() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.create(keyVault: "").secret)
        _ = try t.secrets.create(keyVault: vault.vaultID).secret
        #expect(try t.records.pendings.count == 2)
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.current?.keyVault == "")
        t.clock.advance(7 * TestClock.day)
        try t.secrets.prune()
        #expect(t.keys.keyVaults == [""])
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// At most four unconfirmed epoch-1 records: a fifth is refused before a key is made, and none is dropped.
    @Test func aFifthPendingEpochOneIsRefused() throws {
        let t = try TestPhone()
        for i in 0 ..< PhoneSecrets.maxPendings { _ = try t.secrets.create(keyVault: "v\(i)").secret }
        let four = try t.records.pendings
        #expect(failureKind { try t.secrets.create(keyVault: "v9").secret } == .unconfirmedChanges)
        #expect(try t.records.pendings == four)
        #expect(t.keys.count == 4)
    }

    /// A change already sent when an unlock starts, which the vault stores after that unlock: the unlock's `ok` leaves
    /// its candidate alone, and the next unlock finds it.
    @Test func aChangeInFlightWhenTheUnlockStartsStays() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        let next = try t.secrets.beginChange(operation: "renew-1")
        _ = try await t.secrets.unlock { s -> UnlockAnswer in
            let a = vault.unlock(s)
            _ = try? vault.change(next, .lostAfterStoring)
            return a
        }
        t.secrets.endChange(operation: "renew-1")
        #expect(try t.records.candidates.count == 1)
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.current?.epoch == 2)
    }

    /// Two unlocks at once with a renew between them: neither buries the renew.
    @Test func twoConcurrentUnlocksDoNotBuryARenew() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        _ = try await t.secrets.unlock { s1 -> UnlockAnswer in
            let a1 = vault.unlock(s1)
            let next = try t.secrets.beginChange(operation: "renew-1")
            _ = try await t.secrets.unlock { s2 -> UnlockAnswer in
                let a2 = vault.unlock(s2)
                _ = try? vault.change(next, .lostAfterStoring)
                return a2
            }
            return a1
        }
        t.secrets.endChange(operation: "renew-1")
        #expect(try t.records.candidates.count == 1)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// A recovery's register stored by the vault while a candidate waits: the unlock proves the pending record, and
    /// after 7 days only its key remains, and it works.
    @Test func aPendingRecordProvedWhileACandidateWaits() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        try await t.secrets.renew(vault, operation: "renew-1", .neverArrived)
        vault.enroll(try t.secrets.create(keyVault: vault.vaultID).secret)
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.pendings.isEmpty && t.records.candidates.isEmpty)
        t.clock.advance(7 * TestClock.day)
        try t.secrets.prune()
        #expect(t.keys.count == 1)
        #expect(t.secrets.keysUsable() == .usable)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// A damaged records file replaced by a new epoch 1: the keys it named, which nothing names any more, are deleted.
    @Test func replacingADamagedFileDeletesTheKeysItNamed() throws {
        let t = try TestPhone()
        _ = try t.secrets.createConfirmed(keyVault: "v1")
        _ = try t.secrets.create(keyVault: "v2").secret
        var raw = try Array(Data(contentsOf: t.url))
        raw[raw.count - 1] ^= 1
        try Data(raw).write(to: t.url)
        #expect(failureKind { try t.secrets.currentSecret() } == .deviceSecret)
        _ = try t.secrets.create(keyVault: "v3").secret
        #expect(t.keys.keyVaults == ["v3"])
        #expect(t.keys.count == 1)
    }

    /// Two epoch-1 records for the same `key_vault` (two transfers' `hs.init`): the success of the first confirms
    /// exactly the first, never the newer one.
    @Test func confirmCreatePromotesExactlyItsRecord() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        let a = try t.secrets.create(keyVault: "")
        vault.enroll(a.secret)
        let b = try t.secrets.create(keyVault: "")
        #expect(a.id != b.id)
        #expect(try t.secrets.confirmCreate(id: a.id))
        #expect(try t.records.current?.keyID == a.id)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// A change whose task is cancelled while it awaits the vault frees the in-flight slot; so does one whose send
    /// throws. Its candidate stays.
    @Test func aCancelledChangeFreesTheSlot() async throws {
        let t = try TestPhone()
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
        let secrets = t.secrets
        let task = Task {
            try await secrets.change(operation: "renew-1", send: { _ -> UnlockAnswer in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return .opened
            }, confirmed: { $0.ok })
        }
        while try t.records.candidates.isEmpty { await Task.yield() }
        #expect(failureKind { try t.secrets.beginChange(operation: "renew-2") } == .busy)
        task.cancel()
        _ = await task.result
        #expect(try t.records.candidates.map(\.operation) == ["renew-1"])
        #expect(try await t.secrets.renew(vault, operation: "renew-2", .answered) == .opened)
        struct Boom: Error {}
        _ = try? await t.secrets.change(operation: "renew-3", send: { _ -> UnlockAnswer in throw Boom() }, confirmed: { $0.ok })
        #expect(try await t.secrets.renew(vault, operation: "renew-4", .answered) == .opened)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// A phone key source serves one records file: a second file over the same source is refused (the damaged-file
    /// sweep could otherwise delete the other file's keys); the same file again is fine.
    @Test func oneRecordsFilePerKeySource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = "test-source-" + UUID().uuidString
        #expect(PhoneSecretsRegistry.claim(source: source, records: dir.appendingPathComponent("a")))
        #expect(PhoneSecretsRegistry.claim(source: source, records: dir.appendingPathComponent("a")))
        #expect(!PhoneSecretsRegistry.claim(source: source, records: dir.appendingPathComponent("b")))
        // A reopened phone (same source, same file) is accepted.
        let t = try TestPhone()
        t.reopen()
        #expect(PhoneSecretsRegistry.claim(source: t.keys.sourceID, records: t.url))
    }

    /// Four pending records whose keys are gone no longer block a new epoch 1: they are dropped before the bound is
    /// applied. Four whose keys still exist, or are locked, keep blocking it.
    @Test func deadPendingsDoNotBlockANewEpochOne() throws {
        let t = try TestPhone()
        for kv in ["a", "b", "c", "d"] { _ = try t.secrets.reuseOrCreate(keyVault: kv) }
        #expect(failureKind { try t.secrets.reuseOrCreate(keyVault: "e") } == .unconfirmedChanges)
        // Locked keys are not "gone".
        for kv in ["a", "b"] { t.keys.key(kv)?.state.behaviour = .locked }
        #expect(failureKind { try t.secrets.reuseOrCreate(keyVault: "e") } == .unconfirmedChanges)
        // A missing key and an invalid one are.
        t.keys.key("a")?.state.behaviour = .normal
        t.keys.deleteKeys(of: "a")
        t.keys.key("b")?.state.behaviour = .invalid
        #expect(failureKind { try t.secrets.reuseOrCreate(keyVault: "e") } == nil)
        #expect(try t.records.pendings.map(\.keyVault) == ["c", "d", "e"])
        #expect(t.keys.keyVaults == ["c", "d", "e"])
    }
}
