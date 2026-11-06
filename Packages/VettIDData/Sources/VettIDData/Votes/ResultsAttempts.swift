import Foundation
import Network
import VettIDKeys

/// What the app keeps of its last attempt at one vote's results (VAULT-MESSAGING 0.83.6 §10.19.6, "A `gave_up` check is
/// not final"; ANDROID-PLAN 0.1.121 "A `gave_up` check run again"): enough to run a `gave_up` check again at most once a
/// day per record, across restarts, and not to download an unchanged `rows.json` again. **Never a choice, a row or a
/// proof**: only times, the SHA-256 of the public `results.json`, its signature and its bundle, and a few facts. A re-check
/// that skips the download sends nothing (the spec's "or sends nothing": the same results, row and proof get the same
/// answer), so no row needs to be kept. Forgotten when the check is final or the vote leaves the vault's list, and with
/// the app's data at a wipe. Mirrors vettid-android `ResultsAttempt`.
public struct ResultsAttempt: Codable, Equatable, Sendable, CustomStringConvertible {
    /// ``ResultsAttempts/id(_:)`` of the pair.
    public var key: String
    /// When the attempt ran (the phone's clock, epoch milliseconds).
    public var atMs: Int64
    /// Hex SHA-256 of the `results.json` it read; nil when it was absent or could not be fetched.
    public var resultsSha256: String?
    /// `rows.json` was had on that attempt (read, or found over its cap): false when it was absent or could not be fetched.
    public var rowsFetched = false
    /// The vault left the check for a reason of its own side (`trust_root`, `service_list`, `clock`).
    public var vaultSide = false
    /// The attempt was submitted and the vault answered it: only then does "the same results get the same answer" hold.
    public var answered = false
    /// That submission carried the member's real row, not `rows_unavailable`: a `rows.json` that was broken may be
    /// corrected under the same `results.json`, so after such an attempt it is always fetched again.
    public var sentRow = false
    /// Hex SHA-256 of the `results.json.sig` and `results.json.sigstore.json` it read (public, small); nil when absent or not
    /// fetched. A fixed bundle or signature beside the same `results.json` is a change: fetched and sent again.
    public var sigSha256: String?
    public var bundleSha256: String?
    /// When this record's `gave_up` check was first run again (epoch ms; owner decision a, 2026-11-06): for 7 days from it
    /// `rows.json` is downloaded by the daily rule on any network; after them on an unmetered one, and at most weekly on a
    /// metered one. Nil before the first re-check.
    public var firstRecheckMs: Int64?
    /// When `rows.json` was last downloaded for this record (epoch ms; the weekly cap on a metered network); nil for never.
    public var lastRowsMs: Int64?

    public init(
        key: String, atMs: Int64, resultsSha256: String? = nil, rowsFetched: Bool = false, vaultSide: Bool = false,
        answered: Bool = false, sentRow: Bool = false, sigSha256: String? = nil, bundleSha256: String? = nil,
        firstRecheckMs: Int64? = nil, lastRowsMs: Int64? = nil
    ) {
        self.key = key
        self.atMs = atMs
        self.resultsSha256 = resultsSha256
        self.rowsFetched = rowsFetched
        self.vaultSide = vaultSide
        self.answered = answered
        self.sentRow = sentRow
        self.sigSha256 = sigSha256
        self.bundleSha256 = bundleSha256
        self.firstRecheckMs = firstRecheckMs
        self.lastRowsMs = lastRowsMs
    }

    /// Whether a `gave_up` re-check that read `results.json`, its signature and its bundle of these hashes skips
    /// `rows.json` and sends nothing: the same three as this attempt, which had `rows.json`, was answered by the vault with
    /// the member's real row and did not end on the vault's side.
    public func skipsRows(results: String?, sig: String?, bundle: String?) -> Bool {
        answered && sentRow && rowsFetched && !vaultSide && results != nil && sig != nil && bundle != nil &&
            results == resultsSha256 && sig == sigSha256 && bundle == bundleSha256
    }

    public var description: String { "ResultsAttempt" }
}

