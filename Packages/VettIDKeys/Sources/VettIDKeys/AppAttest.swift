import Foundation
import VettIDCrypto

/// A failure of App Attest. Carries no key id, attestation or assertion (IOS-PLAN §6.2, "Never logged").
public enum AppAttestError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Apple's App Attest service could not be reached at an attestation (`DCError.serverUnavailable` after the retries,
    /// or no answer in time): nothing was sent; "VettID couldn't reach Apple…" (IOS-PLAN §14).
    case appleUnreachable
    /// The attested key is gone (`DCError.invalidKey` at an assertion: a reinstall, a restore): IOS-PLAN §6.2's "this
    /// phone no longer holds the keys" path.
    case keyGone
    /// ``AppAttestKey/maxPending`` attested keys are unconfirmed, any of which the vault may hold: a new attestation is
    /// refused before anything is made or sent, and none is dropped (chosen; not in the spec).
    case pendingFull
    /// Any other refusal (`DCError.unknownSystemFailure`, `.invalidInput`, a local call without an answer in time):
    /// nothing was sent; the member tries again. Never a loss of the keys.
    case failed(Int)

    public var description: String {
        switch self {
        case .appleUnreachable: "app attest: Apple unreachable"
        case .keyGone: "app attest: key gone"
        case .pendingFull: "app attest: too many unconfirmed keys"
        case .failed(let code): "app attest: failed (\(code))"
        }
    }
}

/// The App Attest key of the device attestation (VAULT-MESSAGING §11.7; IOS-PLAN §6.1, §6.2). Mirrors vettid-android
/// `KeystoreAttester` and `DeviceAttestationKey`, except for the old key (below; chosen; not in the spec: Android
/// replaces its key at once).
///
/// - ``attest(clientDataHash:)`` makes a fresh key (one key per request, so pending, confirmed and discarded keys stay apart), attests it with the challenge
///   as clientDataHash, and keeps its key id in the keychain (`AfterFirstUnlockThisDeviceOnly`, never synchronizable)
///   as **pending**, before the request that carries it is sent. The **current** key, the one the vault bound, stays.
///   The request that carried it records the key id with itself (an enrollment's in its kept request,
///   `AltState.EnrollAttempt`), so that whatever proves which request the vault took confirms that key
///   (``confirm(keyID:)``): the request's `ok`, or its `vault.enrolled`. A request that certainly bound nothing (a
///   sealed refusal, one that never reached the vault's processing) discards its key (``discard(keyID:)``).
/// - No pending key is dropped while it may be the bound one: with ``maxPending`` of them a new attestation is refused
///   (``AppAttestError/pendingFull``).
/// - ``assert(clientDataHash:)`` asserts with the current key, or without one the newest pending key. An unlock the
///   vault refuses for its assertion while no key is confirmed moves to the next untried pending key, newest first, then to
///   the keys of an identity's earlier registrations (``nextCandidate()``); an accepted one confirms the key in use
///   (``confirmInUse()``).
/// - Calls are serialized, so two assertions of one request are made one after the other with increasing counters
///   (§11.10.3). They block the calling thread while App Attest answers (the ``Attester`` protocol is synchronous):
///   never on the main thread, which is checked.
/// - `isSupported == false`: ``KeysError/noSecureHardware`` before anything is made or sent.
/// - `DCError.serverUnavailable`: retried after each of ``backoff``, then ``AppAttestError/appleUnreachable``.
/// - `DCError.invalidKey` at attestation: one fresh key and one more try (chosen; not in the spec), then
///   ``AppAttestError/failed(_:)``; at an assertion ``AppAttestError/keyGone``. `DCError.invalidInput` is never a loss.
/// - No key id kept: ``KeysError/missing(_:)`` when protected data was available around the lookup, otherwise
///   ``KeysError/unavailable(_:)`` (IOS-PLAN §6.3).
/// - A record that does not parse may name the bound key: an assertion fails with ``KeysError/corrupt(_:)``, and an
///   attestation starts a fresh record only when ``mayStartOver`` says no vault can hold one of its keys, the damaged
///   one kept aside (chosen; not in the spec).
public final class AppAttestKey: KeyEraser, @unchecked Sendable {
    public static let account = "vettid.appattest.key_id.v1"
    /// Where a damaged record is kept aside.
    public static let asideAccount = "vettid.appattest.key_id.aside.v1"
    /// The waits before each retry of a `serverUnavailable` answer, in seconds (chosen; not in the spec).
    public static let defaultBackoff: [Double] = [1, 2, 4]
    /// The most unconfirmed keys kept (chosen; not in the spec).
    public static let maxPending = 8
    static let what = "app attest key"
    static let hashSize = 32

