import Foundation
import VettIDVault

/// The only requests that "Try again" on the root screen "This phone can't use your vault" sends again by itself (IOS-PLAN
/// §4.4 (1), as the owner reads it): idempotent and without a secret. A request with the PIN, the password or a sealed
/// body, and a write that is not idempotent (a message, a connection's or an approval's decision), is never kept: its
/// screen sends it again.
public enum Resend: Equatable, Sendable {
    /// `settings.set` of one setting to [json]: the same value set again.
    case setting(key: String, json: String)
}

/// How the failures of a manager over the vault manager's session reach ``VaultManager/noted(_:since:resend:)``: [mark]
/// is read before the request is sent (the vault manager's lock generation), [note] gets the failure with it and the
/// ``Resend`` of the request, if it has one. ``none`` notes nothing.
public struct FailureNotes {
    let mark: @MainActor () -> Int
    let note: @MainActor (_ e: any Error, _ since: Int, _ resend: Resend?) -> any Error

    public static var none: FailureNotes { FailureNotes(mark: { 0 }, note: { e, _, _ in e }) }

    /// Runs [body] and turns every failure into a ``VaultFailure``, noted with [resend].
    @MainActor
    func run<T>(resend: Resend? = nil, _ body: () async throws -> T) async throws -> T {
        let since = mark()
        do {
            return try await body()
        } catch {
            throw note(VaultFailures.map(error), since, resend)
        }
    }
}

extension VaultManager {
    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one); [resend] is the request
    /// "Try again" on the root screen sends again (``noted(_:since:resend:)``). Mirrors vettid-android `VaultManager.guard`.
    @discardableResult
    func guarded<T>(resend: Resend? = nil, _ body: () async throws -> T) async throws -> T {
        let since = lockGeneration
        do {
            return try await body()
        } catch {
            throw noted(VaultFailures.map(error), since: since, resend: resend)
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

    /// The managers' way to ``noted(_:since:resend:)``.
    static func failureNotes(_ ref: ManagerRef) -> FailureNotes {
        FailureNotes(
            mark: { ref.manager?.lockGeneration ?? 0 },
            note: { e, since, resend in ref.manager?.noted(e, since: since, resend: resend) ?? e }
        )
    }

    /// What a failure shows beyond its screen. MEMBER-API 1.2.0: a refusal while paused also shows the banner (the status
    /// may not have been read yet). IOS-PLAN §4.4 (1): `credential_required` to a request the member sent
    /// (``VaultFailures/memberRequest(_:)``; never one the app sends by itself, such as the reads on every open) shows the
    /// root screen (``credentialRequired``), unless a lock was asked for since the request was sent ([since], the lock
    /// generation then). [resend] is kept for "Try again".
    func noted(_ e: any Error, since: Int, resend: Resend? = nil) -> any Error {
        guard let f = e as? VaultFailure else { return e }
        if f.kind == .servicePaused { servicePaused = true }
        if f.kind == .credentialRequired, since == lockGeneration, VaultFailures.memberRequest(f) {
            credentialRequired = true
            credentialRequiredResend = resend
        }
        return e
    }

    /// "Try again" on the root screen "This phone can't use your vault" (IOS-PLAN §4.4 (1), as the owner reads it): a
    /// ``Resend`` (a setting) is sent again as it was; for any other request the screen that sent it is shown again, with
    /// its secret fields empty, and its own action sends it (nothing was counted).
    public func credentialRequiredTryAgain() {
        credentialRequired = false
        let resend = credentialRequiredResend
        credentialRequiredResend = nil
        if let resend { Task { try? await self.resend(resend) } }
    }

    /// Sends [r] again, noted as it was.
    func resend(_ r: Resend) async throws {
        switch r {
        case .setting(let key, let json):
            try await guarded(resend: r) { try await setSetting(try await openSession(), key, json) }
        }
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
        // The member's own item and tag writes and reveals (§10.7, §10.8; a critical item's are credential operations).
        "item.put", "item.reveal", "item.tag", "item.sensitivity", "item.delete", "tag.set", "tag.delete", "tag.merge",
    ]

    /// Whether [f] is the vault's answer to a request of ``memberTypes``.
    static func memberRequest(_ f: VaultFailure) -> Bool {
        guard let op = f.cause as? VaultOpError else { return false }
        return memberTypes.contains(op.type) || op.type.hasPrefix("device.transfer.")
    }
}