/// Where ``ResultsAttempt``s are kept.
public protocol ResultsAttemptStore: Sendable {
    /// The kept attempts; nil when they cannot be read now (the protected data is unavailable): nothing is written until a
    /// load succeeds, so that the other votes' stamps are not overwritten.
    func load() -> [ResultsAttempt]?
    func save(_ attempts: [ResultsAttempt])
}

/// In memory only (tests, and builds without a file).
public final class MemoryResultsAttemptStore: ResultsAttemptStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [ResultsAttempt] = []

    public init() {}

    public func load() -> [ResultsAttempt]? { lock.withLock { held } }
    public func save(_ attempts: [ResultsAttempt]) { lock.withLock { held = attempts } }
}

/// In an encrypted file (``EncryptedFileStore``) of the data directory that a wipe erases; an unreadable file reads as
/// empty, and an empty list clears it.
public final class FileResultsAttemptStore: ResultsAttemptStore, @unchecked Sendable {
    private let file: EncryptedFileStore

    public init(file: EncryptedFileStore) { self.file = file }

    public func load() -> [ResultsAttempt]? {
        let bytes: [UInt8]?
        do {
            bytes = try file.load()
        } catch KeysError.unavailable {
            // Cannot be read now (the protected data is unavailable): not "empty", and nothing is written over it.
            return nil
        } catch {
            // Damaged, replaced, in a format this app does not know, or its key is gone: the attempts are only a daily stamp
            // and hashes, so it reads as empty and the file is cleared, and the next write repairs it (as vettid-android's
            // store, whose unreadable file reads as empty).
            try? file.clear()
            return []
        }
        guard let bytes else { return [] }
        return (try? JSONDecoder().decode([ResultsAttempt].self, from: Data(bytes))) ?? []
    }

    public func save(_ attempts: [ResultsAttempt]) {
        if attempts.isEmpty {
            try? file.clear()
        } else if let data = try? JSONEncoder().encode(attempts) {
            try? file.save(Array(data))
        }
    }
}

/// The kept attempts and the rules that read them (VAULT-MESSAGING 0.83.6 §10.19.6; owner decision a, 2026-11-06). On the
/// main actor: every read and write is one step, so a write racing ``forgetAll()`` is dropped by its ``epoch``.
@MainActor
final class ResultsAttempts {
    /// A `gave_up` check runs again at most once a day per record.
    static let recheckEvery: TimeInterval = 24 * 3600
    /// From the first re-check of a `gave_up` record, `rows.json` on any network for this long.
    static let wifiOnlyAfter: TimeInterval = 7 * 24 * 3600
    /// After that, on a metered network, `rows.json` at most this often (a weekly cap, not a block).
    static let meteredRowsEvery: TimeInterval = 7 * 24 * 3600

    private let store: any ResultsAttemptStore
    private var held: [ResultsAttempt]?
    /// Bumped by ``forgetAll()`` (a wipe, a sign-out, a deletion). A write taken under an older epoch is dropped. A lock
    /// does not bump it: the kept attempts outlive a lock and a restart on purpose (the daily limit).
    private(set) var epoch = 0

    init(store: any ResultsAttemptStore) { self.store = store }

    static func id(_ key: VoteKey) -> String { key.connectionID + "/" + key.proposalID }

    /// The kept attempts; nil while they cannot be read (a failed load is not kept, and is tried again at the next step).
    private var loaded: [ResultsAttempt]? {
        if let held { return held }
        held = store.load()
        return held
    }

    /// For reading: an unreadable store reads as empty.
    private var all: [ResultsAttempt] { loaded ?? [] }

    func attempt(_ key: VoteKey) -> ResultsAttempt? { all.first { $0.key == Self.id(key) } }

    /// A `gave_up` check is run again at most once a day per record; a clock set back does not hold it up.
    func dailyDue(_ key: VoteKey, at: Date) -> Bool {
        // Attempts that cannot be read now are not "none": the daily re-check waits until they can.
        guard loaded != nil else { return false }
        guard let last = attempt(key) else { return true }
        let since = at.timeIntervalSince1970 * 1000 - Double(last.atMs)
        return since < 0 || since >= Self.recheckEvery * 1000
    }

