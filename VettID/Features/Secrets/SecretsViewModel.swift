import Foundation
import SwiftUI

// MARK: - Secrets View Model

/// Vault-backed minor-secrets list.
///
/// As of Phase 2.1, reads + writes go through `SecretsClient` (vault
/// `secret.*` verbs) instead of the on-device `SecretsStore` (Keychain).
/// The vault encrypts the value under the user's DEK after warm-up, so
/// minor secrets no longer require a per-reveal password prompt — the
/// DEK being loaded is the gate. The legacy password-prompt API is kept
/// briefly for source compatibility with `SecretsView`, but it now
/// always passes through (no client-side decryption).
///
/// Critical secrets stay on `CriticalSecretsViewModel`; that surface
/// keeps the password gate because critical secrets live inside the
/// credential blob and require `credential.secret.get` with a password-
/// encrypted envelope (Phase D).
@MainActor
final class SecretsViewModel: ObservableObject {

    enum State {
        case loading
        case empty
        case loaded([MinorSecret])
        case error(String)
    }

    @Published var state: State = .loading
    @Published var revealedSecretId: String? = nil
    @Published var revealedValue: String? = nil
    @Published var showPasswordPrompt = false
    @Published var passwordError: String? = nil
    @Published var autoHideCountdown: Int = 30

    /// Injected by the parent view via `.task` after vault warm-up.
    /// `AppState.secretsClient` is the source of truth. When nil, the
    /// view shows an empty state — there's nothing meaningful to render
    /// without a live vault connection.
    var client: SecretsClient?

    private var secrets: [MinorSecret] = []
    private var autoHideTask: Task<Void, Never>?

    // MARK: - Load Secrets

    func loadSecrets() async {
        state = .loading
        guard let client = client else {
            state = .empty
            return
        }

        do {
            let rows = try await client.listMinor()
            secrets = rows.compactMap { MinorSecret.from(vaultDict: $0) }
                          .sorted { $0.sortOrder < $1.sortOrder }
            state = secrets.isEmpty ? .empty : .loaded(secrets)
        } catch {
            state = .error("Failed to load secrets: \(error.localizedDescription)")
        }
    }

    // MARK: - Search / Filter

