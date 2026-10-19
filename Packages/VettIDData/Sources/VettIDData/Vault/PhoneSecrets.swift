import CryptoKit
import Foundation
import VettIDCrypto
import VettIDKeys

/// The iPhone's unlock secret for a vault of release R (VAULT-MESSAGING §11.14.1 "On an iPhone", IOS-PLAN §6.3 and ID9):
/// phone keys `P` (Secure Enclave key-agreement keys from ``PhoneSecretSource``, each made for a `key_vault` and named by
/// its own key id) and, per epoch, a record `(key_vault, epoch, pub(E_e), check_e)` from which its `P` computes the
/// secret each time it is needed (``PhoneSecretIOS``). The secret itself is never stored; `priv(E_e)` is dropped once
/// the record is written.
///
/// - Every record is written **before** the request that carries its secret is built, and a retry reuses its record.
/// - A new key never overwrites one a record names, and nothing is deleted before a later record is confirmed: a new
///   epoch 1 (enrollment, transfer, recovery) waits as the **pending** record beside the others until its operation
///   succeeds (``confirmCreate(id:)``, ``confirmPending(keyVault:)``) or an unlock proves it.
/// - Besides the current record, up to four candidates (changes whose answer did not arrive); a fifth change is refused
///   before anything is sent, and no candidate is ever dropped to make room.
/// - A candidate becomes current on its operation's answer (even after an unlock made it a replaced record), or when an
///   unlock answered `device_secret` with the current record gets an answer given only after the secret matched with it.
/// - Replaced records are kept 7 days after the confirmation (never extended by a clock set back), for the
///   earlier-secret step the member starts, and deleted then (with any key no kept record names) or at a wipe.
/// - Only a definite loss is ``FailureKind/deviceSecret``; a locked iPhone is ``FailureKind/phoneLocked`` and keeps
///   every key and record; a records file in a format this app does not know is ``FailureKind/localState`` and is never
///   written over.
///
/// Mirrors vettid-android `PhoneSecrets` (whose secret of an epoch can be computed again at any time, so it keeps no
/// records). Nonisolated; every step holds the records file's process-wide lock (``EncryptedFileStore/exclusive(_:)``).
/// An epoch-1 secret and the id of the record it belongs to (its phone key's id), which the operation's success passes
/// to ``PhoneSecrets/confirmCreate(id:)``. The caller wipes ``secret`` after building the request.
public struct EpochOneSecret: Sendable {
    public let id: String
    public var secret: [UInt8]
}

public final class PhoneSecrets: @unchecked Sendable {
    public static let maxCandidates = 4
    /// Unconfirmed epoch-1 records kept at most (chosen; not in the spec: the bound of the candidates, rule 3).
    public static let maxPendings = 4
    /// How long a replaced record is kept after the confirmation (VAULT-MESSAGING §11.14.1 rule 6), in real time; divided
    /// by the vault's time scale when the 7 days start (STAGING-TIME-SCALE S9).
    public static let keepMs: Int64 = TimeScales.replacedRecordsKeepMs
    /// The records file's purpose in the encrypted file store.
    public static let purpose = "phone-secrets"

    let keys: any PhoneSecretSource
    let store: EncryptedFileStore
    let now: @Sendable () -> Date
    let ephemeral: @Sendable () -> P256.KeyAgreement.PrivateKey
    /// The vault's time scale now (STAGING-TIME-SCALE §5.2).
    let timeScale: @Sendable () -> UInt64
    /// ``pinGeneration``, read and written under ``generationLock``. In memory only.
    private var generation = 0
    private let generationLock = NSLock()

    /// [store] is the records file (purpose ``purpose``, in the app's backup-excluded data directory). [ephemeral] makes
    /// each epoch's fresh `E_e` (random; the vectors pass fixed keys).
    public init(
        keys: any PhoneSecretSource,
        store: EncryptedFileStore,
        now: @escaping @Sendable () -> Date = { Date() },
        ephemeral: @escaping @Sendable () -> P256.KeyAgreement.PrivateKey = { P256.KeyAgreement.PrivateKey() },
        timeScale: @escaping @Sendable () -> UInt64 = { 1 }
    ) {
        let claimed = PhoneSecretsRegistry.claim(source: keys.sourceID, records: store.url)
        precondition(claimed, "one PhoneSecrets records file per phone key source")
        self.keys = keys
        self.store = store
        self.now = now
        self.ephemeral = ephemeral
        self.timeScale = timeScale
    }

