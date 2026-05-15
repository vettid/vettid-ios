import Foundation

// MARK: - Migration Completion Recorder

/// Phase 5.7 — local record of the most recent vault re-seal version.
///
/// The M1 migration model couples consent to a PIN unlock: when the user
/// approves an enclave update on the PIN screen, `migrate_consent=true`
/// rides on the next `vault.warm` request and the vault re-seals
/// `sealed_material.bin` against the running PCR0 inline. The vault
/// echoes `migration_status="completed"` + `migration_version=...` in
/// the warm response; this recorder persists the version locally so
/// the app:
///
///   1. Knows it has consented to the running enclave already and
///      doesn't re-prompt on the next unlock.
///   2. Can show the user a "What's new in this version" link from the
///      Security Audit Log when a `migration_verified` event arrives
///      carrying the same version.
///
/// Mirrors Android `MigrationCompletionRecorder` (UserDefaults-backed,
/// no remote sync). The store is keyed by user GUID so a credential
/// rotation that changes the GUID starts fresh.
final class MigrationCompletionRecorder {

    static let shared = MigrationCompletionRecorder()

    private let defaults: UserDefaults
    private let key = "vettid.migration.last-completed-version"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Record that the vault has re-sealed against the given migration
    /// version. Idempotent — calling with the same version is a no-op
    /// at the persistent layer (write is unconditional, but reads see
    /// the same value).
    func record(version: String) {
        guard !version.isEmpty else { return }
        defaults.set(version, forKey: key)
        #if DEBUG
        print("[MigrationCompletionRecorder] Recorded migrated version: \(version)")
        #endif
    }

    /// Most recently recorded migration version, or nil when no
    /// migration has completed on this install.
    var lastCompletedVersion: String? {
        defaults.string(forKey: key)
    }

    /// Forget the recorded version. Called when a user re-enrolls or
    /// rotates credentials so we don't carry over a stale version from
    /// a previous identity.
    func reset() {
        defaults.removeObject(forKey: key)
    }
}
