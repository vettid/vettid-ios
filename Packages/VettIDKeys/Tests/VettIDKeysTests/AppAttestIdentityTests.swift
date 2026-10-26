import Foundation
import Testing
import VettIDCrypto
@testable import VettIDKeys
import VettIDKeysTesting

/// A phone that could not tell holds two device identities (IOS-PLAN 0.1.35 §4.9), and the vault bound each one's own App Attest
/// key at its register: the keys of the identity in use are the current and pending ones, the other's wait untouched. N is
/// registered again with a new key for each further recovery, and its earlier keys are kept (after the handshake too, until the
/// vault's binding there is confirmed).
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

    // MARK: - N registered again (IOS-PLAN 0.1.35 §4.9)

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
        // The second register is confirmed: its key is in use, and the first registration's key is kept beside it.
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
        // The handshake completes with N: E's key goes; N's earlier one stays a candidate of its unlock (kept until the vault's
        // binding at the handshake is confirmed), and a confirmation no longer keeps the key it replaces.
        try later.settle(identity: 1)
        let settled = try stored(store)
        #expect(settled.current == fake.keyID(3) && settled.earlier == [fake.keyID(2)] && settled.parked.isEmpty && !settled.keepsReplaced)
        #expect(try later.nextCandidate())
        #expect(try asserted(later) == fake.keyID(2))
        try later.confirm(keyID: try attested(later))
        let after = try stored(store)
        #expect(after.current == fake.keyID(4) && after.earlier == [fake.keyID(2)])
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
