import Foundation
import Testing
import VettIDCrypto
@testable import VettIDKeys
import VettIDKeysTesting

/// A phone that could not tell holds two device identities (IOS-PLAN 0.1.38 §4.9), and the vault bound each one's own App Attest
/// key at its register: the keys of the identity in use are the current and pending ones, the other's wait untouched. N is
/// registered again with a new key for each further recovery, and its earlier keys are kept until the handshake completes.
@Suite struct AppAttestIdentityTests {
    let challenge = [UInt8](repeating: 7, count: 32)

    func make(_ fake: FakeAppAttest, _ store: MemoryKeyIDStore = MemoryKeyIDStore()) -> AppAttestKey {
        AppAttestKey(
            service: fake, keyID: store, aside: MemoryKeyIDStore(), mayStartOver: { false }, backoff: [], sleep: { _ in },
            checkThread: false
        )
    }

    func asserted(_ key: AppAttestKey) throws -> String {
        guard case .ios(let assertion) = try key.assert(clientDataHash: challenge) else { throw TestFailure("not iOS") }
        return String(bytes: assertion.dropLast(32), encoding: .utf8) ?? ""
    }

    func attested(_ key: AppAttestKey) throws -> [UInt8] {
        guard case .ios(let id, _) = try key.attest(clientDataHash: challenge) else { throw TestFailure("not iOS") }
        return id
    }

