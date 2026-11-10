import Foundation

/// The member's own credential key for Settings → Vault status (ANDROID-PLAN 0.1.119 §4 "Owner check and status";
/// VAULT-MESSAGING 0.83.8 §10.8). Part of ``VaultRepository``.
@MainActor
public protocol CredentialKeyRepository: AnyObject {
    /// `credential.version` for Vault status's Credential key row, asked each time the screen opens. Throws a
    /// ``VaultFailure`` when it cannot be asked (an error, a timeout, a locked vault). Default: ``FailureKind/notSupported``.
    func credentialKey() async throws -> CredentialKeyAnswer

    /// The credential key of the latest create, rotate or reset answer, so that the row shows the new one at
    /// once (``CredentialKeyChange``). Default: nil.
    var credentialKeyChange: CredentialKeyChange? { get }
}

public extension CredentialKeyRepository {
    func credentialKey() async throws -> CredentialKeyAnswer { throw VaultFailure(.notSupported) }
    var credentialKeyChange: CredentialKeyChange? { nil }
}
