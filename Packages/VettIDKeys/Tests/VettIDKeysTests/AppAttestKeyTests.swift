import Foundation
import Testing
import VettIDCrypto
@testable import VettIDKeys
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// The App Attest key's rules (IOS-PLAN §6.2) over a fake App Attest: the device tests (AppTests) run the real one.
@Suite struct AppAttestKeyTests {
    let challenge = [UInt8](repeating: 7, count: 32)

    func make(_ fake: FakeAppAttest, _ store: MemoryKeyIDStore = MemoryKeyIDStore(), backoff: [Double] = [1, 2, 4],
              waits: Waits = Waits(), aside: MemoryKeyIDStore = MemoryKeyIDStore(), startOver: Bool = false) -> AppAttestKey {
        AppAttestKey(
            service: fake, keyID: store, aside: aside, mayStartOver: { startOver }, backoff: backoff, sleep: { waits.add($0) },
            checkThread: false
        )
    }

    func assertedKey(_ key: AppAttestKey) throws -> String {
        guard case .ios(let assertion) = try key.assert(clientDataHash: challenge) else { throw TestFailure("not iOS") }
        return String(bytes: assertion.dropLast(32), encoding: .utf8) ?? ""
    }

    func keyID(_ attest: DeviceAttest) throws -> [UInt8] {
        guard case .ios(let id, _) = attest else { throw TestFailure("not an iOS attestation") }
        return id
    }