    /// Whether the `rows.json` download of a `gave_up` re-check waits: past ``wifiOnlyAfter`` from the record's first
    /// re-check, on a network not known to be unmetered, and less than ``meteredRowsEvery`` since the last rows download.
    /// Within the 7 days, or on an unmetered network, the daily rule alone governs. [unmetered] nil (unknown) is metered.
    func rowsDeferred(_ key: VoteKey, at: Date, unmetered: () -> Bool?) -> Bool {
        // Unreadable attempts: the download waits too (nothing is known of the last one).
        guard loaded != nil else { return true }
        guard let last = attempt(key), let first = last.firstRecheckMs, let rowsAt = last.lastRowsMs else { return false }
        let now = Int64(at.timeIntervalSince1970 * 1000)
        return now - first >= Int64(Self.wifiOnlyAfter * 1000) && (0 ..< Int64(Self.meteredRowsEvery * 1000)).contains(now - rowsAt) &&
            unmetered() != true
    }

    /// Writes [next] for [key] (nil: forgets it), only while no wipe happened since [epoch] was taken.
    func put(_ key: VoteKey, _ next: ResultsAttempt?, epoch taken: Int) {
        guard taken == epoch, let current = loaded else { return }
        let id = Self.id(key)
        var list = current.filter { $0.key != id }
        if let next { list.append(next) }
        write(list)
    }

    /// Stamps the time of the daily re-check on [key]'s kept attempt (a daily run that joined a Check again on its way).
    func stamp(_ key: VoteKey, at: Date, epoch taken: Int) {
        guard var last = attempt(key) else { return }
        last.atMs = Int64(at.timeIntervalSince1970 * 1000)
        put(key, last, epoch: taken)
    }

    /// Forgets the attempts for which [gone] holds (a vote no longer listed, or whose check is final).
    func forget(epoch taken: Int, where gone: (ResultsAttempt) -> Bool) {
        guard taken == epoch, let current = loaded else { return }
        let list = current.filter { !gone($0) }
        if list != current { write(list) }
    }

    /// Forgets the attempts of votes that [list] (the whole list the vault gave) no longer has, or whose check is final.
    func forgetUnlisted(_ list: [VoteSummary], epoch taken: Int) {
        let live = Set(list.filter { $0.check.map { !VotesManager.finalCheck($0.state) } ?? true }.map { Self.id($0.key) })
        forget(epoch: taken) { !live.contains($0.key) }
    }

    /// The vault's data goes from this phone (a wipe, a sign-out, a deletion): forgotten in memory and on disk, and a
    /// write still on its way is dropped. Not at a lock.
    func forgetAll() {
        epoch += 1
        held = []
        store.save([])
    }

    private func write(_ list: [ResultsAttempt]) {
        held = list
        // A store that cannot be written keeps the memory copy: the daily limit then holds until a restart.
        store.save(list)
    }
}

/// Whether the phone's network is unmetered now (owner decision a, 2026-11-06: after 7 days a `gave_up` record downloads
/// `rows.json` on an unmetered network, and at most weekly on a metered one). Nil when it cannot be told, counted as metered.
public protocol NetworkMeter: Sendable {
    func unmetered() -> Bool?
}

/// A network that cannot be told (the tests, the builds without a monitor): metered.
public struct UnknownNetworkMeter: NetworkMeter {
    public init() {}
    public func unmetered() -> Bool? { nil }
}

/// ``NetworkMeter`` over `NWPathMonitor`: an expensive (cellular, personal hotspot) or constrained (Low Data Mode) path is
/// metered; so is a path that is not satisfied or has not been reported yet (nil).
public final class PathNetworkMeter: NetworkMeter, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    public init() {
        monitor.pathUpdateHandler = { [weak self] p in self?.lock.withLock { self?.path = p } }
        monitor.start(queue: DispatchQueue(label: "org.vettid.votes.network", qos: .utility))
    }

    deinit { monitor.cancel() }

    public func unmetered() -> Bool? {
        guard let p = lock.withLock({ path }) else { return nil }
        return Self.unmetered(satisfied: p.status == .satisfied, expensive: p.isExpensive, constrained: p.isConstrained)
    }

    /// The rule alone: only a satisfied path that is neither expensive nor constrained is unmetered.
    static func unmetered(satisfied: Bool, expensive: Bool, constrained: Bool) -> Bool? {
        satisfied ? !(expensive || constrained) : nil
    }
}
