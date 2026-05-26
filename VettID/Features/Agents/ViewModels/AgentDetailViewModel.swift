import Foundation
import Combine

/// One minor secret in the visibility list, with its current
/// discoverability state. Mirrors Android `VisibilityItem`.
struct VisibilityItem: Identifiable, Equatable {
    let secretId: String
    let name: String
    /// Alias group label when the secret is part of a multi-field
    /// alias (Area A). Surfaced as a subtitle so the user can tell
    /// "passport.number — Driver's License" apart from a singleton.
    let alias: String?
    let category: String
    /// Wire value: "PROFILE" | "CATALOG" | "PRIVATE" | "USE_ONLY".
    let discoverability: String

    var id: String { secretId }
    /// True iff the secret is exposed to peers / agents.
    /// PRIVATE = hidden; everything else is at least cataloged.
    var visible: Bool {
        let v = discoverability.uppercased()
        return !v.isEmpty && v != "PRIVATE"
    }
}

/// LEASH mint dialog state — lives on `AgentDetailState.loaded.mint`.
/// Nil when no dialog open. Mirrors Android `MintDialogState`.
struct MintDialogState: Equatable {
    var scopes: [MintScopeToggle]
    var customScope: String
    var durationSeconds: Int
    var submitting: Bool = false
    var result: MintResult? = nil
    var error: String? = nil
}

struct MintScopeToggle: Equatable, Identifiable {
    let token: String
    let label: String
    let description: String
    var granted: Bool
    var id: String { token }
}

struct MintResult: Equatable {
    let jwt: String
    let jti: String
    let expiresAt: Int
}

enum AgentDetailState: Equatable {
    case loading
    case loaded(agent: AgentConnection, items: [VisibilityItem], mint: MintDialogState?)
    case error(String)
}

/// View-model for the per-agent details screen. Mirrors Android
/// `AgentDetailViewModel` (commit 855a9f5 + supporting commits).
///
/// Loads the agent's record + the user's minor-secret inventory with
/// per-item discoverability. Lets the owner flip each secret's
/// visibility in bulk (a global change — visible-to-agent also means
/// visible to peers; that matches Android's current model).
///
/// Also owns the Mint LEASH dialog: scope toggles + free-form
/// custom-scope + duration chips → `leash.attest` → JWT/jti/expires-at
/// result.
@MainActor
final class AgentDetailViewModel: ObservableObject {

    @Published private(set) var state: AgentDetailState = .loading
    @Published var toast: String?

    private var ownerSpaceClient: OwnerSpaceClient?
    private var connectionId: String = ""

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    func bind(connectionId: String) async {
        if self.connectionId == connectionId, case .loaded = state { return }
        self.connectionId = connectionId
        await load()
    }

    /// Re-fetch everything. Used by pull-to-refresh + after a
    /// visibility toggle that the vault confirmed.
    func refresh() async { await load() }

