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

    // MARK: - Load Secrets

    func loadSecrets() async {
        state = .loading

        // Simulate loading delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        // For now, use mock data
        // TODO: Load from secure storage
        secrets = Secret.mockSecrets()

        if secrets.isEmpty {
            state = .empty
        } else {
            state = .loaded(secrets)
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
        // TODO: Implement actual password verification using stored hash
        // For now, accept any non-empty password
        return !password.isEmpty
    }

    // MARK: - Decryption

    private func decryptSecret(_ secretId: String, password: String) async -> String? {
        // TODO: Implement actual decryption
        // For now, return mock value

        // Simulate decryption delay
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Return mock decrypted value
        guard let secret = secrets.first(where: { $0.id == secretId }) else {
            return nil
        }

        switch secret.category {
        case .password:
            return "SuperSecr3tP@ssw0rd!"
        case .apiKey:
            return "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        case .pin:
            return "1234"
        case .recoveryCode:
            return "ABCD-EFGH-IJKL-MNOP\nQRST-UVWX-YZ12-3456"
        case .note, .other:
            return "This is the secret content that was encrypted."
        }
    }

    // MARK: - Add Secret

    func addSecret(name: String, value: String, category: Secret.SecretCategory, notes: String?) async {
        // TODO: Encrypt and store secret
        let newSecret = Secret(
            id: UUID().uuidString,
            name: name,
            encryptedValue: "encrypted_\(value)",
            category: category,
            notes: notes,
            createdAt: Date(),
            updatedAt: Date()
        )

        secrets.insert(newSecret, at: 0)
        state = .loaded(secrets)
    }

    // MARK: - Delete Secret

    func deleteSecret(_ secretId: String) async {
        secrets.removeAll { $0.id == secretId }

        if secrets.isEmpty {
            state = .empty
        } else {
            state = .loaded(secrets)
        }
    }
}
