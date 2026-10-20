import Foundation

extension VaultManager {
    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one). Mirrors vettid-android
    /// `VaultManager.guard`.
    @discardableResult
    func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw noted(VaultFailures.map(error))
        }
    }

    @discardableResult
    func guardedSync<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw noted(VaultFailures.map(error))
        }
    }

    /// What a failure shows beyond its screen: MEMBER-API 1.2.0, a refusal while paused also shows the banner (the status
    /// may not have been read yet); IOS-PLAN §4.4 (1), `credential_required` the root screen (``credentialRequired``).
    func noted(_ e: any Error) -> any Error {
        guard let f = e as? VaultFailure else { return e }
        if f.kind == .servicePaused { servicePaused = true }
        if f.kind == .credentialRequired { credentialRequired = true }
        return e
    }

    /// "Try again" on the root screen "This phone can't use your vault" (IOS-PLAN §4.4 (1)): the screen that sent the
    /// request is shown again, and its own action sends it again (the daily check, and every request with the PIN, asks
    /// for the PIN and the password again: nothing was counted). Chosen; not in the spec: the request is not resent by
    /// itself, since the PIN and password it carried are not kept.
    public func dismissCredentialRequired() {
        credentialRequired = false
    }
}