    // MARK: - Epoch 1

    /// A new phone key for [keyVault] and its epoch-1 record (enrollment, a transfer to this phone, a recovery), added to
    /// the **pending** records before the secret is returned. Every existing record and key stays until one pending
    /// record is confirmed (``confirmCreate(id:)``, or an unlock). While ``maxPendings`` are unconfirmed a new one is
    /// refused before anything is made or sent (``FailureKind/unconfirmedChanges``), after dropping the pending records
    /// whose key is definitively gone (missing or invalid; never on a locked or unknown answer). If the record cannot be
    /// written,
    /// the new key is deleted and nothing else changed. A device without secure hardware is ``FailureKind/hardwareKeys``.
    /// The caller wipes the secret after building the request.
    ///
    /// A records file that does not decrypt (a definite loss, VAULT-MESSAGING §11.14.1 rule 8) is replaced, and then every
    /// phone key no record names is deleted: the file was the only place that named them, so none can compute a secret
    /// any more.
    public func create(keyVault: String) throws -> EpochOneSecret {
        try store.exclusive {
            var corrupt = false
            var recs: PhoneRecords
            do {
                recs = try readRecords()
            } catch let f as VaultFailure where f.kind == .deviceSecret {
                (recs, corrupt) = (PhoneRecords(), true)
            }
            if recs.pendings.count >= Self.maxPendings { try dropDeadPendings(&recs) }
            guard recs.pendings.count < Self.maxPendings else {
                throw VaultFailure(.unconfirmedChanges, code: "unconfirmed_epoch_one")
            }
            let made = try keyStep(creating: true) { try keys.create(keyVault: keyVault) }
            do {
                let epoch = try newEpoch(made.key, keyVault: keyVault, epoch: 1, creating: true)
                recs.pendings.append(PhoneRecords.Entry(keyID: made.keyID, record: epoch.record))
                do {
                    try write(recs)
                } catch {
                    var s = epoch.secret
                    Bytes.wipe(&s)
                    throw error
                }
                if corrupt { sweepUnnamedKeys(recs) }
                return EpochOneSecret(id: made.keyID, secret: epoch.secret)
            } catch {
                try? keys.delete(keyVault: keyVault, keyID: made.keyID)
                throw error
            }
        }
    }

    /// Epoch 1 for [keyVault], reused when this phone already holds it (a retry whose earlier try may have reached the
    /// vault): the pending record, or a current epoch-1 record, of the same `key_vault` whose key passes the "keys
    /// usable" check. A new pending record otherwise (IOS-PLAN §6.3 item 7). A locked iPhone is
    /// ``FailureKind/phoneLocked`` and makes nothing.
    public func reuseOrCreate(keyVault: String) throws -> EpochOneSecret {
        try store.exclusive {
            let recs: PhoneRecords
            do {
                recs = try readRecords()
            } catch let f as VaultFailure where f.kind == .deviceSecret {
                return try create(keyVault: keyVault)
            }
            let reusable = (recs.pendings.reversed() + [recs.current].compactMap { $0 })
                .filter { $0.record.epoch == 1 && $0.record.keyVault == keyVault }
            for entry in reusable {
                do {
                    return EpochOneSecret(id: entry.keyID, secret: try secret(of: entry))
                } catch let f as VaultFailure where f.kind == .deviceSecret {
                    continue
                }
            }
            return try create(keyVault: keyVault)
        }
    }

    /// A pending epoch-1 record's own operation succeeded (the enrollment, the transfer or the recovery): exactly the
    /// pending record [id] (``EpochOneSecret/id``) becomes current, and the record it replaces, every candidate and every
    /// other pending record become replaced records. False when no pending record has that id.
    @discardableResult
    public func confirmCreate(id: String) throws -> Bool {
        try store.exclusive {
            var recs = try readRecords()
            guard let i = recs.pendings.firstIndex(where: { $0.keyID == id }) else { return false }
            promotePending(&recs, at: i)
            try write(recs)
            return true
        }
    }