    private let service: any AppAttestService
    private let store: any KeyIDStore
    private let aside: any KeyIDStore
    private let mayStartOver: @Sendable () -> Bool
    private let backoff: [Double]
    private let sleep: @Sendable (Double) -> Void
    private let checkThread: Bool
    private let lock = NSLock()
    /// The pending key tried after a refusal (``nextCandidate()``), and the ones tried, in this process.
    private var override: String?
    private var tried: Set<String> = []

    /// [aside] keeps a damaged record; [mayStartOver] says whether no vault can hold one of the record's keys (no
    /// enrollment made or under way here); [checkThread] refuses the main thread (off only for unit tests over a fake).
    public init(
        service: any AppAttestService, keyID: any KeyIDStore, aside: any KeyIDStore,
        mayStartOver: @escaping @Sendable () -> Bool,
        backoff: [Double] = AppAttestKey.defaultBackoff,
        sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }, checkThread: Bool = true
    ) {
        self.service = service
        store = keyID
        self.aside = aside
        self.mayStartOver = mayStartOver
        self.backoff = backoff
        self.sleep = sleep
        self.checkThread = checkThread
    }

    public var isSupported: Bool { service.isSupported }

    /// A fresh key attested over [clientDataHash] (the 32-byte challenge of §11.7), kept as pending once attested.
    public func attest(clientDataHash: [UInt8]) throws -> DeviceAttest {
        if checkThread { dispatchPrecondition(condition: .notOnQueue(.main)) }
        guard service.isSupported else { throw KeysError.noSecureHardware }
        guard clientDataHash.count == Self.hashSize else { throw CryptoError.format("clientDataHash") }
        lock.lock()
        defer { lock.unlock() }
        var record = try recordForAttestation()
        guard record.pending.count < Self.maxPending else { throw AppAttestError.pendingFull }
        let (id, attestation) = try attestFresh(clientDataHash)
        guard let raw = Data(base64Encoded: id), !raw.isEmpty else { throw AppAttestError.failed(-1) }
        // (IOS-PLAN 0.1.35 §4.9) Each registration's binding stays tied to its own key: an identity registered again asserts with
        // the new key, and its earlier ones stay candidates.
        let before = record.current
        record.attesting()
        if record.current != before { (override, tried) = (nil, []) }
        record.pending.append(id)
        try store.write(record.encoded())
        return try DeviceAttest.iosAttestation(keyID: Array(raw), attestation: attestation)
    }

    private func attestFresh(_ clientDataHash: [UInt8]) throws -> (String, [UInt8]) {
        let id = try call { try service.generateKey() }
        do {
            return (id, try call { try service.attestKey(id, clientDataHash: clientDataHash) })
        } catch AppAttestServiceError.invalidKey {
            let again = try call { try service.generateKey() }
            do {
                return (again, try call { try service.attestKey(again, clientDataHash: clientDataHash) })
            } catch AppAttestServiceError.invalidKey {
                throw AppAttestError.failed(3)
            }
        }
    }

    /// The kept key's assertion over [clientDataHash] (an unlock's challenge, or SHA-256 of an approval string).
    public func assert(clientDataHash: [UInt8]) throws -> DeviceAssertion {
        if checkThread { dispatchPrecondition(condition: .notOnQueue(.main)) }
        guard service.isSupported else { throw KeysError.noSecureHardware }
        guard clientDataHash.count == Self.hashSize else { throw CryptoError.format("clientDataHash") }
        lock.lock()
        defer { lock.unlock() }
        guard let id = inUse(try readRecord(missingIsEmpty: false)) else { throw KeysError.missing(Self.what) }
        do {
            // Made on the phone: no answer in time is not Apple unreachable.
            return try DeviceAssertion.iosAssertion(try call(local: true) {
                try service.generateAssertion(id, clientDataHash: clientDataHash)
            })
        } catch AppAttestServiceError.invalidKey {
            throw AppAttestError.keyGone
        }
    }

    /// The vault bound [keyID] (raw bytes): it becomes the current key, the others are forgotten. A key that is not
    /// pending changes nothing.
    public func confirm(keyID: [UInt8]) throws {
        try update { record in
            guard let id = record.pending.first(where: { Self.raw($0) == keyID }) else { return }
            record.promote(id)
        }
    }

    /// The request that carried [keyID] certainly did not bind it.
    public func discard(keyID: [UInt8]) throws {
        try update { record in
            record.pending.removeAll { Self.raw($0) == keyID }
        }
    }

    /// With every pending slot taken, forgets the pending keys outside [keyIDs] (raw bytes): no kept request names them,
    /// so no `vault.enrolled` can bind them any more. Nothing changes while a slot is free.
    public func prune(keeping keyIDs: [[UInt8]]) throws {
        try update { record in
            guard record.pending.count >= Self.maxPending else { return }
            record.pending.removeAll { id in !keyIDs.contains { Self.raw(id) == $0 } }
        }
    }

    /// An assertion of the key in use was accepted: without a current key, or when it is an earlier one, it is the bound one.
    public func confirmInUse() throws {
        try update { record in
            guard let id = inUse(record), id != record.current else { return }
            record.promote(id)
        }
    }

    /// An assertion of the key in use was refused: while no key is confirmed, the next untried pending key, newest first; then,
    /// for an identity registered again (IOS-PLAN 0.1.35 §4.9), the keys of its earlier registrations, newest first (chosen; not
    /// in the spec: the vault's binding may be an earlier registration's).
    public func nextCandidate() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let record = try readRecord(missingIsEmpty: false)
        let candidates = (record.current == nil ? Array(record.pending.reversed()) : []) + record.earlier.reversed()
        if let used = inUse(record) { tried.insert(used) }
        override = candidates.first { !tried.contains($0) }
        return override != nil
    }

    /// (IOS-PLAN 0.1.33 §4.9) The device identity [n] is in use: its keys are the current and pending ones from now on, those of
    /// the identity that was in use are kept as they are.
    public func use(identity n: Int) throws {
        try update { $0.use(n) }
    }

    /// (§4.9) The identity [n]'s keys are forgotten (App Attest keys cannot be deleted; a forgotten one is never used again):
    /// once the vault answered `ok` and the other identity's pairing completed. The identity in use is never forgotten here.
    public func forget(identity n: Int) throws {
        try update { record in
            guard n != record.active else { return }
            record.parked.removeValue(forKey: n)
        }
    }

    /// (IOS-PLAN 0.1.35 §4.9) The identity in use is registered again (the new identity, reused for another recovery): from now
    /// on, for this identity only, a new attestation is the key in use with the current one kept as an earlier one, and a
    /// confirmation keeps the keys it replaces, until ``settle(identity:)`` or ``resetIdentities()``.
    public func keepReplacedKeys() throws {
        try update { $0.keepsReplaced = true }
    }

    /// (§4.9) The handshake completed with the identity [n]: it is in use, and the keys of every other identity are forgotten. The
    /// keys of its own earlier registrations stay candidates of its unlock (chosen; not in the spec: kept until the vault's binding
    /// at the handshake is confirmed).
    public func settle(identity n: Int) throws {
        try update { record in
            record.use(n)
            record.parked = [:]
            record.keepsReplaced = false
        }
    }

    /// (§4.9) A forget: the first identity is in use, with its own keys (the second's, and any earlier ones, are gone).
    public func resetIdentities() throws {
        try update { record in
            let first = record.active == 0 ? nil : record.parked[0]
            if record.active != 0 {
                record.current = first?.current
                record.pending = first?.pending ?? []
            }
            record.active = 0
            record.parked = [:]
            record.earlier = []
            record.keepsReplaced = false
        }
    }

    /// Whether a key id is kept, classified by IOS-PLAN §6.3.
    public func lookup() -> ItemLookup<Void> {
        store.lookup().map { _ in () }
    }

    /// Forgets the key ids, the damaged record kept aside included (App Attest keys cannot be deleted; a forgotten one
    /// is never used again).
    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        override = nil
        tried = []
        try store.delete()
        try aside.delete()
    }

    private func inUse(_ record: KeyIDRecord) -> String? {
        if let o = override, (record.current == nil && record.pending.contains(o)) || record.earlier.contains(o) { return o }
        return record.inUse
    }

    private func update(_ change: (inout KeyIDRecord) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var record = try readRecord(missingIsEmpty: true)
        let before = record
        change(&record)
        guard record != before else { return }
        if record.current != before.current || record.active != before.active {
            override = nil
            tried = []
        }
        try store.write(record.encoded())
    }

    private func readRecord(missingIsEmpty: Bool) throws -> KeyIDRecord {
        switch store.lookup() {
        case .found(let bytes):
            guard let r = KeyIDRecord(bytes) else { throw KeysError.corrupt(Self.what) }
            return r
        case .missing:
            if missingIsEmpty { return KeyIDRecord(current: nil, pending: []) }
            throw KeysError.missing(Self.what)
        case .unavailable:
            throw KeysError.unavailable(Self.what)
        }
    }

    /// The record an attestation adds to; a damaged one is set aside for a fresh one only when no vault can hold one of
    /// its keys.
    private func recordForAttestation() throws -> KeyIDRecord {
        guard case .found(let bytes) = store.lookup(), KeyIDRecord(bytes) == nil else {
            return try readRecord(missingIsEmpty: true)
        }
        guard mayStartOver() else { throw KeysError.corrupt(Self.what) }
        try aside.write(bytes)
        return KeyIDRecord(current: nil, pending: [])
    }

    static func raw(_ id: String) -> [UInt8]? { Data(base64Encoded: id).map { Array($0) } }

    /// [body], retried after each wait of ``backoff`` while Apple is unavailable; other answers mapped. An invalid key
    /// is passed on as it is, for the caller to decide. [local]: a call App Attest answers on the phone, whose time-out
    /// is a plain failure.
    private func call<T>(local: Bool = false, _ body: () throws -> T) throws -> T {
        var waits = backoff[...]
        while true {
            do {
                return try body()
            } catch AppAttestServiceError.serverUnavailable {
                guard let wait = waits.popFirst() else { throw AppAttestError.appleUnreachable }
                sleep(wait)
            } catch AppAttestServiceError.timedOut where local {
                throw AppAttestError.failed(-2)
            } catch let e as AppAttestServiceError {
                throw Self.map(e)
            }
        }
    }

    static func map(_ e: AppAttestServiceError) -> any Error {
        switch e {
        case .featureUnsupported: KeysError.noSecureHardware
        case .invalidKey: e
        case .serverUnavailable, .timedOut: AppAttestError.appleUnreachable
        case .invalidInput: AppAttestError.failed(2)
        case .other(let code): AppAttestError.failed(code)
        }
    }
}
