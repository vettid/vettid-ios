import Foundation
import VettIDAttestation
import VettIDKeys

/// Where Settings → Attestation reads the record of this phone's last verification of the enclave its vault runs on
/// (IOS-PLAN §6.9, ANDROID-PLAN 0.1.124); nil when there is none yet.
@MainActor
public protocol EnclaveRecordSource: AnyObject {
    var enclaveRecord: EnclaveRecord? { get }
}

extension VaultManager: EnclaveRecordSource {}

/// What a session's alternate channel reads and writes besides the network: the canary manifest, and where the enclave
/// verifications' records go (bound to the generation the session was opened in).
struct SessionStores: Sendable {
    let canary: CanaryManifestStore
    let records: EnclaveRecords
}

/// The last enclave verification's record (IOS-PLAN §6.9, ANDROID-PLAN 0.1.124 §5 "What the phone keeps"): each check's
/// result, the values the attestation screen shows and when it was made, in the app's encrypted file store (in the data
/// directory a wipe erases, excluded from backups); replaced by the next verification, erased by the wipe. Public material
/// only. A file that does not read is no record (the screen then says the phone has not verified the enclave yet), and the
/// next verification replaces it. Safe from any thread: the alternate channel records from its own task. Mirrors
/// vettid-android `EnclaveRecordStore`.
final class EnclaveRecordStore: @unchecked Sendable {
    private let file: EncryptedFileStore
    private let lock = NSLock()
    private var current: EnclaveRecord?
    /// Bumped by ``forget()``: a verification that began before a wipe never writes after it.
    private var generation = 0
    /// Set by ``load()``, and by a record or a wipe made before it: after either, what the file held is out of date.
    private var settled = false
    private var changed: (@Sendable () -> Void)?

    init(file: EncryptedFileStore) { self.file = file }

    /// Told after the record changed (a verification, the file read, a wipe).
    func onChange(_ body: @escaping @Sendable () -> Void) { lock.withLock { changed = body } }

    /// Whether the file has not been read yet.
    var needsLoad: Bool { lock.withLock { !settled } }

    /// The last record, or nil.
    var record: EnclaveRecord? { lock.withLock { current } }

    /// Reads the stored record (off the main actor: it is a keychain lookup and a decryption), once; a record or a wipe
    /// already made wins. While the file cannot be read yet (protected data not available) it is tried again at the next
    /// call.
    func load() {
        guard !lock.withLock({ settled }) else { return }
        let read: EnclaveRecord?
        do {
            read = try file.load().flatMap(Self.decode)
        } catch KeysError.unavailable {
            return
        } catch {
            read = nil
        }
        let took = lock.withLock {
            guard !settled else { return false }
            settled = true
            current = read
            return true
        }
        if took { notify() }
    }

    /// Where a session's verifications go: bound to the generation it was made in, so that nothing lands after a wipe.
    func sink() -> EnclaveRecords { Sink(store: self, generation: lock.withLock { generation }) }

    /// The wipe: the record goes from memory and from disk, and every sink made before it is closed.
    func forget() {
        lock.withLock {
            generation += 1
            settled = true
            current = nil
            try? file.clear()
        }
        notify()
    }

    private func record(_ r: EnclaveRecord, in g: Int) {
        let kept = lock.withLock {
            guard g == generation else { return false }
            settled = true
            current = r
            // Best effort: the screen shows the record in memory either way. A failed write clears the file, so that a restart
            // never reads an older record (a pass) after a newer one (a failure): it reads none.
            let saved = Self.encode(r).map { (try? file.save($0)) != nil } ?? false
            if !saved { try? file.clear() }
            return true
        }
        if kept { notify() }
    }

    private func notify() {
        let body = lock.withLock { changed }
        body?()
    }

    private struct Sink: EnclaveRecords {
        let store: EnclaveRecordStore
        let generation: Int

        func record(_ r: EnclaveRecord) { store.record(r, in: generation) }
    }

