import Foundation

// The operations of the later rows of IOS-PLAN §8: each refuses with ``FailureKind/notSupported`` until its row brings
// it, so that a screen that reaches one early shows "not supported" instead of acting on half an implementation. The
// protocols' defaults cover the rest (the move, the phone secret's renewal).
extension VaultManager {
    // MARK: - VaultRepository

    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step opened the vault: ``renewSecretSuggested`` is set for the
    /// shell. The History entry on the phone and the immediate prompt for a new phone secret (`vault.secret.renew`) come
    /// with New phone secret (I1.8) and History (I2.3).
    func earlierSecretRestored() { renewSecretSuggested = true }

    /// I1.8: deleting the vault from Settings (§12.5).
    public func deleteVault(pin: String, password: String) async throws { throw VaultFailure(.notSupported) }

    // MARK: - CredentialRepository (I1.8: rotation, a new credential, the clone alarm)

    public func rotate(password: String) async throws { throw VaultFailure(.notSupported) }
    public func newCredential(pin: String, password: String, newPassword: String) async throws {
        throw VaultFailure(.notSupported)
    }
    public func confirmAlarm(mine: Bool) async throws { throw VaultFailure(.notSupported) }
}