    @Test func anAttestationMakesAFreshPendingKey() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        let first = try key.attest(clientDataHash: challenge)
        guard case .ios(let id1, let att1) = first else { throw TestFailure("not an iOS attestation") }
        #expect(id1 == Bytes.sha256([1]))
        #expect(att1 == [0xA1] + challenge)
        // Without a confirmed key, the newest pending one asserts.
        #expect(try assertedKey(key) == fake.keyID(1))
        #expect(try keyID(key.attest(clientDataHash: challenge)) == Bytes.sha256([2]), "each attestation is a new key")
        #expect(try assertedKey(key) == fake.keyID(2))
    }

    /// IOS-PLAN §6.2 (chosen; not in the spec): the key the vault accepted stays in use until another is confirmed;
    /// a refused attestation never displaces it.
    @Test func theConfirmedKeyStaysUntilAnotherIsConfirmed() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        let a = try keyID(key.attest(clientDataHash: challenge))
        try key.confirm(keyID: a)
        let b = try keyID(key.attest(clientDataHash: challenge))
        #expect(try assertedKey(key) == fake.keyID(1), "an unconfirmed attestation does not replace the current key")
        try key.discard(keyID: b)
        #expect(try assertedKey(key) == fake.keyID(1))
        let c = try keyID(key.attest(clientDataHash: challenge))
        try key.confirm(keyID: c)
        #expect(try assertedKey(key) == fake.keyID(3))
        // A later process reads the same record.
        #expect(try assertedKey(make(fake, store)) == fake.keyID(3))
        // Confirming a key that is not pending changes nothing.
        try key.confirm(keyID: a)
        #expect(try assertedKey(key) == fake.keyID(3))
    }

    /// An enrollment whose first answer was lost: key A sent, the retry's key B refused (`vault_exists`): A, which the
    /// vault may hold, is the one that asserts.
    @Test func aLostAnswerThenARefusedRetryKeepsTheFirstKey() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        _ = try key.attest(clientDataHash: challenge)
        let b = try keyID(key.attest(clientDataHash: challenge))
        try key.discard(keyID: b)
        #expect(try assertedKey(key) == fake.keyID(1))
    }

    /// No pending key is dropped while it may be the bound one: the ninth attestation is refused before anything is made.
    @Test func atMostEightPendingKeysAndNoneDropped() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        for _ in 0 ..< 8 { _ = try key.attest(clientDataHash: challenge) }
        let calls = fake.calls
        #expect(throws: AppAttestError.pendingFull) { _ = try key.attest(clientDataHash: challenge) }
        #expect(fake.calls == calls, "nothing asked of App Attest")
        guard case .found(let bytes) = store.lookup(), let r = KeyIDRecord(bytes) else { throw TestFailure("no record") }
        #expect(r.current == nil && r.pending == (1 ... 8).map { fake.keyID(UInt8($0)) })
        // A confirmation frees them.
        try key.confirm(keyID: Bytes.sha256([3]))
        _ = try key.attest(clientDataHash: challenge)
    }

    /// With every slot taken, the keys no kept request names are forgotten; while a slot is free nothing changes.
    @Test func aFullRecordForgetsTheKeysNoRequestNames() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        for _ in 0 ..< 7 { _ = try key.attest(clientDataHash: challenge) }
        try key.prune(keeping: [])
        _ = try key.attest(clientDataHash: challenge)
        #expect(throws: AppAttestError.pendingFull) { _ = try key.attest(clientDataHash: challenge) }
        try key.prune(keeping: [Bytes.sha256([7]), Bytes.sha256([8])])
        #expect(try assertedKey(key) == fake.keyID(8))
        _ = try key.attest(clientDataHash: challenge)
        #expect(try assertedKey(key) == fake.keyID(9))
        #expect(try key.nextCandidate() && assertedKey(key) == fake.keyID(8))
        #expect(try key.nextCandidate() && assertedKey(key) == fake.keyID(7))
        #expect(try !key.nextCandidate(), "keys 1 to 6 are forgotten")
    }

    /// A phone registered for a recovery never starts a damaged record over.
    @Test func theStartOverGate() {
        let g = AttestStartOver()
        #expect(!g.value, "no until the account record was read")
        g.set(true)
        #expect(g.value)
        g.set(recovering: true)
        #expect(!g.value)
        g.set(recovering: false)
        #expect(g.value)
    }

    /// Without a confirmed key, an assertion refused by the vault moves to the next untried pending key, newest first,
    /// each once; an accepted one confirms the key in use.
    @Test func aRefusedAssertionTriesTheOtherPendingKeys() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        for _ in 0 ..< 3 { _ = try key.attest(clientDataHash: challenge) }
        #expect(try assertedKey(key) == fake.keyID(3))
        #expect(try key.nextCandidate())
        #expect(try assertedKey(key) == fake.keyID(2))
        #expect(try key.nextCandidate())
        #expect(try assertedKey(key) == fake.keyID(1))
        #expect(try !key.nextCandidate(), "each key once")
        // Key 2 was the bound one, as an accepted unlock shows.
        let fresh = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let other = make(fresh, store)
        for _ in 0 ..< 3 { _ = try other.attest(clientDataHash: challenge) }
        #expect(try other.nextCandidate())
        try other.confirmInUse()
        guard case .found(let bytes) = store.lookup(), let r = KeyIDRecord(bytes) else { throw TestFailure("no record") }
        #expect(r == KeyIDRecord(current: fresh.keyID(2), pending: []))
        #expect(try !other.nextCandidate(), "a confirmed key is never switched")
        try other.confirmInUse()
        #expect(try assertedKey(other) == fresh.keyID(2))
    }

    /// A damaged record may name the bound key: an assertion is a loss of the keys, an attestation refused, unless no
    /// vault can hold one of its keys; the damaged record is then kept aside.
    @Test func aDamagedRecord() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let aside = MemoryKeyIDStore()
        let damaged = Array("not base64!".utf8)
        try store.write(damaged)
        #expect(throws: KeysError.corrupt("app attest key")) { _ = try make(fake, store, aside: aside).assert(clientDataHash: challenge) }
        #expect(throws: KeysError.corrupt("app attest key")) { _ = try make(fake, store, aside: aside).attest(clientDataHash: challenge) }
        #expect(fake.calls == 0)
        let fresh = make(fake, store, aside: aside, startOver: true)
        _ = try fresh.attest(clientDataHash: challenge)
        #expect(aside.lookup() == .found(damaged))
        #expect(try assertedKey(fresh) == fake.keyID(1))
        try fresh.deleteAll()
        #expect(aside.lookup() == .missing)
    }

    /// A failure to record a confirmation or a discard is thrown, not swallowed.
    @Test func aFailedWriteIsThrown() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        let a = try keyID(key.attest(clientDataHash: challenge))
        store.failWrites = true
        #expect(throws: KeysError.unavailable("memory")) { try key.confirm(keyID: a) }
        #expect(throws: KeysError.unavailable("memory")) { try key.discard(keyID: a) }
    }

    /// The earlier format, a bare key id, reads as the current key; anything else unreadable is corrupt.
    @Test func theRecordFormat() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        try store.write(Array(fake.keyID(9).utf8))
        #expect(try assertedKey(make(fake, store)) == fake.keyID(9))
        try store.write(Array("not base64!".utf8))
        #expect(throws: KeysError.corrupt("app attest key")) { _ = try make(fake, store).assert(clientDataHash: challenge) }
        try store.write(Array(#"{"v":2,"pending":[]}"#.utf8))
        #expect(KeyIDRecord(Array(#"{"v":2,"pending":[]}"#.utf8)) == nil)
        let r = KeyIDRecord(current: fake.keyID(1), pending: [fake.keyID(2)])
        #expect(KeyIDRecord(try r.encoded()) == r)
    }

    @Test func aClientDataHashIsThirtyTwoBytes() {
        let key = make(FakeAppAttest())
        #expect(throws: CryptoError.self) { _ = try key.attest(clientDataHash: [1]) }
        #expect(throws: CryptoError.self) { _ = try key.assert(clientDataHash: [1]) }
    }

    @Test func noAppAttestRefusesBeforeAnythingIsMade() {
        let fake = FakeAppAttest()
        fake.supported = false
        let key = make(fake)
        #expect(throws: KeysError.noSecureHardware) { _ = try key.attest(clientDataHash: challenge) }
        #expect(throws: KeysError.noSecureHardware) { _ = try key.assert(clientDataHash: challenge) }
        #expect(fake.calls == 0)
    }

    /// `serverUnavailable` is retried after each wait, then "VettID couldn't reach Apple".
    @Test func appleUnavailableIsRetriedThenReported() throws {
        let fake = FakeAppAttest()
        let waits = Waits()
        let key = make(fake, backoff: [1, 2], waits: waits)
        fake.failures = [.serverUnavailable, .serverUnavailable]
        _ = try key.attest(clientDataHash: challenge)
        #expect(waits.all == [1, 2])
        fake.failures = [.serverUnavailable, .serverUnavailable, .serverUnavailable]
        #expect(throws: AppAttestError.appleUnreachable) { _ = try key.attest(clientDataHash: challenge) }
        fake.failures = [.timedOut]
        #expect(throws: AppAttestError.appleUnreachable) { _ = try key.attest(clientDataHash: challenge) }
        // An assertion is made on the phone: no answer in time is a plain failure.
        fake.failures = [.timedOut]
        #expect(throws: AppAttestError.failed(-2)) { _ = try key.assert(clientDataHash: challenge) }
    }

    /// An attestation whose fresh key is refused tries once more with another, then fails (never a raw error); an
    /// assertion whose key is gone is the "no longer holds the keys" path; `invalidInput` is never a loss.
    @Test func anInvalidKey() throws {
        let fake = FakeAppAttest()
        let key = make(fake)
        fake.invalidAttest = 1
        #expect(try keyID(key.attest(clientDataHash: challenge)) == Bytes.sha256([2]))
        fake.invalidAttest = 2
        #expect(throws: AppAttestError.failed(3)) { _ = try key.attest(clientDataHash: challenge) }
        fake.invalidAssert = true
        #expect(throws: AppAttestError.keyGone) { _ = try key.assert(clientDataHash: challenge) }
        fake.invalidAssert = false
        fake.failures = [.invalidInput]
        #expect(throws: AppAttestError.failed(2)) { _ = try key.assert(clientDataHash: challenge) }
        fake.failures = [.invalidInput]
        #expect(throws: AppAttestError.failed(2)) { _ = try key.attest(clientDataHash: challenge) }
    }

    /// No key id: missing only when protected data says so (the store's own classification), and nothing is asked of Apple.
    @Test func noKeptKey() throws {
        let fake = FakeAppAttest()
        let store = MemoryKeyIDStore()
        let key = make(fake, store)
        #expect(throws: KeysError.missing("app attest key")) { _ = try key.assert(clientDataHash: challenge) }
        store.locked = true
        #expect(throws: KeysError.unavailable("app attest key")) { _ = try key.assert(clientDataHash: challenge) }
        #expect(throws: KeysError.unavailable("app attest key")) { _ = try key.attest(clientDataHash: challenge) }
        store.locked = false
        #expect(fake.calls == 0)
        _ = try key.attest(clientDataHash: challenge)
        try key.deleteAll()
        guard case .missing = key.lookup() else { throw TestFailure("a key id is still kept") }
    }

    @Test func otherAnswersAreMapped() {
        #expect(AppAttestKey.map(.featureUnsupported) as? KeysError == .noSecureHardware)
        #expect(AppAttestKey.map(.invalidInput) as? AppAttestError == .failed(2))
        #expect(AppAttestKey.map(.other(4)) as? AppAttestError == .failed(4))
        #expect(AppAttestKey.map(.timedOut) as? AppAttestError == .appleUnreachable)
        #expect("\(AppAttestError.appleUnreachable)" == "app attest: Apple unreachable")
        #expect("\(AppAttestError.keyGone)" == "app attest: key gone")
    }

    #if canImport(DeviceCheck)
    @Test func deviceCheckErrorsAreClassified() {
        let e = { (code: Int) in NSError(domain: DCErrorDomain, code: code) }
        #expect(DeviceCheckAppAttestService.classify(e(1)) == .featureUnsupported)
        #expect(DeviceCheckAppAttestService.classify(e(2)) == .invalidInput)
        #expect(DeviceCheckAppAttestService.classify(e(3)) == .invalidKey)
        #expect(DeviceCheckAppAttestService.classify(e(4)) == .serverUnavailable)
        #expect(DeviceCheckAppAttestService.classify(e(0)) == .other(0))
        #expect(DeviceCheckAppAttestService.classify(NSError(domain: "x", code: 3)) == .other(-1))
        #expect(DeviceCheckAppAttestService.classify(nil) == .other(-1))
    }
    #endif
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}