    private func load() async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }
        state = .loading
        do {
            guard let agent = try await fetchAgent(client: client) else {
                state = .error("Agent not found")
                return
            }
            let items = try await fetchMinorSecrets(client: client)
            state = .loaded(agent: agent, items: items, mint: nil)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Bulk visibility toggles

    func toggleVisibility(secretId: String, makeVisible: Bool) async {
        guard case .loaded(let agent, var items, let mint) = state else { return }
        guard let secretsClient = currentSecretsClient() else { return }
        let target = makeVisible ? SecretVisibility.catalog : .private
        do {
            try await secretsClient.setMinorVisibility(id: secretId, visibility: target)
            // Mutate local state optimistically so the toggle moves
            // instantly; a subsequent forApp.profile.public tick from
            // the vault will replace the row anyway.
            if let idx = items.firstIndex(where: { $0.secretId == secretId }) {
                let updated = VisibilityItem(
                    secretId: items[idx].secretId,
                    name: items[idx].name,
                    alias: items[idx].alias,
                    category: items[idx].category,
                    discoverability: target.wireValue
                )
                items[idx] = updated
            }
            state = .loaded(agent: agent, items: items, mint: mint)
        } catch {
            toast = "Couldn't update visibility: \(error.localizedDescription)"
        }
    }

    func bulkSet(makeVisible: Bool) async {
        guard case .loaded(_, let items, _) = state else { return }
        // Only flip rows currently in the opposite state — saves
        // round-trips on a no-op toggle.
        let targets = items.filter { $0.visible != makeVisible }.map { $0.secretId }
        for id in targets {
            await toggleVisibility(secretId: id, makeVisible: makeVisible)
        }
    }

    // MARK: - Mint LEASH dialog

    func openMint() {
        guard case .loaded(let agent, let items, _) = state else { return }
        let toggles = LeashScopeCatalog.common.map {
            MintScopeToggle(
                token: $0.token,
                label: $0.label,
                description: $0.description,
                granted: $0.defaultGranted
            )
        }
        let dialog = MintDialogState(
            scopes: toggles,
            customScope: "",
            durationSeconds: Self.defaultMintDuration
        )
        state = .loaded(agent: agent, items: items, mint: dialog)
    }

    func closeMint() {
        guard case .loaded(let agent, let items, _) = state else { return }
        state = .loaded(agent: agent, items: items, mint: nil)
    }

    func mintToggleScope(_ token: String, granted: Bool) {
        updateMint { dialog in
            var d = dialog
            d.scopes = d.scopes.map {
                $0.token == token
                    ? MintScopeToggle(token: $0.token, label: $0.label, description: $0.description, granted: granted)
                    : $0
            }
            return d
        }
    }

    func mintSetCustomScope(_ token: String) {
        updateMint { dialog in
            var d = dialog
            d.customScope = token
            d.error = nil
            return d
        }
    }

    func mintSetDuration(_ seconds: Int) {
        updateMint { dialog in
            var d = dialog
            d.durationSeconds = seconds
            return d
        }
    }

    func mintConfirm() async {
        guard case .loaded(let agent, let items, let mintOpt) = state,
              let mint = mintOpt else { return }

        var granted = mint.scopes.filter { $0.granted }.map { $0.token }
        let custom = mint.customScope.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            if !LeashScopeCatalog.isValidScope(custom) {
                updateMint { d in
                    var x = d
                    x.error = "Custom scope token doesn't match the LEASH grammar."
                    return x
                }
                return
            }
            if !granted.contains(custom) { granted.append(custom) }
        }
        guard !granted.isEmpty else {
            updateMint { d in
                var x = d
                x.error = "Grant at least one scope before minting."
                return x
            }
            return
        }

        // Submit
        var submitting = mint
        submitting.submitting = true
        submitting.error = nil
        state = .loaded(agent: agent, items: items, mint: submitting)

        guard let client = ownerSpaceClient else {
            failMint("Not connected to vault")
            return
        }

        do {
            let response = try await client.sendAndAwaitResponse(
                "leash.attest",
                payload: [
                    "connection_id": AnyCodableValue(agent.connectionId),
                    "scope": AnyCodableValue(granted as [Any]),
                    "duration_secs": AnyCodableValue(mint.durationSeconds),
                    // Vault populates agent_pubkey from the
                    // connection record when empty (matches Android).
                    "agent_pubkey": AnyCodableValue("")
                ],
                timeout: 30
            )
            guard response.success, let result = response.result else {
                failMint(response.error ?? "Mint failed")
                return
            }
            let jwt = (result["leash"] as? String) ?? ""
            let jti = (result["jti"] as? String) ?? ""
            let expires: Int = {
                if let i = result["expires_at"] as? Int { return i }
                if let d = result["expires_at"] as? Double { return Int(d) }
                return 0
            }()
            updateMint { d in
                var x = d
                x.submitting = false
                x.result = MintResult(jwt: jwt, jti: jti, expiresAt: expires)
                return x
            }
        } catch {
            failMint(error.localizedDescription)
        }
    }

    private func failMint(_ message: String) {
        updateMint { d in
            var x = d
            x.submitting = false
            x.error = message
            return x
        }
    }

    private func updateMint(_ transform: (MintDialogState) -> MintDialogState) {
        guard case .loaded(let agent, let items, let mintOpt) = state,
              let mint = mintOpt else { return }
        state = .loaded(agent: agent, items: items, mint: transform(mint))
    }

    // MARK: - Vault fetches

    private func fetchAgent(client: OwnerSpaceClient) async throws -> AgentConnection? {
        let response = try await client.sendAndAwaitResponse(
            "agent.list",
            timeout: 15
        )
        guard response.success else { return nil }
        let agents = response.getArray("agents") ?? []
        guard let dict = agents.first(where: { ($0["connection_id"] as? String) == connectionId }) else {
            return nil
        }
        return AgentConnection.from(dict: dict)
    }

    private func fetchMinorSecrets(client: OwnerSpaceClient) async throws -> [VisibilityItem] {
        let secretsClient = SecretsClient(ownerSpaceClient: client)
        let rows = try await secretsClient.listMinor()
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let name = (row["label"] ?? row["name"]) as? String ?? "Untitled"
            return VisibilityItem(
                secretId: id,
                name: name,
                alias: row["alias"] as? String,
                category: (row["category"] as? String) ?? "other",
                discoverability: (row["visibility"] as? String) ?? "PRIVATE"
            )
        }
    }

    private func currentSecretsClient() -> SecretsClient? {
        guard let client = ownerSpaceClient else { return nil }
        return SecretsClient(ownerSpaceClient: client)
    }

    private static let defaultMintDuration: Int = 30 * 60   // 30 min — matches Android demo session
}