    /// The vault proved that an enrollment carrying an epoch-1 secret for [keyVault] was accepted (its `vault.enrolled`
    /// pinned the vault on this device) while the enrollment's own answer, and so the record's id, was lost (a crash, a
    /// lost answer): the pending epoch-1 record of [keyVault] becomes current as ``confirmCreate(id:)`` makes it, but only
    /// when exactly one such record is pending, since with two it cannot tell which secret the vault holds (chosen; not in
    /// the spec). Pending records whose key is definitively gone are dropped first. True when a record was confirmed;
    /// false when none is pending. Throws ``FailureKind/localState`` (code ``codeAmbiguousEpochOne``) with more than
    /// one; they then stay pending (an unlock proves the right one).
    @discardableResult
    public func confirmPending(keyVault: String) throws -> Bool {
        try store.exclusive {
            var recs = try readRecords()
            try dropDeadPendings(&recs)
            let matching = recs.pendings.indices.filter {
                recs.pendings[$0].record.epoch == 1 && recs.pendings[$0].record.keyVault == keyVault
            }
            guard !matching.isEmpty else { return false }
            guard matching.count == 1 else { throw VaultFailure(.localState, code: Self.codeAmbiguousEpochOne) }
            promotePending(&recs, at: matching[0])
            try write(recs)
            return true
        }
    }

    public static let codeAmbiguousEpochOne = "ambiguous_epoch_one"

    /// Whether an epoch-1 record is pending: an enrollment, a transfer or a recovery that may have reached a vault and
    /// whose answer did not confirm it yet. Throws ``FailureKind/phoneLocked`` while the records cannot be read now and
    /// ``FailureKind/localState`` for a file in a format this app does not know.
    public func hasPending() throws -> Bool { try store.exclusive { try readRecords().pendings.isEmpty == false } }

    /// Drops the pending epoch-1 record [id] and deletes its key: its operation was refused for certain, or never reached
    /// the vault, so no vault holds its secret. Only a record never confirmed; false when none pending has that id.
    @discardableResult
    public func dropPending(id: String) throws -> Bool {
        try store.exclusive {
            var recs = try readRecords()
            guard let i = recs.pendings.firstIndex(where: { $0.keyID == id }) else { return false }
            let p = recs.pendings.remove(at: i)
            try write(recs)
            try? keys.delete(keyVault: p.record.keyVault, keyID: p.keyID)
            return true
        }
    }

    // MARK: - Secrets

    /// The current record's secret (an unlock, a recovery open). No record, no key, a point that does not parse or a tag
    /// that does not match: ``FailureKind/deviceSecret``.
    public func currentSecret() throws -> [UInt8] {
        try store.exclusive {
            guard let cur = try readRecords().current else { throw Self.lost }
            return try secret(of: cur)
        }
    }

    /// The current record, if any.
    public func current() throws -> PhoneSecretRecord? { try store.exclusive { try readRecords().current?.record } }

    /// Whether this phone holds a phone secret (a vault of release R). False also while the records cannot be read.
    public var inUse: Bool {
        guard let recs = try? records() else { return false }
        return recs.current != nil || !recs.pendings.isEmpty
    }