    static func encode(_ r: EnclaveRecord) -> [UInt8]? {
        let s = StoredEnclaveRecord(
            atMs: ms(r.at),
            results: Dictionary(uniqueKeysWithValues: AttestationCheck.allCases.map { ($0.rawValue, r.result($0).rawValue) }),
            manifestKeyID: r.manifestKeyID, manifestSerial: r.manifestSerial, pcr0: r.pcr0, pcr1: r.pcr1, pcr2: r.pcr2,
            attestedAtMs: r.attestedAt.map(ms), notAfterMs: r.notAfter.map(ms), releaseNumber: r.releaseNumber,
            releaseStatus: r.releaseStatus?.rawValue, releaseEndsAtMs: r.releaseEndsAt.map(ms), refusal: r.refusal?.rawValue
        )
        return (try? JSONEncoder().encode(s)).map { Array($0) }
    }

    /// The record again; a stored set of results that does not read as a run (a "Passed" after a check that did not pass,
    /// an unknown name), an unknown release status or refusal, is no record, so the screen never shows a pass that was not
    /// recorded in order.
    static func decode(_ bytes: [UInt8]) -> EnclaveRecord? {
        guard let s = try? JSONDecoder().decode(StoredEnclaveRecord.self, from: Data(bytes)) else { return nil }
        var results: [AttestationCheck: CheckResult] = [:]
        for (k, v) in s.results {
            guard let c = AttestationCheck(rawValue: k), let res = CheckResult(rawValue: v) else { return nil }
            results[c] = res
        }
        guard let run = EnclaveRecord.run(results) else { return nil }
        var r = EnclaveRecord(at: date(s.atMs), passed: run.passed, failed: run.failed)
        if let st = s.releaseStatus {
            guard let status = ReleaseStatus(rawValue: st) else { return nil }
            r.releaseStatus = status
        }
        if let why = s.refusal {
            // A refusal comes only after every check passed.
            guard let refusal = EnclaveRefusal(rawValue: why), r.allPassed else { return nil }
            r.refusal = refusal
        }
        values(s, into: &r, passed: run.passed)
        return r
    }

    /// Only the values the verifier had read by the end of a run of [passed] passes (as it records them): none of a step
    /// not reached.
    private static func values(_ s: StoredEnclaveRecord, into r: inout EnclaveRecord, passed: Int) {
        if passed >= 1 {
            r.manifestKeyID = s.manifestKeyID
            r.manifestSerial = s.manifestSerial
        }
        if passed >= 3 {
            r.pcr0 = s.pcr0
            r.pcr1 = s.pcr1
            r.pcr2 = s.pcr2
            r.attestedAt = s.attestedAtMs.map(date)
            r.notAfter = s.notAfterMs.map(date)
        }
        if r.verified(.match) {
            r.releaseNumber = s.releaseNumber
            r.releaseEndsAt = s.releaseEndsAtMs.map(date)
        } else {
            r.releaseStatus = nil
        }
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

/// The stored form of an ``EnclaveRecord`` (``EnclaveRecordStore``): names and numbers only.
struct StoredEnclaveRecord: Codable {
    var atMs: Int64
    /// The result of each check, by ``AttestationCheck`` name.
    var results: [String: String]
    var manifestKeyID: String?
    var manifestSerial: UInt64?
    var pcr0: String?
    var pcr1: String?
    var pcr2: String?
    var attestedAtMs: Int64?
    var notAfterMs: Int64?
    var releaseNumber: UInt64?
    var releaseStatus: String?
    var releaseEndsAtMs: Int64?
    var refusal: String?

    enum CodingKeys: String, CodingKey {
        case atMs = "at_ms", results, manifestKeyID = "manifest_key_id", manifestSerial = "manifest_serial", pcr0, pcr1, pcr2
        case attestedAtMs = "attested_at_ms", notAfterMs = "not_after_ms", releaseNumber = "release_number"
        case releaseStatus = "release_status", releaseEndsAtMs = "release_ends_at_ms", refusal
    }
}
