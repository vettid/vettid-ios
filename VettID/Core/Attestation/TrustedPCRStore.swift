import Foundation

// MARK: - Trusted PCR Store

/// Phase 5.7 follow-up (#56) — per-user record of the PCR0 values the
/// user has explicitly consented to.
///
/// Background: the vault's PCR0 changes whenever the enclave image is
/// rebuilt. A user who enrolled against PCR0 = A should be prompted
/// before talking to PCR0 = B even if both are signed by Anthropic /
/// AWS — otherwise an operator could quietly substitute the enclave
/// and the app would happily send the PIN to it.
///
/// This store records the PCR0 fingerprints the user has approved on
/// this device. The PIN unlock screen compares the current PCR0
/// (from `ExpectedPCRStore.getCurrentPCRSet()` or the live attestation)
/// against this set; an untrusted PCR0 fires the "Enclave Update
/// Required" sheet before the PIN is sent.
///
/// Persistence: UserDefaults, keyed by user GUID so credential rotation
/// to a new identity starts fresh. Reset on logout.
///
/// Mirrors Android `PcrConfigManager.getTrustedPcr0Set()` /
/// `addTrustedPcr0()` / `isPcr0Trusted()`.
final class TrustedPCRStore {

    static let shared = TrustedPCRStore()

    private let defaults: UserDefaults
    private let keyPrefix = "vettid.trusted-pcr0."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    /// All PCR0s the user has approved on this device. Lowercased,
    /// hex-only — comparisons are case-insensitive at write time so
    /// the persisted form is canonical.
    func trustedSet(for userGuid: String) -> Set<String> {
        let raw = defaults.stringArray(forKey: storageKey(userGuid)) ?? []
        return Set(raw)
    }

    /// True when `pcr0` matches an approved value for this user.
    /// Empty trusted set returns false — the caller should treat that
    /// as the "bootstrap on first unlock" path and add the current
    /// PCR0 then, rather than gating forever.
    func isTrusted(pcr0: String, for userGuid: String) -> Bool {
        let canonical = pcr0.lowercased()
        return trustedSet(for: userGuid).contains(canonical)
    }

    /// True when the user has no recorded trusted PCR0s yet (e.g.
    /// existing users who enrolled before this surface existed).
    /// The first unlock after upgrade bootstraps by adding the
    /// current PCR0 to the trusted set silently.
    func isBootstrap(for userGuid: String) -> Bool {
        trustedSet(for: userGuid).isEmpty
    }

    // MARK: - Write

    /// Record consent for a PCR0. Idempotent — adding the same value
    /// twice is a no-op. The persisted value is lowercased.
    func add(pcr0: String, for userGuid: String) {
        let canonical = pcr0.lowercased()
        guard !canonical.isEmpty else { return }
        var set = trustedSet(for: userGuid)
        guard !set.contains(canonical) else { return }
        set.insert(canonical)
        defaults.set(Array(set), forKey: storageKey(userGuid))
        #if DEBUG
        print("[TrustedPCRStore] Added PCR0 \(canonical.prefix(16))… for \(userGuid.prefix(8))…")
        #endif
    }

    /// Forget every recorded PCR0 for a user. Called on logout or
    /// when a credential rotation produces a new GUID.
    func reset(for userGuid: String) {
        defaults.removeObject(forKey: storageKey(userGuid))
    }

    /// Forget every recorded PCR0 across every user. Wipes the store
    /// in the device-reset path.
    func resetAll() {
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    private func storageKey(_ userGuid: String) -> String {
        keyPrefix + userGuid
    }
}
