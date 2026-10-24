import Foundation
import VettIDAltChan
import VettIDKeys

/// The lock's record (``LockRecord``, ``LockKeeper``) in a file of its own in the encrypted file store, beside the account
/// record and not in it, written whole by atomic replace: a lock the member asked for is kept across a process death
/// whatever the state of the account record. Two times (when a lock was asked for, and until when an unanswered relay lock
/// may still be acted on) and, from release L, the `unlock_id` a pending lock is bound to (a name, not a secret) and whether
/// this phone is held locked after a lock that ended because the vault was opened again. A record with neither is written
/// in the first version's form; a record of a form this app does not know says a lock is pending (fail secure). Mirrors
/// vettid-android `LockRecordFile` (a plain-text file there; no older record to migrate here).
///
/// Fail secure: a file that cannot be read now (the iPhone locked), read at all, or understood says a lock is pending,
/// and so does a missing file once one was written ([inUse], kept in the account record). A fresh install (no account
/// record, no file) has no lock. It is read only after the account record was (the vault manager resumes the lock once
/// the first-run cleanup ran and the record loaded), so a record that cannot be read never gets here.
@MainActor
final class LockRecordFile: LockRecordStore {
    private static let version = "1"
    /// (Release L) With the `unlock_id` the pending lock is bound to (or `-`) and the held marker (`0`, `1`, or `2`: held and
    /// since confirmed locked).
    private static let versionBound = "2"
    private static let none = "-"
    private static let fields = 3
    private static let fieldsBound = 5
    private static let held = "1"
    private static let notHeld = "0"
    private static let heldConfirmed = "2"

    /// A record that cannot be written in a form the next process reads (an `unlock_id` not of the form).
    struct NotSaved: Error {}

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
        try file.save(Array(Self.line(record).utf8))
        if !inUse() { onFirstSave() }
    }

    static func line(_ r: LockRecord) throws -> String {
        let times = "\(r.pendingSinceMs.map(String.init) ?? none) \(r.relayLockUntilMs.map(String.init) ?? none)"
        if r.unlockID == nil && !r.held { return "\(version) \(times)\n" }
        var shown = none
        if let id = r.unlockID {
            guard UnlockIds.of(id) != nil else { throw NotSaved() }
            shown = id
        }
        let mark = !r.held ? notHeld : r.heldConfirmed ? heldConfirmed : held
        return "\(versionBound) \(times) \(shown) \(mark)\n"
    }

    static func parse(_ bytes: [UInt8]) -> LockRecord? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
        guard let form = parts.first else { return nil }
        let bound = form == versionBound
        guard bound || form == version, parts.count == (bound ? fieldsBound : fields) else { return nil }
        func time(_ s: Substring) -> Int64?? {
            if s == none { return .some(nil) }
            guard let v = Int64(s) else { return nil }
            return .some(v)
        }
        guard let pending = time(parts[1]), let relay = time(parts[2]) else { return nil }
        guard bound else { return LockRecord(pendingSinceMs: pending, relayLockUntilMs: relay) }
        var id: String?
        if parts[3] != none {
            guard let valid = UnlockIds.of(String(parts[3])) else { return nil }
            id = valid
        }
        let marks: [String: (Bool, Bool)] = [held: (true, false), heldConfirmed: (true, true), notHeld: (false, false)]
        guard let mark = marks[String(parts[4])] else { return nil }
        return LockRecord(pendingSinceMs: pending, relayLockUntilMs: relay, unlockID: id, held: mark.0, heldConfirmed: mark.1)
    }
}
