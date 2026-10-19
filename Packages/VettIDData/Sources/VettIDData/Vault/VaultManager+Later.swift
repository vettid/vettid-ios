import Foundation

// The operations of the later rows of IOS-PLAN §8: each refuses with ``FailureKind/notSupported`` until its row brings
// it, so that a screen that reaches one early shows "not supported" instead of acting on half an implementation. The
// protocols' defaults cover the rest (the move).
extension VaultManager {
    // MARK: - CredentialRepository (I1.8: rotation, a new credential, the clone alarm)

    public func rotate(password: String) async throws { throw VaultFailure(.notSupported) }
    public func newCredential(pin: String, password: String, newPassword: String) async throws {
        throw VaultFailure(.notSupported)
    }
    public func confirmAlarm(mine: Bool) async throws { throw VaultFailure(.notSupported) }
}
