import Foundation
import VettIDKeys

/// The lock's record (``LockRecord``, ``LockKeeper``) in a file of its own in the encrypted file store, beside the account
/// record and not in it, written whole by atomic replace: a lock the member asked for is kept across a process death
/// whatever the state of the account record. Two times and nothing else (when a lock was asked for, and until when an
/// unanswered relay lock may still be acted on). Mirrors vettid-android `LockRecordFile` (a plain-text file there; no
/// older record to migrate here).
///
/// Fail secure: a file that cannot be read now (the iPhone locked), read at all, or understood says a lock is pending,
/// and so does a missing file once one was written ([inUse], kept in the account record). A fresh install (no account
/// record, no file) has no lock. It is read only after the account record was (the vault manager resumes the lock once
/// the first-run cleanup ran and the record loaded), so a record that cannot be read never gets here.
@MainActor
final class LockRecordFile: LockRecordStore {
    private static let version = "1"
    private static let none = "-"
    private static let fields = 3

    private let file: EncryptedFileStore
    private let inUse: @MainActor () -> Bool
    private let onFirstSave: @MainActor () -> Void
    private let now: @Sendable () -> Date

    init(
        file: EncryptedFileStore,
        inUse: @escaping @MainActor () -> Bool = { false },
        onFirstSave: @escaping @MainActor () -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.file = file
        self.inUse = inUse
        self.onFirstSave = onFirstSave
        self.now = now
    }

    private var pendingNow: LockRecord { LockRecord(pendingSinceMs: Int64((now().timeIntervalSince1970 * 1000).rounded(.down))) }

    func load() -> LockRecord {
        let found: [UInt8]
        do {
            switch try file.lookup() {
            case .found(let b): found = b
            case .missing: return inUse() ? pendingNow : LockRecord()
            case .unavailable: return pendingNow
            }
        } catch {
            return pendingNow
        }
        return Self.parse(found) ?? pendingNow
    }

    func save(_ record: LockRecord) throws {
        let line = "\(Self.version) \(record.pendingSinceMs.map(String.init) ?? Self.none) "
            + "\(record.relayLockUntilMs.map(String.init) ?? Self.none)\n"
        try file.save(Array(line.utf8))
        if !inUse() { onFirstSave() }
    }

    static func parse(_ bytes: [UInt8]) -> LockRecord? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == fields, parts[0] == version else { return nil }
        func time(_ s: Substring) -> Int64?? {
            if s == none { return .some(nil) }
            guard let v = Int64(s) else { return nil }
            return .some(v)
        }
        guard let pending = time(parts[1]), let relay = time(parts[2]) else { return nil }
        return LockRecord(pendingSinceMs: pending, relayLockUntilMs: relay)
    }
}
