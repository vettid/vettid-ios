import Foundation
import SwiftUI

// MARK: - Critical Secrets ViewModel

/// Vault-backed critical-secrets surface.
///
/// As of Phase 2.1, the password gate is real — entered passwords are
/// hashed (Argon2id via `PasswordHasher`), encrypted under a freshly
/// rotated UTK, and sent in the same envelope shape the vault expects
/// for `credential.secret.list` and `credential.secret.get` (Phase D).
/// The mock metadata is gone; rows come from the vault. Values come on
/// demand from a second password-gated round-trip.
///
/// Each network call consumes one UTK from the local pool — the vault
/// rejects reuse, so we mark the UTK used right after the request
/// returns regardless of outcome. The pool is replenished by the
/// vault's normal post-op `new_utks` rotation.
@MainActor
final class CriticalSecretsViewModel: ObservableObject {

    @Published var state: CriticalSecretsState = .passwordPrompt
    @Published var secretsMetadata: [CriticalSecretMetadata] = []
    @Published var searchText: String = ""
    @Published var autoHideCountdown: Int = 30

    /// Injected by the parent view via `.task` after vault warm-up.
    /// Source of truth lives on `AppState.secretsClient`.
    var client: SecretsClient?

    private let credentialStore: ProteanCredentialStore
    private var autoHideTask: Task<Void, Never>?

    init(credentialStore: ProteanCredentialStore = ProteanCredentialStore()) {
        self.credentialStore = credentialStore
    }

    // MARK: - Filtered Metadata

    var filteredMetadata: [CriticalSecretMetadata] {
        if searchText.isEmpty { return secretsMetadata }
        return secretsMetadata.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.category.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - First password — fetch metadata

    func authenticateForMetadata(password: String) async {
        state = .authenticating

        guard let client = client else {
            state = .error("Not connected to vault")
            return
        }

        do {
            let env = try Self.buildPasswordEnvelope(password: password)
            let rows = try await client.listCritical(
                encryptedPasswordHash: env.payload.encryptedPasswordHash,
                ephemeralPublicKey:    env.payload.ephemeralPublicKey,
                nonce:                 env.payload.nonce,
                salt:                  env.salt,
                utkKeyId:              env.utkKeyId
            )
            secretsMetadata = rows.compactMap(Self.parseMetadata(from:))
            state = .metadataList
        } catch CriticalSecretsError.invalidPassword {
            state = .error("Invalid password")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Second password — reveal value

    func requestReveal(secretId: String) {
        state = .secondPasswordPrompt(secretId: secretId)
    }

    func authenticateAndReveal(secretId: String, password: String) async {
        state = .retrieving(secretId: secretId)

        guard let client = client else {
            state = .error("Not connected to vault")
            return
        }

        do {
            let env = try Self.buildPasswordEnvelope(password: password)
            let value = try await client.getCritical(
                id: secretId,
                encryptedPasswordHash: env.payload.encryptedPasswordHash,
                ephemeralPublicKey:    env.payload.ephemeralPublicKey,
                nonce:                 env.payload.nonce,
                salt:                  env.salt
            )
            autoHideCountdown = 30
            state = .revealed(secretId: secretId, value: value, countdown: 30)
            startAutoHideTimer()
        } catch {
            state = .error("Invalid password or vault rejected the request")
        }
    }

    // MARK: - Auto-hide (30s)

    private func startAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideCountdown = 30
        autoHideTask = Task {
            while autoHideCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                autoHideCountdown -= 1
                if case .revealed(let id, let value, _) = state {
                    state = .revealed(secretId: id, value: value, countdown: autoHideCountdown)
                }
            }
            if !Task.isCancelled { hideSecret() }
        }
    }

    func hideSecret() {
        autoHideTask?.cancel()
        autoHideTask = nil
        autoHideCountdown = 30
        state = .metadataList
    }

    // MARK: - Navigation

    func backToMetadataList() {
        autoHideTask?.cancel()
        state = .metadataList
    }

    func backToPasswordPrompt() {
        secretsMetadata = []
        state = .passwordPrompt
    }

    // MARK: - Password envelope helpers

    /// Bundle the password-encryption inputs the vault expects: hash the
    /// password with Argon2id, fetch a UTK from the local pool, encrypt
    /// the hash under that UTK's public key.
    private struct PasswordEnvelope {
        let payload: EncryptedPasswordPayload
        let salt: String
        /// The UTK key id used — included in the wire envelope so the
        /// vault knows which key the ephemeral was derived against.
        let utkKeyId: String?
    }

    private static func buildPasswordEnvelope(password: String) throws -> PasswordEnvelope {
        let hashResult = try PasswordHasher.hash(password: password)

        let store = ProteanCredentialStore()
        let credentialStore = CredentialStore()
        let utk = (try credentialStore.retrieveFirst())?.getUnusedKey()
        _ = store // store-shaped methods land below as Phase D matures

        // If we have no UTK in the pool the vault will refuse the request.
        // Surface that as a generic invalid-password to avoid leaking
        // local-state-vs-server-state to the prompt UI.
        guard let utk = utk else {
            throw CriticalSecretsError.invalidPassword
        }
        let payload = try CryptoManager.encryptPasswordHash(
            passwordHash: hashResult.hash,
            utkPublicKeyBase64: utk.publicKey
        )
        return PasswordEnvelope(
            payload: payload,
            salt: hashResult.salt.base64EncodedString(),
            utkKeyId: utk.keyId
        )
    }

    // MARK: - Wire decoder

    private static func parseMetadata(from dict: [String: Any]) -> CriticalSecretMetadata? {
        guard let id = dict["id"] as? String,
              let name = (dict["label"] ?? dict["name"]) as? String else {
            return nil
        }
        let categoryRaw = (dict["category"] as? String) ?? "vault_secret"
        let category = CriticalSecretCategory(rawValue: categoryRaw) ?? .vaultSecret
        let createdAt = (dict["created_at"] as? Double)
            ?? (dict["created_at"] as? Int).map(Double.init) ?? 0
        let updatedAt = (dict["updated_at"] as? Double)
            ?? (dict["updated_at"] as? Int).map(Double.init) ?? createdAt
        return CriticalSecretMetadata(
            id: id,
            name: name,
            category: category,
            createdAt: createdAt > 0 ? Date(timeIntervalSince1970: createdAt) : Date(),
            updatedAt: updatedAt > 0 ? Date(timeIntervalSince1970: updatedAt) : Date()
        )
    }
}

// MARK: - Errors

private enum CriticalSecretsError: LocalizedError {
    case invalidPassword

    var errorDescription: String? {
        switch self {
        case .invalidPassword: return "Invalid password"
        }
    }
}