    func filteredSecrets(searchText: String) -> [MinorSecret] {
        if searchText.isEmpty { return secrets }
        return secrets.filter { secret in
            secret.name.localizedCaseInsensitiveContains(searchText) ||
            (secret.alias?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            secret.category.displayName.localizedCaseInsensitiveContains(searchText) ||
            (secret.notes?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    func groupedSecrets(searchText: String) -> [(category: SecretCategory, secrets: [MinorSecret])] {
        let filtered = filteredSecrets(searchText: searchText)
        let grouped = Dictionary(grouping: filtered) { $0.category }
        return SecretCategory.allCases.compactMap { category in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            return (category: category, secrets: items.sorted { $0.sortOrder < $1.sortOrder })
        }
    }

    // MARK: - Sort with Groups (unchanged from legacy — vault may or may
    // not assign groupId; the UI handles both shapes)

    func sortWithGroups(_ secrets: [MinorSecret]) -> [MinorSecret] {
        var groupedMap: [String: [MinorSecret]] = [:]
        var ungrouped: [MinorSecret] = []
        for secret in secrets {
            if let groupId = secret.groupId {
                groupedMap[groupId, default: []].append(secret)
            } else {
                ungrouped.append(secret)
            }
        }
        for key in groupedMap.keys {
            groupedMap[key]?.sort { $0.sortOrder < $1.sortOrder }
        }
        let sortedGroups = groupedMap.sorted { lhs, rhs in
            let lhsOrder = lhs.value.first?.sortOrder ?? 0
            let rhsOrder = rhs.value.first?.sortOrder ?? 0
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return (lhs.value.first?.name ?? "") < (rhs.value.first?.name ?? "")
        }
        ungrouped.sort { $0.sortOrder < $1.sortOrder }

        var result: [MinorSecret] = []
        var gIdx = 0, uIdx = 0
        while gIdx < sortedGroups.count || uIdx < ungrouped.count {
            let nextG = gIdx < sortedGroups.count
                ? (sortedGroups[gIdx].value.first?.sortOrder ?? Int.max) : Int.max
            let nextU = uIdx < ungrouped.count ? ungrouped[uIdx].sortOrder : Int.max
            if nextG <= nextU {
                result.append(contentsOf: sortedGroups[gIdx].value)
                gIdx += 1
            } else {
                result.append(ungrouped[uIdx])
                uIdx += 1
            }
        }
        return result
    }

    // MARK: - Reveal Secret (vault round-trip, no password prompt)

    /// Reveal a minor secret's value. The vault DEK is the gate; the
    /// password prompt path on SecretsView is now a no-op pass-through.
    func requestRevealSecret(_ secretId: String) {
        Task { await revealSecret(secretId) }
    }

    /// Legacy entrypoint kept so `SecretsView`'s existing password sheet
    /// compiles. Password is ignored — the vault performs the actual
    /// gate via the DEK loaded during warm.
    func verifyPasswordAndReveal(_ password: String) async {
        // No-op: minor secrets aren't password-gated anymore. If the
        // sheet is showing, dismiss it and reveal.
        showPasswordPrompt = false
        passwordError = nil
        // Caller invokes us with the currently-selected secret id; for
        // backwards compat we resolve from `pendingRevealSecretId` if
        // SecretsView ever sets it. Today there's no pending id field
        // here; rely on requestRevealSecret instead.
        _ = password
    }

    private func revealSecret(_ secretId: String) async {
        guard let client = client else {
            passwordError = "Not connected"
            return
        }
        do {
            guard let value = try await client.getMinor(id: secretId), !value.isEmpty else {
                passwordError = "Secret unavailable"
                return
            }
            revealedSecretId = secretId
            revealedValue = value
            startAutoHideTimer()
        } catch {
            passwordError = "Failed to reveal: \(error.localizedDescription)"
        }
    }

    func cancelPasswordPrompt() {
        showPasswordPrompt = false
        passwordError = nil
    }

    // MARK: - Hide / auto-hide

    func hideSecret() {
        autoHideTask?.cancel()
        autoHideTask = nil
        revealedSecretId = nil
        revealedValue = nil
        autoHideCountdown = 30
    }

    private func startAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideCountdown = 30
        autoHideTask = Task {
            while autoHideCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                autoHideCountdown -= 1
            }
            if !Task.isCancelled { hideSecret() }
        }
    }

    // MARK: - Add Secret

    /// Add a new minor secret via the vault. `password` is ignored — the
    /// vault encrypts the value under the DEK; minor secrets no longer
    /// carry a per-record password. Signature kept for compatibility
    /// with SecretsView's existing call site.
    func addSecret(name: String,
                   value: String,
                   category: SecretCategory,
                   notes: String?,
                   password: String) async {
        _ = password
        await addSecret(name: name, value: value, category: category, notes: notes)
    }

    func addSecret(name: String,
                   value: String,
                   category: SecretCategory,
                   notes: String?,
                   alias: String? = nil) async {
        guard let client = client else {
            state = .error("Not connected")
            return
        }
        do {
            let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await client.addMinor(
                category: category.rawValue,
                label: name,
                alias: (trimmedAlias?.isEmpty == false) ? trimmedAlias : nil,
                value: value,
                fields: nil,
                visibility: .private
            )
            await loadSecrets()
        } catch {
            state = .error("Failed to save secret: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete Secret

    func deleteSecret(_ secretId: String) async {
        guard let client = client else {
            state = .error("Not connected")
            return
        }
        do {
            try await client.deleteMinor(id: secretId)
            secrets.removeAll { $0.id == secretId }
            state = secrets.isEmpty ? .empty : .loaded(secrets)
        } catch {
            state = .error("Failed to delete secret: \(error.localizedDescription)")
        }
    }

    // MARK: - Legacy no-ops (Phase 2.1 transition)
    //
    // `clearCachedPassword` was called by SecretsView when the password
    // sheet was dismissed. Minor secrets don't cache a password anymore.
    func clearCachedPassword() {}
}
