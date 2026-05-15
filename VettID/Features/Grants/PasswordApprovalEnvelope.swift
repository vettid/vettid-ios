import Foundation

// MARK: - Password Approval Envelope

/// Shared helper for the three password-gated approval screens
/// (DataGrant / CriticalUseApproval / IdentityVerifyApproval) plus
/// `CriticalSecretsViewModel`. Hashes the password with Argon2id, pulls
/// a fresh UTK from the credential store, encrypts the hash under the
/// UTK's public key, and packages the result + the per-attempt salt
/// for the vault envelope.
///
/// Lives in Features/Grants/ rather than Core/Crypto because it's the
/// approval-screen contract, but the building blocks (`PasswordHasher`,
/// `CryptoManager.encryptPasswordHash`, `CredentialStore.getUnusedKey`)
/// are all in Core. Phase 3 — every approve call site funnels through
/// here so the password-envelope wire format is built one way.
struct PasswordApprovalEnvelope {
    let encryptedPasswordHash: String
    let ephemeralPublicKey: String
    let nonce: String
    let salt: String
    let utkKeyId: String?

    /// Build an envelope from a user-entered password. Throws when no
    /// UTK is available — the vault will reject the request anyway, so
    /// we fail fast and surface as `.notReady`.
    static func build(password: String,
                      credentialStore: CredentialStore = CredentialStore()) throws -> PasswordApprovalEnvelope {
        let hashResult = try PasswordHasher.hash(password: password)
        guard let credential = try credentialStore.retrieveFirst(),
              let utk = credential.getUnusedKey() else {
            throw PasswordApprovalError.notReady
        }
        let payload = try CryptoManager.encryptPasswordHash(
            passwordHash: hashResult.hash,
            utkPublicKeyBase64: utk.publicKey
        )
        return PasswordApprovalEnvelope(
            encryptedPasswordHash: payload.encryptedPasswordHash,
            ephemeralPublicKey: payload.ephemeralPublicKey,
            nonce: payload.nonce,
            salt: hashResult.salt.base64EncodedString(),
            utkKeyId: utk.keyId
        )
    }
}

enum PasswordApprovalError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Vault isn't ready for password-gated requests yet. Unlock the app and try again."
        }
    }
}
