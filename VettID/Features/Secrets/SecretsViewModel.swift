import Foundation
import SwiftUI

// MARK: - Secrets View Model

@MainActor
final class SecretsViewModel: ObservableObject {

    enum State {
        case loading
        case empty
        case loaded([Secret])
        case error(String)
    }

    @Published var state: State = .loading
    @Published var revealedSecretId: String? = nil
    @Published var revealedValue: String? = nil
    @Published var showPasswordPrompt = false
    @Published var passwordError: String? = nil
    @Published var autoHideCountdown: Int = 30

    private var secrets: [Secret] = []
    private var autoHideTask: Task<Void, Never>?
    private var pendingRevealSecretId: String?
    private var cachedPassword: String?

    private let secretsStore = SecretsStore()

    // MARK: - Load Secrets

    func loadSecrets() async {
        state = .loading

        do {
            secrets = try secretsStore.retrieveAll()

            if secrets.isEmpty {
                state = .empty
            } else {
                state = .loaded(secrets)
            }
        } catch {
            state = .error("Failed to load secrets: \(error.localizedDescription)")
        }
    }

    // MARK: - Search/Filter

    func filteredSecrets(searchText: String) -> [Secret] {
        if searchText.isEmpty {
            return secrets
        }
        return secrets.filter { secret in
            secret.name.localizedCaseInsensitiveContains(searchText) ||
            secret.category.displayName.localizedCaseInsensitiveContains(searchText) ||
            (secret.notes?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    // MARK: - Reveal Secret (Password Required)

    func requestRevealSecret(_ secretId: String) {
        pendingRevealSecretId = secretId
        passwordError = nil
        showPasswordPrompt = true
    }

    func verifyPasswordAndReveal(_ password: String) async {
        guard let secretId = pendingRevealSecretId else { return }

        // Verify password against stored hash
        let isValid = await verifyPassword(password)

        if !isValid {
            passwordError = "Invalid password"
            return
        }

        // Password verified - decrypt and reveal secret
        showPasswordPrompt = false
        passwordError = nil

        // Decrypt the secret value
        if let value = await decryptSecret(secretId, password: password) {
            revealedSecretId = secretId
            revealedValue = value
            startAutoHideTimer()
        } else {
            passwordError = "Failed to decrypt secret"
        }

        pendingRevealSecretId = nil
    }

    func cancelPasswordPrompt() {
        showPasswordPrompt = false
        pendingRevealSecretId = nil
        passwordError = nil
    }

    // MARK: - Hide Secret

    func hideSecret() {
        autoHideTask?.cancel()
        autoHideTask = nil
        revealedSecretId = nil
        revealedValue = nil
        autoHideCountdown = 30
    }

    // MARK: - Auto-Hide Timer

    private func startAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideCountdown = 30

        autoHideTask = Task {
            while autoHideCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                if Task.isCancelled { return }
                autoHideCountdown -= 1
            }

            if !Task.isCancelled {
                hideSecret()
            }
        }
    }

    // MARK: - Password Verification

    private func verifyPassword(_ password: String) async -> Bool {
        // Check if password hash is set up
        guard secretsStore.hasPasswordHash() else {
            // No password hash set - accept any non-empty password for first-time setup
            // In production, this should be tied to vault password
            return !password.isEmpty
        }

        return await secretsStore.verifyPassword(password)
    }

    // MARK: - Decryption

    private func decryptSecret(_ secretId: String, password: String) async -> String? {
        guard let secret = secrets.first(where: { $0.id == secretId }) else {
            return nil
        }

        do {
            let decrypted = try secretsStore.decryptValue(secret.encryptedValue, password: password)
            // Cache password for subsequent operations in this session
            cachedPassword = password
            return decrypted
        } catch {
            #if DEBUG
            print("Decryption failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Add Secret

    func addSecret(name: String, value: String, category: Secret.SecretCategory, notes: String?, password: String) async {
        do {
            // Encrypt the secret value
            let encryptedValue = try secretsStore.encryptValue(value, password: password)

            let newSecret = Secret(
                id: UUID().uuidString,
                name: name,
                encryptedValue: encryptedValue,
                category: category,
                notes: notes,
                createdAt: Date(),
                updatedAt: Date()
            )

            // Store in keychain
            try secretsStore.store(secret: newSecret)

            secrets.insert(newSecret, at: 0)
            state = .loaded(secrets)
        } catch {
            state = .error("Failed to save secret: \(error.localizedDescription)")
        }
    }

    /// Add secret using cached password (from recent verification)
    func addSecret(name: String, value: String, category: Secret.SecretCategory, notes: String?) async {
        guard let password = cachedPassword else {
            state = .error("Password required to add secret")
            return
        }
        await addSecret(name: name, value: value, category: category, notes: notes, password: password)
    }

    // MARK: - Delete Secret

    func deleteSecret(_ secretId: String) async {
        do {
            try secretsStore.delete(id: secretId)
            secrets.removeAll { $0.id == secretId }

            if secrets.isEmpty {
                state = .empty
            } else {
                state = .loaded(secrets)
            }
        } catch {
            state = .error("Failed to delete secret: \(error.localizedDescription)")
        }
    }

    // MARK: - Clear Cached Password

    func clearCachedPassword() {
        cachedPassword = nil
    }
}