    /// The "keys usable" check of the phone key (IOS-PLAN §6.3): the current record's secret is recomputed, its tag
    /// compared with `check_e`, and discarded. Lost only on a definite loss; a format this app does not know is its own
    /// verdict (refuse to start, VAULT-MESSAGING §11.14.1 rule 9); anything else is refused for now.
    public func keysUsable() -> KeysUsability {
        do {
            var s = try currentSecret()
            Bytes.wipe(&s)
            return .usable
        } catch let f as VaultFailure {
            switch f.kind {
            case .deviceSecret: return .lost
            case .localState: return .unknownFormat
            default: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    // MARK: - Which PIN the vault expects

    /// (VAULT-MESSAGING §11.14.9 step 2) Bumped by everything that may change which PIN the vault expects: a change of
    /// PIN or password, or a renew, about to go out (its record or marker stored), a change decided (applied, not
    /// applied, or ended with the PIN uncertain), a renew decided, the uncertain PIN settled, the unlock's PIN step moved,
    /// and the records deleted. A flow that unlocks with a PIN typed on its own screen (the release update, "Finish the
    /// move") reads it when it takes the PIN and sends nothing when it moved since (``VaultManager/pinTakenBefore(_:)``):
    /// the PIN may be the one from before that change (chosen; not in the spec, which holds these flows only while a
    /// change is undecided). In memory only; a restart takes the PIN again.
    public var pinGeneration: Int { generationLock.withLock { generation } }

    /// Something that may change which PIN the vault expects happened (``pinGeneration``).
    func pinMoved() { generationLock.withLock { generation += 1 } }

    /// The records as stored (for the screens and the tests).
    public func records() throws -> PhoneRecords { try store.exclusive { try readRecords() } }

    // MARK: - Deletion

    /// Deletes replaced records whose 7 days are over, and every key no kept record names any more. The 7 days count
    /// from the confirmation, or from now when the clock is behind it (that time is stored, so a clock kept behind never
    /// extends them). Run at launch; every write prunes too.
    public func prune() throws {
        try store.exclusive {
            let recs = try readRecords()
            if Self.pruned(recs, nowMs: nowMs(), keepMs: keepNowMs()) != recs { try write(recs) }
        }
    }

    /// Deletes every phone key and record (a wipe, the end of a transfer's keep period).
    public func delete() throws {
        try store.exclusive {
            defer { pinMoved() }
            try keyStep(creating: false) { try keys.deleteAll() }
            try store.clear()
        }
    }

    /// The records less the replaced ones whose keep period is over. A replaced record without its keep period yet (just
    /// made) gets [keepMs], the 7 days at the vault's time scale now, and keeps it.
    static func pruned(_ recs: PhoneRecords, nowMs: Int64, keepMs: Int64 = PhoneSecrets.keepMs) -> PhoneRecords {
        var out = recs
        out.replaced = recs.replaced.compactMap { r in
            var r = r
            if nowMs < r.since { r.since = nowMs }
            if r.keepMs == nil { r.keepMs = keepMs }
            return nowMs - r.since >= (r.keepMs ?? keepMs) ? nil : r
        }
        return out
    }

    /// The 7 days of a replaced record that starts now, at the vault's time scale.
    func keepNowMs() -> Int64 { TimeScale.scaledMs(Self.keepMs, by: timeScale()) }

    // MARK: - Internals (callers hold the file's lock)

    static let lost = VaultFailure(.deviceSecret, code: "no_phone_key")
    static let locked = VaultFailure(.phoneLocked, code: "phone_locked")
    static let unknownFormat = VaultFailure(.localState, code: "phone_records_format")

    func nowMs() -> Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded(.down)) }

    /// The records file: missing is no records; unreadable now is ``FailureKind/phoneLocked``; a format this app does not
    /// know (the blob's or the JSON's) is ``FailureKind/localState`` and is never written over; a file that does not
    /// decrypt or parse while its key works is lost.
    func readRecords() throws -> PhoneRecords {
        let raw: [UInt8]
        do {
            switch try store.lookup() {
            case .found(let b): raw = b
            case .missing: return PhoneRecords()
            case .unavailable: throw Self.locked
            }
        } catch let e as KeysError {
            throw Self.failure(reading: e)
        }
        if let v = try? PhoneRecords.format(raw), v != PhoneRecords.format { throw Self.unknownFormat }
        do {
            return try PhoneRecords.parse(raw)
        } catch {
            throw Self.lost
        }
    }

    /// The records file's lookup failure: an unknown format, a loss, or refused for now.
    static func failure(reading e: KeysError) -> VaultFailure {
        switch e {
        case .unknownFormat: unknownFormat
        case .corrupt, .missing, .invalid: lost
        case .unavailable, .noSecureHardware: locked
        }
    }

    /// Writes [recs] (after pruning), durably, by atomic replace; then deletes the keys of pruned records that no kept
    /// record names.
    func write(_ recs: PhoneRecords) throws {
        let kept = Self.pruned(recs, nowMs: nowMs(), keepMs: keepNowMs())
        do {
            try store.save(kept.marshal())
        } catch {
            throw Self.locked
        }
        let named = Set(kept.all.map { PhoneKeyName(keyVault: $0.record.keyVault, keyID: $0.keyID) })
        let dropped = Set(recs.all.map { PhoneKeyName(keyVault: $0.record.keyVault, keyID: $0.keyID) }).subtracting(named)
        for k in dropped { try? keys.delete(keyVault: k.keyVault, keyID: k.keyID) }
    }

    /// Runs a key operation and classifies its failure: no secure hardware, lost, or refused for now.
    @discardableResult
    func keyStep<T>(creating: Bool, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as KeysError {
            switch e {
            case .noSecureHardware: throw VaultFailure(.hardwareKeys, code: "phone_key", cause: e)
            case .unavailable: throw Self.locked
            case .unknownFormat: throw Self.unknownFormat
            case .missing, .invalid, .corrupt: throw creating ? VaultFailure(.hardwareKeys, code: "phone_key", cause: e) : Self.lost
            }
        } catch let e as CryptoError {
            // A point that does not parse, a tag that does not match: the keys no longer work. At creation, the
            // two-way check failed: the hardware cannot make the secret, and the vault never holds it.
            throw creating ? VaultFailure(.hardwareKeys, code: "phone_key", cause: e) : Self.lost
        } catch let f as VaultFailure {
            throw f
        } catch {
            throw Self.locked
        }
    }

    /// The phone key an entry names: missing is lost, unreadable now is locked.
    func phoneKey(_ entry: PhoneRecords.Entry) throws -> any KeyAgreementKey {
        switch keys.lookup(keyVault: entry.record.keyVault, keyID: entry.keyID) {
        case .found(let k): return k
        case .missing: throw Self.lost
        case .unavailable: throw Self.locked
        }
    }

    /// The secret of a stored [entry], recomputed by its `P` and checked against its tag.
    func secret(of entry: PhoneRecords.Entry) throws -> [UInt8] {
        let key = try phoneKey(entry)
        return try keyStep(creating: false) {
            try PhoneSecretIOS.recompute(entry.record, phoneKey: try key.publicKey()) { try key.agree($0) }
        }
    }

    /// A new epoch's record and secret with a fresh `E_e`, after the two-way check; `priv(E_e)` goes out of scope here.
    func newEpoch(
        _ key: any KeyAgreementKey, keyVault: String, epoch: UInt64, creating: Bool
    ) throws -> (record: PhoneSecretRecord, secret: [UInt8]) {
        try keyStep(creating: creating) {
            try PhoneSecretIOS.newEpoch(
                keyVault: keyVault, epoch: epoch, phoneKey: try key.publicKey(), ephemeral: ephemeral()
            ) { try key.agree($0) }
        }
    }

    /// Pending record [i] becomes current; the current record, every candidate and every other pending record become
    /// replaced records.
    func promotePending(_ recs: inout PhoneRecords, at i: Int) {
        let ms = nowMs()
        recs.confirmed()
        let chosen = recs.pendings.remove(at: i)
        if let cur = recs.current { recs.replaced.append(PhoneRecords.Replaced(entry: cur, operation: nil, since: ms)) }
        recs.replaced += recs.candidates.map { PhoneRecords.Replaced(entry: $0.entry, operation: $0.operation, since: ms) }
        recs.replaced += recs.pendings.map { PhoneRecords.Replaced(entry: $0, operation: nil, since: ms) }
        recs.candidates = []
        recs.pendings = []
        recs.current = chosen
    }

    /// Drops the pending records whose phone key is definitively gone (missing, or reported invalid), and their keys. A
    /// key that is locked or answers anything else keeps its record.
    func dropDeadPendings(_ recs: inout PhoneRecords) throws {
        let dead = recs.pendings.filter { p in
            KeysUsableCheck.agreement(keys.lookup(keyVault: p.record.keyVault, keyID: p.keyID)) == .lost
        }
        guard !dead.isEmpty else { return }
        recs.pendings.removeAll { dead.contains($0) }
        try write(recs)
        for p in dead { try? keys.delete(keyVault: p.record.keyVault, keyID: p.keyID) }
    }

    /// After a damaged records file was replaced by [recs]: deletes every phone key [recs] does not name. Safe because
    /// a phone key source serves one records file (``PhoneSecretsRegistry``).
    func sweepUnnamedKeys(_ recs: PhoneRecords) {
        guard let all = try? keys.keyNames() else { return }
        let named = Set(recs.all.map { PhoneKeyName(keyVault: $0.record.keyVault, keyID: $0.keyID) })
        for k in all where !named.contains(k) { try? keys.delete(keyVault: k.keyVault, keyID: k.keyID) }
    }
}

/// One records file per phone key source, for the whole process: a source's keys are named only by its one records
/// file, which is what makes deleting the keys no record names safe. A second `PhoneSecrets` over the same file is fine
/// (it shares the file's lock); one over another file is a programming error.
enum PhoneSecretsRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [String: String] = [:]

    /// Whether [records] may be used with [source]: the first file claims the source, later claims must name the same
    /// file.
    static func claim(source: String, records: URL) -> Bool {
        let path = records.standardizedFileURL.resolvingSymlinksInPath().path
        return lock.withLock {
            if let held = files[source] { return held == path }
            files[source] = path
            return true
        }
    }
}
