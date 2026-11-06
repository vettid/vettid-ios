import Foundation
import VettIDKeys

/// When the recheck on open (or a results check) last downloaded `rows.json` for a vote (VAULT-MESSAGING §10.19.6; vettid-android
/// #319 item 2 and #321): a key and a time, **no choice and no verdict**. Its own encrypted file, since the attempts of a
/// final check are dropped and the recheck is for `verified` and `unconfirmed` votes. Mirrors vettid-android `RecheckStamp`.
public struct RecheckStamp: Codable, Equatable, Sendable, CustomStringConvertible {
    /// ``ResultsAttempts/id(_:)`` of the pair.
    public var key: String
    /// The phone's clock, epoch milliseconds.
    public var atMs: Int64

    public init(key: String, atMs: Int64) {
        self.key = key
        self.atMs = atMs
    }

    public var description: String { "RecheckStamp" }
}

/// Where ``RecheckStamp``s are kept.
public protocol RecheckStampStore: Sendable {
    /// The kept stamps; nil when they cannot be read now (the protected data is unavailable): nothing is written until a load
    /// succeeds.
    func load() -> [RecheckStamp]?
    func save(_ stamps: [RecheckStamp])
}

/// In memory only (tests, and builds without a file).
public final class MemoryRecheckStampStore: RecheckStampStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [RecheckStamp] = []

    public init() {}

    public func load() -> [RecheckStamp]? { lock.withLock { held } }
    public func save(_ stamps: [RecheckStamp]) { lock.withLock { held = stamps } }
}

/// In an encrypted file (``EncryptedFileStore``) of the data directory that a wipe erases; a damaged file reads as empty
/// (and is cleared), an empty list clears it, as ``FileResultsAttemptStore``.
public final class FileRecheckStampStore: RecheckStampStore, @unchecked Sendable {
    private let file: EncryptedFileStore

    public init(file: EncryptedFileStore) { self.file = file }

    public func load() -> [RecheckStamp]? {
        let bytes: [UInt8]?
        do {
            bytes = try file.load()
        } catch KeysError.unavailable {
            return nil
        } catch {
            try? file.clear()
            return []
        }
        guard let bytes else { return [] }
        return (try? JSONDecoder().decode([RecheckStamp].self, from: Data(bytes))) ?? []
    }

    public func save(_ stamps: [RecheckStamp]) {
        if stamps.isEmpty {
            try? file.clear()
        } else if let data = try? JSONEncoder().encode(stamps) {
            try? file.save(Array(data))
        }
    }
}

/// The recheck on open's last rows downloads, and the cap on the next (vettid-android #319 item 2, the lead's call (a); #321):
/// the verdict is memory only and a lock forgets it, so without a cap every open after a lock would download `rows.json`
/// (up to 51 MB) again. On a network not known unmetered: until a vote's `closes_at` (as extended) plus 7 days at most one
/// download per vote per 24 hours, after that (and with no close known) at most weekly; an unmetered network is never capped.
///
/// Thread-safe, not main-actor: a download reports its first bytes from the site client's own thread, which a lock does not
/// interrupt, and they count whatever the job's state (a lock partway still spent them). A wipe ``forgetAll()`` bumps the
/// ``epoch``, and a stamp taken under an older one is dropped.
final class RecheckStamps: @unchecked Sendable {
    /// Until the vote's close plus this, on a metered network, at most one download per ``earlyEvery``.
    static let dailyFor: TimeInterval = 7 * 24 * 3600
    static let earlyEvery: TimeInterval = 24 * 3600
    /// After that, or with no close known, at most this often (as ``ResultsAttempts/meteredRowsEvery``).
    static let laterEvery: TimeInterval = 7 * 24 * 3600

    private let lock = NSLock()
    private let store: any RecheckStampStore
    private var held: [String: Int64]?
    private var generation = 0

    init(store: any RecheckStampStore) { self.store = store }

    /// Bumped by ``forgetAll()``.
    var epoch: Int { lock.withLock { generation } }

    /// Under the lock. Nil while the store cannot be read (a failed load is not kept; the next step tries again).
    private func loaded() -> [String: Int64]? {
        if let held { return held }
        guard let list = store.load() else { return nil }
        let map = Dictionary(list.map { ($0.key, $0.atMs) }, uniquingKeysWith: max)
        held = map
        return map
    }

    private func write(_ map: [String: Int64]) {
        held = map
        store.save(map.sorted { $0.key < $1.key }.map { RecheckStamp(key: $0.key, atMs: $0.value) })
    }

    /// Records the download of [key] at [at], while the epoch is still [taken] (no wipe since the check began).
    func stamp(_ key: String, at: Int64, epoch taken: Int) {
        lock.withLock {
            guard taken == generation, var map = loaded() else { return }
            map[key] = at
            write(map)
        }
    }

    /// The stamps of votes that [listed] (the whole list) no longer has go, with the attempts' pruning.
    func prune(listed: Set<String>, epoch taken: Int) {
        lock.withLock {
            guard taken == generation, let map = loaded() else { return }
            let kept = map.filter { listed.contains($0.key) }
            if kept.count != map.count { write(kept) }
        }
    }

    /// Whether the recheck's `rows.json` download for [key] waits at [at] (epoch ms): on a network not known unmetered, the
    /// last download was less than a day ago while within 7 days of the vote's close [closesAt] (epoch ms), or less than a week
    /// ago after it or with no close known. No stamp: it does not wait. Stamps that cannot be read now: it waits.
    func waits(_ key: String, at: Int64, closesAt: Int64?, unmetered: Bool?) -> Bool {
        let last: Int64?? = lock.withLock { loaded().map { $0[key] } }
        guard let last else { return unmetered != true }
        guard let last else { return false }
        let early = closesAt.map { at < $0 + Int64(Self.dailyFor * 1000) } ?? false
        let every = Int64((early ? Self.earlyEvery : Self.laterEvery) * 1000)
        return (0 ..< every).contains(at - last) && unmetered != true
    }

    /// A wipe: forgotten in memory and on disk, and a stamp still on its way is dropped.
    func forgetAll() {
        lock.withLock {
            generation += 1
            held = [:]
            store.save([])
        }
    }
}

/// One `rows.json` download's report of its bytes (``VoteSite/getCounted(_:maxBytes:received:)``): at its first bytes it stamps
/// the recheck's cap once (not at every chunk), whatever the job's state by then (a lock partway still spent them), under the
/// epoch the check began in (a wipe since drops it); and it says whether any bytes came, which counts toward the weekly cap on
/// a metered network even when the download then drops.
final class RowsReport: @unchecked Sendable {
    private let lock = NSLock()
    private let stamps: RecheckStamps
    private let key: String
    private let at: Int64
    private let epoch: Int
    private var any = false

    init(_ stamps: RecheckStamps, key: String, at: Int64, epoch: Int) {
        self.stamps = stamps
        self.key = key
        self.at = at
        self.epoch = epoch
    }

    /// Whether any bytes of the body came.
    var received: Bool { lock.withLock { any } }

    @Sendable func receive(_ n: Int) {
        let first = lock.withLock { () -> Bool in
            guard n > 0, !any else { return false }
            any = true
            return true
        }
        if first { stamps.stamp(key, at: at, epoch: epoch) }
    }
}
