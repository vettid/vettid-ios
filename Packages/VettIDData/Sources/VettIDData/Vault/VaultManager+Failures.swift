import Foundation
import VettIDVault

/// A request that "Try again" on the root screen "This phone can't use your vault" sends again (IOS-PLAN §4.4 (1)).
public typealias RetryAction = @MainActor () async -> Void

/// How the failures of a manager over the vault manager's session reach ``VaultManager/noted(_:since:retry:)``: [mark]
/// is read before the request is sent (the vault manager's lock generation), [note] gets the failure with it and, for a
/// request without a secret, the action that sends it again. ``none`` notes nothing.
public struct FailureNotes {
    let mark: @MainActor () -> Int
    let note: @MainActor (_ e: any Error, _ since: Int, _ retry: RetryAction?) -> any Error

    public static var none: FailureNotes { FailureNotes(mark: { 0 }, note: { e, _, _ in e }) }

    /// Runs [body] and turns every failure into a ``VaultFailure``, noted with [retry].
    @MainActor
    func run<T>(retry: RetryAction? = nil, _ body: () async throws -> T) async throws -> T {
        let since = mark()
        do {
            return try await body()
        } catch {
            throw note(VaultFailures.map(error), since, retry)
        }
    }
}

extension VaultManager {
    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one); [retry] sends a request
    /// without a secret again from the root screen (``noted(_:since:retry:)``). Mirrors vettid-android `VaultManager.guard`.
    @discardableResult
    func guarded<T>(retry: RetryAction? = nil, _ body: () async throws -> T) async throws -> T {
        let since = lockGeneration
        do {
            return try await body()
        } catch {
            throw noted(VaultFailures.map(error), since: since, retry: retry)
        }
    }

    @discardableResult
    func guardedSync<T>(_ body: () throws -> T) throws -> T {
        let since = lockGeneration
        do {
            return try body()
        } catch {
            throw noted(VaultFailures.map(error), since: since)
        }
    }

    /// The managers' way to ``noted(_:since:retry:)``.
    static func failureNotes(_ ref: ManagerRef) -> FailureNotes {
        FailureNotes(
            mark: { ref.manager?.lockGeneration ?? 0 },
            note: { e, since, retry in ref.manager?.noted(e, since: since, retry: retry) ?? e }
        )
    }

    /// What a failure shows beyond its screen. MEMBER-API 1.2.0: a refusal while paused also shows the banner (the status
    /// may not have been read yet). IOS-PLAN §4.4 (1): `credential_required` to a request the member sent
    /// (``VaultFailures/memberRequest(_:)``; never one the app sends by itself, such as the reads on every open) shows the
    /// root screen (``credentialRequired``), unless a lock was asked for since the request was sent ([since], the lock
    /// generation then). [retry] is kept for "Try again": a request without a secret is sent again as it was.
    func noted(_ e: any Error, since: Int, retry: RetryAction? = nil) -> any Error {
        guard let f = e as? VaultFailure else { return e }
        if f.kind == .servicePaused { servicePaused = true }
        if f.kind == .credentialRequired, since == lockGeneration, VaultFailures.memberRequest(f) {
            credentialRequired = true
            credentialRequiredRetry = retry
        }
        return e
    }

    /// "Try again" on the root screen "This phone can't use your vault" (IOS-PLAN §4.4 (1), as the owner reads it): a
    /// request without a secret (a setting) is sent again as it was; for a request with the PIN or the password, the
    /// screen that sent it is shown again with its secret fields empty, and its own action sends it (nothing was counted).
    public func credentialRequiredTryAgain() {
        credentialRequired = false
        let retry = credentialRequiredRetry
        credentialRequiredRetry = nil
        if let retry { Task { await retry() } }
    }
}

extension VaultFailures {
    /// The owner-facing requests the member sends (IOS-PLAN §4.4 (1): the daily check, a credential operation, a change,
    /// `account.name.set`, `device.transfer.*`, `vault.delete`, `settings.set`). Not the reads the app sends by itself
    /// (`vault.status`, `account.get`, `credential.version`, the lists).
    static let memberTypes: Set<String> = [
        "vault.owner-check", "pin.change", "vault.secret.renew", "account.name.set", "vault.delete", "settings.set",
        "credential.unlock", "credential.rotate", "credential.password.change", "credential.reset", "credential.get",
        "credential.ack", "credential.utk.get",
    ]

    /// Whether [f] is the vault's answer to a request of ``memberTypes``.
    static func memberRequest(_ f: VaultFailure) -> Bool {
        guard let op = f.cause as? VaultOpError else { return false }
        return memberTypes.contains(op.type) || op.type.hasPrefix("device.transfer.")
    }
}
