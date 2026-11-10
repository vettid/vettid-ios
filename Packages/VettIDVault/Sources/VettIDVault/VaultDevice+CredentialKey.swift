import Foundation

/// The credential key (§10.6 `key`, standard base64) of a credential this device kept from the vault's answer
/// (``VaultDevice/credentialKeyChanges()``). [key] nil: an answer that replaced the credential (`credential.create`,
/// `.rotate`, `.reset`) named no key, so the key is not known here. Not a secret (VAULT-MESSAGING 0.83.8 §10.8), and
/// never printed.
public struct CredentialKeySeen: Equatable, Sendable, CustomStringConvertible {
    public let key: String?

    public init(key: String?) {
        self.key = key
    }

    public var description: String { "CredentialKeySeen" }
}

// The member's own credential key, for Settings → Vault status (VAULT-MESSAGING 0.83.8 §10.8; ANDROID-PLAN 0.1.119 §4).
// Mirrors vettid-android `VaultDevice.credentialKeyChanges`.
extension VaultDevice {
    /// The credential key of every credential this device keeps from an answer that names one (only `credential.create`,
    /// `.rotate` and `.reset` answers do, §10.6), and a nil key when such an answer named none. Only after the credential
    /// is stored. A transfer or a recovery emits nothing: the new phone learns the key from `credential.version` (§10.8).
    public func credentialKeyChanges() -> AsyncStream<CredentialKeySeen> { keyBroadcast.stream() }

    /// A credential was kept from an answer naming [key] (nil: it replaced the credential without naming one).
    func noteCredentialKey(_ key: String?) { keyBroadcast.emit(CredentialKeySeen(key: key)) }
}
