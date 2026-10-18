import Foundation

// The operations of the later rows of IOS-PLAN §8: each refuses with ``FailureKind/notSupported`` until its row brings
// it, so that a screen that reaches one early shows "not supported" instead of acting on half an implementation. The
// protocols' defaults cover the rest (the move, the release R changes).
extension VaultManager {
    // MARK: - VaultRepository

    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step opened the vault: ``renewSecretSuggested`` is set for the
    /// shell. The History entry on the phone and the immediate prompt for a new phone secret (`vault.secret.renew`) come
    /// with I1.8 (History, New phone secret).
    func earlierSecretRestored() { renewSecretSuggested = true }

    /// I1.8: Settings → Vault status.
    public func overview() async throws -> VaultOverview { throw VaultFailure(.notSupported) }

    /// I1.8: Change PIN (release R: `changePin(pin:newPin:password:)`, which keeps its protocol default until then).
    public func changePin(pin: String, newPin: String) async throws { throw VaultFailure(.notSupported) }

    /// I1.8: deleting the vault from Settings (§12.5).
    public func deleteVault(pin: String, password: String) async throws { throw VaultFailure(.notSupported) }

    /// I1.8: Settings → Vault status, with "Installed from" (ID15).
    public func attestationInfo() async throws -> AttestationInfo { throw VaultFailure(.notSupported) }

    // MARK: - CredentialRepository (I1.8: the credential screen)

    public func status() async throws -> CredentialStatus { throw VaultFailure(.notSupported) }
    public func openUnlockWindow(password: String) async throws { throw VaultFailure(.notSupported) }
    public func closeUnlockWindow() async throws { throw VaultFailure(.notSupported) }
    public func changePassword(_ password: String, newPassword: String) async throws { throw VaultFailure(.notSupported) }
    public func rotate(password: String) async throws { throw VaultFailure(.notSupported) }
    public func newCredential(pin: String, password: String, newPassword: String) async throws {
        throw VaultFailure(.notSupported)
    }
    public func setBackup(_ on: Bool) async throws { throw VaultFailure(.notSupported) }
    public func setUnlockTtl(seconds: Int) async throws { throw VaultFailure(.notSupported) }
    public func confirmAlarm(mine: Bool) async throws { throw VaultFailure(.notSupported) }
}