    @Test func theEarlierIdentitysKeyIsKeptWhileTheNewIdentityIsConfirmed() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        // The earlier identity's register was answered `ok`: its key is the current one.
        try key.confirm(keyID: try attested(key))
        #expect(try asserted(key) == fake.keyID(1))
        // The new identity: its keys are its own.
        try key.use(identity: 1)
        #expect(throws: KeysError.self) { try key.assert(clientDataHash: challenge) }
        let new = try attested(key)
        #expect(try asserted(key) == fake.keyID(2))
        try key.confirm(keyID: new)
        #expect(try asserted(key) == fake.keyID(2))
        // Back to the earlier identity: its key asserts, and the new one's waits.
        try key.use(identity: 0)
        #expect(try asserted(key) == fake.keyID(1))
        // A later process reads the same record, and the same identity in use.
        let later = make(fake, store)
        #expect(try asserted(later) == fake.keyID(1))
        try later.use(identity: 1)
        #expect(try asserted(later) == fake.keyID(2))
    }

    @Test func aConfirmationOfTheNewIdentityNeverForgetsTheEarlierOnes() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        let a = try attested(key)
        let b = try attested(key)
        try key.use(identity: 1)
        let c = try attested(key)
        try key.confirm(keyID: c)
        // The earlier identity still has both of its pending keys, and the confirm of one of them is its own.
        try key.use(identity: 0)
        #expect(try asserted(key) == fake.keyID(2))
        try key.confirm(keyID: a)
        #expect(try asserted(key) == fake.keyID(1))
        _ = b
        try key.use(identity: 1)
        #expect(try asserted(key) == fake.keyID(3))
    }

    @Test func theLimitOnPendingKeysIsPerIdentityRecordInUse() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        for _ in 0..<AppAttestKey.maxPending { _ = try attested(key) }
        #expect(throws: AppAttestError.pendingFull) { try key.attest(clientDataHash: challenge) }
        // The other identity has none pending: it can attest, and the first's keys are not dropped.
        try key.use(identity: 1)
        _ = try attested(key)
        try key.use(identity: 0)
        #expect(try asserted(key) == fake.keyID(UInt8(AppAttestKey.maxPending)))
    }

    @Test func aForgottenIdentityIsGoneAndTheOneInUseIsNeverForgotten() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        try key.confirm(keyID: try attested(key))
        try key.use(identity: 1)
        try key.confirm(keyID: try attested(key))
        // The identity in use stays.
        try key.forget(identity: 1)
        #expect(try asserted(key) == fake.keyID(2))
        // The other one goes, with the pairing complete.
        try key.forget(identity: 0)
        try key.use(identity: 0)
        #expect(throws: KeysError.self) { try key.assert(clientDataHash: challenge) }
        // The identity that stayed has its key.
        try key.use(identity: 1)
        #expect(try asserted(key) == fake.keyID(2))
    }

    @Test func aRecordOfTheEarlierFormatIsTheFirstIdentitys() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        try store.write(Array(fake.keyID(9).utf8))
        let key = make(fake, store)
        #expect(try asserted(key) == fake.keyID(9))
        try key.use(identity: 1)
        try key.use(identity: 0)
        #expect(try asserted(key) == fake.keyID(9))
    }

    @Test func aForgetResetsTheIdentitiesAndTheFirstOneHasItsOwnKeys() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        try key.confirm(keyID: try attested(key))
        try key.use(identity: 1)
        try key.confirm(keyID: try attested(key))
        // After a forget the first identity is in use again, with its own key, and the second's are gone.
        try key.resetIdentities()
        #expect(try asserted(key) == fake.keyID(1))
        try key.use(identity: 1)
        #expect(throws: KeysError.self) { try key.assert(clientDataHash: challenge) }
        // Resetting a record that is in order changes nothing.
        try key.use(identity: 0)
        try key.resetIdentities()
        #expect(try asserted(key) == fake.keyID(1))
    }

    @Test func aStaleCurrentKeyIsNotTheNewIdentitysWhenItsKeysAreForgottenBeforeItsFirstUse() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        try key.confirm(keyID: try attested(key))
        // An earlier episode left keys parked under 1.
        try key.use(identity: 1)
        try key.confirm(keyID: try attested(key))
        try key.use(identity: 0)
        // A new episode: the identity 1 has none of them.
        try key.forget(identity: 1)
        try key.use(identity: 1)
        #expect(throws: KeysError.self) { try key.assert(clientDataHash: challenge) }
        try key.confirm(keyID: try attested(key))
        #expect(try asserted(key) == fake.keyID(3))
    }

    // MARK: - N registered again (IOS-PLAN 0.1.38 §4.9)

    func stored(_ store: MemoryKeyIDStore) throws -> KeyIDRecord {
        guard let r = KeyIDRecord(try store.lookup().get("record")) else { throw TestFailure("unreadable record") }
        return r
    }

    /// E registered and confirmed, then N registered for a first recovery (confirmed) and again for a second one, each with a key
    /// of its own: E's is key 1, N's are 2 and 3.
    func nRegisteredTwice(_ key: AppAttestKey) throws -> (first: [UInt8], second: [UInt8]) {
        try key.confirm(keyID: try attested(key))
        try key.use(identity: 1)
        try key.keepReplacedKeys()
        let first = try attested(key)
        try key.confirm(keyID: first)
        try key.keepReplacedKeys()
        let second = try attested(key)
        return (first, second)
    }

    @Test func eachRegisterOfNAttestsANewKeyAndKeepsTheEarlierOnesUntilTheHandshakeCompletes() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        let (first, second) = try nRegisteredTwice(key)
        #expect(first != second)
        // The second register (R2, its key tagged before the POST) is confirmed: its key is in use, and the first registration's key
        // is kept beside it.
        try key.tag(keyID: second, registration: "R2")
        try key.confirm(keyID: second)
        #expect(try asserted(key) == fake.keyID(3))
        let record = try stored(store)
        #expect(record.current == fake.keyID(3) && record.earlier == [fake.keyID(2)] && record.keepsReplaced)
        // E's key is kept too, and a later process reads the same.
        let later = make(fake, store)
        try later.use(identity: 0)
        #expect(try asserted(later) == fake.keyID(1))
        try later.use(identity: 1)
        #expect(try asserted(later) == fake.keyID(3))
        // The handshake completes with N and the `ctx` of its second registration: E's key and N's earlier one go; a confirmation
        // drops the key it replaces again.
        try later.tag(keyID: first, registration: "R1")
        #expect(try stored(store).registrations == [fake.keyID(3): "R2"]) // only a pending key is tagged
        try later.settle(identity: 1, registration: "R2")
        let settled = try stored(store)
        #expect(settled.current == fake.keyID(3) && settled.earlier.isEmpty && settled.parked.isEmpty && !settled.keepsReplaced)
        #expect(try !later.nextCandidate())
        try later.confirm(keyID: try attested(later))
        #expect(try stored(store).earlier.isEmpty)
    }

    @Test func aRegisterOfNAgainWhoseAnswerIsLostAssertsWithItsOwnNewKey() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        // N confirmed for its first recovery (key 2), then registered again (key 3), the answer never read: nothing confirms key 3.
        _ = try nRegisteredTwice(key)
        // The open of the new recovery asserts with key 3, the key its registration bound; key 2 stays a candidate.
        #expect(try asserted(key) == fake.keyID(3))
        let record = try stored(store)
        #expect(record.current == nil && record.pending == [fake.keyID(3)] && record.earlier == [fake.keyID(2)])
        // An unlock refused for its assertion tries key 2 next, then nothing is left.
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(2))
        #expect(try !key.nextCandidate())
        // E is untouched, and its own register was never marked: a new attestation of E keeps its current key in use.
        try key.use(identity: 0)
        #expect(try asserted(key) == fake.keyID(1))
        _ = try attested(key)
        #expect(try asserted(key) == fake.keyID(1))
        // The mark is N's and survives a later process.
        let later = make(fake, store)
        try later.use(identity: 1)
        #expect(try stored(store).keepsReplaced)
    }

    @Test func nsUnlockTriesItsNewestKeyFirstAndAnEarlierOneThatOpensDoesNotReplaceIt() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        let (_, second) = try nRegisteredTwice(key)
        try key.confirm(keyID: second)
        // The newest key (3) first; refused, the earlier one (2), which opens.
        #expect(try asserted(key) == fake.keyID(3))
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(2))
        try key.confirmUnlocked()
        // IOS-PLAN 0.1.38 §4.9: that unlock binds the newest key in the vault's header; later unlocks use the newest again.
        let record = try stored(store)
        #expect(record.current == fake.keyID(3) && record.earlier == [fake.keyID(2)])
        #expect(try asserted(key) == fake.keyID(3))
        // A pending key of the current registration that opens (the applied copy's) is the bound one: it is confirmed.
        let copies = make(FakeAppAttest(), MemoryKeyIDStore())
        try copies.confirm(keyID: try attested(copies))
        try copies.use(identity: 1)
        try copies.keepReplacedKeys()
        _ = try attested(copies)
        _ = try attested(copies)
        #expect(try asserted(copies) == fake.keyID(3))
        #expect(try copies.nextCandidate())
        #expect(try asserted(copies) == fake.keyID(2))
        try copies.confirmUnlocked()
        #expect(try asserted(copies) == fake.keyID(2))
        // Without a register again, an unlock that opens with a pending key confirms it, as before.
        let other = make(FakeAppAttest(), MemoryKeyIDStore())
        _ = try attested(other)
        _ = try attested(other)
        #expect(try other.nextCandidate())
        try other.confirmUnlocked()
        #expect(try asserted(other) == fake.keyID(1))
    }

    @Test func aRepeatThatWasNeverConfirmedKeepsEveryKeyOfN() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        try key.confirm(keyID: try attested(key))
        try key.use(identity: 1)
        try key.keepReplacedKeys()
        // Two registers whose answers were lost (pending), then a third confirmed: the two stay as earlier ones.
        _ = try attested(key)
        _ = try attested(key)
        try key.confirm(keyID: try attested(key))
        #expect(try asserted(key) == fake.keyID(4))
        // A refused assertion tries them, newest first, and an accepted one is the bound key, the others kept.
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(3))
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(2))
        try key.confirmInUse()
        #expect(try asserted(key) == fake.keyID(2))
        try key.use(identity: 0)
        #expect(try asserted(key) == fake.keyID(1))
    }

    @Test func theUnlockOfNTriesTheEarlierRegistrationsKeyWhenTheVaultRefusesTheNewest() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        let (_, second) = try nRegisteredTwice(key)
        try key.confirm(keyID: second)
        // The vault's binding is the first registration's (an open resumed with step 2 stored): the unlock with key 3 is refused
        // for its assertion, and key 2 is tried; nothing is left after it.
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(2))
        try key.confirmInUse()
        #expect(try asserted(key) == fake.keyID(2))
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(3))
        #expect(try !key.nextCandidate())
    }

    @Test func withoutARegisterAgainAConfirmationDropsTheKeyItReplacesAsBefore() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        try key.confirm(keyID: try attested(key))
        try key.confirm(keyID: try attested(key))
        #expect(try asserted(key) == fake.keyID(2))
        // A confirmed key, no earlier ones: a refused assertion has nothing else to try.
        #expect(try !key.nextCandidate())
    }

    @Test func aForgetDropsTheEarlierKeysAndTheirKeeping() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        let (_, second) = try nRegisteredTwice(key)
        try key.confirm(keyID: second)
        try key.resetIdentities()
        let record = try stored(store)
        #expect(record.active == 0 && record.current == fake.keyID(1) && record.earlier.isEmpty && !record.keepsReplaced)
    }

    // MARK: - The binding after the handshake (IOS-PLAN 0.1.39 §4.9)

    /// E's key 1; N registered for R1 with key 2 (confirmed) and again for R2 with key 3 (confirmed), each tagged before its POST.
    func nRegisteredTwiceTagged(_ key: AppAttestKey) throws {
        try key.confirm(keyID: try attested(key))
        try key.use(identity: 1)
        try key.keepReplacedKeys()
        for rid in ["R1", "R2"] {
            let k = try attested(key)
            try key.tag(keyID: k, registration: rid)
            try key.confirm(keyID: k)
        }
    }

    @Test func theHandshakeKeepsTheKeyOfTheRegistrationItsCtxNamedNotTheOneThatAnsweredTheOk() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        try nRegisteredTwiceTagged(key)
        #expect(try stored(store).registrations == [fake.keyID(2): "R1", fake.keyID(3): "R2"])
        // The lost-ok unlock: key 3 refused, key 2 opens (it stays an earlier key); the handshake with `ctx` R2 completes: the
        // binding is key 3, and key 2 goes.
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(2))
        try key.confirmUnlocked()
        let later = make(fake, store)
        try later.settle(identity: 1, registration: "R2")
        let record = try stored(store)
        #expect(record.current == fake.keyID(3) && record.pending.isEmpty && record.earlier.isEmpty && record.parked.isEmpty)
        #expect(record.registrations.isEmpty && !record.keepsReplaced)
        #expect(try asserted(later) == fake.keyID(3) && !later.nextCandidate())
    }

    @Test func aHandshakeWithAnEarlierRegistrationsCtxKeepsThatRegistrationsKey() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        try nRegisteredTwiceTagged(key)
        // The invitation was R1's (R2's open stored nothing): the handshake with `ctx` R1 completes, key 2 is the binding.
        try key.settle(identity: 1, registration: "R1")
        let record = try stored(store)
        #expect(record.current == fake.keyID(2) && record.pending.isEmpty && record.earlier.isEmpty && record.parked.isEmpty)
        #expect(try asserted(key) == fake.keyID(2))
        // Settled again (a kill before the rule's record was written): nothing changes.
        try key.settle(identity: 1, registration: "R1")
        #expect(try stored(store) == record)
    }

    @Test func aRegistrationWithTwoKeysKeepsBothUntilAnUnlockConfirmsOne() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        try key.confirm(keyID: try attested(key))
        try key.use(identity: 1)
        try key.keepReplacedKeys()
        // R1: key 2 confirmed. R2: keys 3 and 4 (a register sealed again), neither confirmed.
        let k2 = try attested(key)
        try key.tag(keyID: k2, registration: "R1")
        try key.confirm(keyID: k2)
        for _ in 0..<2 { try key.tag(keyID: try attested(key), registration: "R2") }
        try key.settle(identity: 1, registration: "R2")
        let record = try stored(store)
        #expect(record.current == nil && record.pending == [fake.keyID(3), fake.keyID(4)] && record.earlier.isEmpty)
        // The newest first; refused, the other, whose `ok` confirms it.
        #expect(try asserted(key) == fake.keyID(4))
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(3))
        try key.confirmUnlocked()
        #expect(try stored(store).current == fake.keyID(3) && stored(store).pending.isEmpty)
    }

    @Test func aCtxNoKeyWasRegisteredForForgetsNoneOfTheIdentitysKeys() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        try nRegisteredTwiceTagged(key)
        // E's own `recovery_id`, or a handshake from a build before the tags: E's keys go, N's all stay.
        for ctx in ["E", nil] as [String?] {
            try key.settle(identity: 1, registration: ctx)
            let record = try stored(store)
            #expect(record.current == fake.keyID(3) && record.earlier == [fake.keyID(2)] && record.parked.isEmpty && !record.keepsReplaced)
        }
        #expect(try key.nextCandidate())
        #expect(try asserted(key) == fake.keyID(2))
    }

    @Test func aTagOutlivesNoKey() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        let a = try attested(key)
        try key.tag(keyID: a, registration: "R1")
        let b = try attested(key)
        try key.tag(keyID: b, registration: "R1")
        try key.discard(keyID: a)
        #expect(try stored(store).registrations == [fake.keyID(2): "R1"])
        // A later process reads the tags.
        let later = make(fake, store)
        try later.confirm(keyID: b)
        #expect(try stored(store).registrations == [fake.keyID(2): "R1"])
    }

    @Test func theSlotsOfTheTwoIdentitiesAreDistinct() {
        let first = KeySlot.slots(of: .first), second = KeySlot.slots(of: .second)
        #expect(Set(first).isDisjoint(with: second) && first.count == 3 && second.count == 3)
        #expect(Set(KeySlot.allCases).count == IdentitySet.limit * 3 && Set(first + second).isSubset(of: Set(KeySlot.allCases)))
        for slot in KeySlot.allCases {
            #expect(slot.of(.second).of(.first) == slot.of(.first) && slot.of(.first).of(.second) == slot.of(.second))
            #expect(first.contains(slot.of(.first)) && second.contains(slot.of(.second)))
        }
        #expect(KeySlot.identity.of(.second) == .identity2 && KeySlot.kem2.of(.first) == .kem && KeySlot.relay.of(.first) == .relay)
        #expect(IdentitySet.first.next == .second && IdentitySet(rawValue: IdentitySet.limit - 1).next == nil)
    }

    @Test func eachIdentityHasKeysOfItsOwn() throws {
        let keys = DeviceKeys(wrapper: SeedWrapper(source: SoftwareSeedWrapKeySource()), store: InMemoryWrappedKeyStore())
        for set in IdentitySet.all { for slot in KeySlot.slots(of: set) { try keys.generate(slot) } }
        let a = try keys.ed25519(.identity), b = try keys.ed25519(.identity2)
        #expect(a.publicKey != b.publicKey)
        #expect(try keys.kem(.kem).publicKey.bytes != keys.kem(.kem2).publicKey.bytes)
        #expect(try keys.ed25519(.relay).publicKey != keys.ed25519(.relay2).publicKey)
    }
}