/// A fake App Attest: key n's id is base64(SHA-256([n])); an attestation is 0xA1 ‖ clientDataHash; an assertion is the
/// key id's UTF-8 ‖ clientDataHash.
final class FakeAppAttest: AppAttestService, @unchecked Sendable {
    private let lock = NSLock()
    private var made: UInt8 = 0
    private var count = 0
    var supported = true
    /// Answers given, one per call, before the calls succeed.
    var failures: [AppAttestServiceError] = []
    /// How many attestations answer `invalidKey`.
    var invalidAttest = 0
    var invalidAssert = false

    var isSupported: Bool { supported }
    var calls: Int { lock.withLock { count } }

    func keyID(_ n: UInt8) -> String { Data(Bytes.sha256([n])).base64EncodedString() }

    private func step() throws {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if !failures.isEmpty { throw failures.removeFirst() }
    }

    func generateKey() throws -> String {
        try step()
        lock.lock()
        defer { lock.unlock() }
        made += 1
        return keyID(made)
    }

    func attestKey(_ keyID: String, clientDataHash: [UInt8]) throws -> [UInt8] {
        try step()
        lock.lock()
        defer { lock.unlock() }
        if invalidAttest > 0 {
            invalidAttest -= 1
            throw AppAttestServiceError.invalidKey
        }
        return [0xA1] + clientDataHash
    }

    func generateAssertion(_ keyID: String, clientDataHash: [UInt8]) throws -> [UInt8] {
        try step()
        if lock.withLock({ invalidAssert }) { throw AppAttestServiceError.invalidKey }
        return Array(keyID.utf8) + clientDataHash
    }
}

/// The key id in memory; `locked` answers like a locked iPhone.
final class MemoryKeyIDStore: KeyIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: [UInt8]?
    var locked = false

    func lookup() -> ItemLookup<[UInt8]> {
        lock.lock()
        defer { lock.unlock() }
        if locked { return .unavailable }
        return value.map { .found($0) } ?? .missing
    }

    var failWrites = false

    func write(_ value: [UInt8]) throws {
        if failWrites { throw KeysError.unavailable("memory") }
        lock.withLock { self.value = value }
    }
    func delete() throws { lock.withLock { value = nil } }
}

final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}
