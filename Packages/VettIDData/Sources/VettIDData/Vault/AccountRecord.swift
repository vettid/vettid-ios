import Foundation
import VettIDKeys

/// What this phone knows of its member without signing in (VAULT-MESSAGING §11.12.1): the `user_guid` and `vault_id`
/// from the setup code's redeem, the masked email to show, and where setting the vault up stands. Kept in the encrypted
/// file store; members this build does not know are ignored when read. Mirrors the fields of vettid-android
/// `LocalAccount` that onboarding uses; the later rows add theirs (the account snapshot, the move, the lock, recovery).
struct LocalAccount: Codable, Equatable, Sendable {
    var userGuid = ""
    var vaultID = ""
    var emailHint = ""
    /// A direct transfer to this phone started (§6.7.1): it has a vault to come without a redeem (I3.3).
    var transferIn = false
    /// The member left onboarding (``VaultManager/finishSetup()``).
    var setupComplete = false
    /// (§11.10.9) The capabilities of the vault's instance this phone last verified (`recovery_offered`).
    var capabilities: [String] = []
    /// The member's backup choice (§3.5.6), kept before `credential.create` so that a restart before the vault was
    /// confirmed still sends it; nil before the member chose.
    var backupChoice: Bool?
    /// `vault.enroll.confirm` was answered (§11.3): until then the vault is provisional and may be replaced, so every
    /// start resumes the confirmation and onboarding does not end without it.
    var enrollConfirmed = false
    /// This phone's enrollment made the vault (its `vault.enrolled` pinned it here): only then does a start resume
    /// `vault.enroll.confirm`.
    var enrolledHere = false
    /// When an enrollment request whose outcome is not known was first started (Unix ms): it may have made a provisional
    /// vault, so its keys are kept until a definite answer or ``VaultManager/unknownEnrollmentKept`` after this.
    var enrollStartedMs: Int64?
    /// The last time this phone reached the vault service (a status read), written at most hourly
    /// (``StuckScreens/writeContact(_:nowMs:)``), Unix ms.
    var lastContactMs: Int64?
    /// The enclave's time of the last successful unlock result (its inner `ts`, Unix ms): a `vault.locking` not later than
    /// it is stale after a restart too (``LockNotices``).
    var lastOpenedMs: Int64?
    /// The lock's own file (``LockRecordFile``) was written once: from then on a missing file says a lock is pending.
    var lockFileInUse = false

    enum CodingKeys: String, CodingKey {
        case userGuid = "user_guid"
        case vaultID = "vault_id"
        case emailHint = "email_hint"
        case transferIn = "transfer_in"
        case setupComplete = "setup_complete"
        case capabilities
        case backupChoice = "backup_choice"
        case enrollConfirmed = "enroll_confirmed"
        case enrolledHere = "enrolled_here"
        case enrollStartedMs = "enroll_started_ms"
        case lastContactMs = "last_contact_ms"
        case lastOpenedMs = "last_opened_ms"
        case lockFileInUse = "lock_file_in_use"
    }

    init() {}

    init(userGuid: String, vaultID: String, emailHint: String) {
        self.userGuid = userGuid
        self.vaultID = vaultID
        self.emailHint = emailHint
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userGuid = try c.decodeIfPresent(String.self, forKey: .userGuid) ?? ""
        vaultID = try c.decodeIfPresent(String.self, forKey: .vaultID) ?? ""
        emailHint = try c.decodeIfPresent(String.self, forKey: .emailHint) ?? ""
        transferIn = try c.decodeIfPresent(Bool.self, forKey: .transferIn) ?? false
        setupComplete = try c.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? false
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        backupChoice = try c.decodeIfPresent(Bool.self, forKey: .backupChoice)
        enrollConfirmed = try c.decodeIfPresent(Bool.self, forKey: .enrollConfirmed) ?? false
        enrolledHere = try c.decodeIfPresent(Bool.self, forKey: .enrolledHere) ?? false
        enrollStartedMs = try c.decodeIfPresent(Int64.self, forKey: .enrollStartedMs)
        lastContactMs = try c.decodeIfPresent(Int64.self, forKey: .lastContactMs)
        lastOpenedMs = try c.decodeIfPresent(Int64.self, forKey: .lastOpenedMs)
        lockFileInUse = try c.decodeIfPresent(Bool.self, forKey: .lockFileInUse) ?? false
    }

    /// The account as the screens see it before the vault sent a snapshot: the masked email only.
    var info: AccountInfo? { emailHint.isEmpty ? nil : AccountInfo(emailHint: emailHint) }
}

/// The account record and the writes the vault manager makes to it. Read only after the first-run cleanup (IOS-PLAN
/// §6.1), never before; a record that cannot be read is never taken for "no account" (it names the vault this phone's
/// keys belong to). Every reset moves ``generation`` on, so that a write for the record an operation started with is
/// dropped once a reset (another setup code, "that is not my account") replaced it. Mirrors vettid-android
/// `AccountRecord` (on the main actor here, so without its lock).
@MainActor
final class AccountRecord {
    private let store: EncryptedFileStore
    private(set) var value = LocalAccount()
    /// Bumped by every reset.
    private(set) var generation = 0
    private var loaded = false

    init(store: EncryptedFileStore) {
        self.store = store
    }

    /// Reads the record when it has not been read yet. Throws ``KeysError/unavailable(_:)`` while the iPhone is locked,
    /// and a loss (``KeysError/corrupt(_:)``) for a record that does not decrypt or parse; it is read again next time.
    func load() throws {
        guard !loaded else { return }
        if let b = try store.load() {
            do {
                value = try JSONDecoder().decode(LocalAccount.self, from: Data(b))
            } catch {
                throw KeysError.corrupt("account record")
            }
        } else {
            value = LocalAccount()
        }
        loaded = true
    }

    /// A read-modify-write, dropped (false) when a reset happened since [since] was read.
    @discardableResult
    func update(since: Int, _ change: (inout LocalAccount) -> Void) throws -> Bool {
        guard since == generation else { return false }
        var a = value
        change(&a)
        if a != value {
            try save(a)
            value = a
        }
        return true
    }

    /// This phone reached the vault service at [nowMs]: written into the record of [since] when it is worth it
    /// (``StuckScreens/writeContact(_:nowMs:)``). False when nothing was written.
    @discardableResult
    func contacted(since: Int, nowMs: Int64) throws -> Bool {
        guard since == generation, StuckScreens.writeContact(value.lastContactMs, nowMs: nowMs) else { return false }
        return try update(since: since) { $0.lastContactMs = nowMs }
    }

    /// A successful unlock answered at [atMs] (the enclave's clock): kept when it is later than the last one.
    func opened(since: Int, atMs: Int64) throws {
        guard value.lastOpenedMs.map({ atMs > $0 }) ?? true else { return }
        try update(since: since) { $0.lastOpenedMs = atMs }
    }

    /// Drops the writes on their way for the record as it was (the member's lock: what an operation that began before it
    /// would write is not wanted any more). The record itself is unchanged.
    func bumpGeneration() { generation += 1 }

    /// A record of its own ([a]: none, or a new setup's): the writes still on their way for the one before are dropped.
    func reset(_ a: LocalAccount) throws {
        generation += 1
        try save(a)
        value = a
        loaded = true
    }

    private func save(_ a: LocalAccount) throws {
        try store.save(Array(try JSONEncoder().encode(a)))
    }
}
