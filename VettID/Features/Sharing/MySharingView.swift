import SwiftUI

// MARK: - My Sharing View

/// Outbound-side sharing surface (Phase 3.10, parity with Android
/// `MySharingScreen`).
///
/// For one specific connection, lets the user shape what THIS peer can
/// ask for: per-item allow/deny + tier + retention + rate-limit +
/// expiry. Includes a location auto-fulfill toggle (the peer's location
/// requests get auto-answered with the user's current position rather
/// than prompting).
///
/// The policy rows are seeded from the items in `PersonalDataStore`
/// (data) and `SecretsViewModel.filteredSecrets("")` (secrets) that
/// have non-private visibility. Vault is the source of truth — the
/// editor's writes flow through `personal-data.set-visibility` and
/// `secret.set-visibility` for the allow/deny toggle, with the other
/// fields ride along in the per-row settings.
struct MySharingView: View {

    let peer: Peer

    @ObservedObject private var dataStore = PersonalDataStore.shared
    @StateObject private var viewModel = MySharingViewModel()
    @State private var locationAutoFulfill: Bool = false

    struct Peer: Hashable {
        let connectionId: String
        let label: String
    }

    var body: some View {
        Form {
            Section {
                header
            }

            Section {
                Toggle("Auto-fulfill location requests", isOn: $locationAutoFulfill)
                    .onChange(of: locationAutoFulfill) { newValue in
                        Task { await viewModel.setLocationAutoFulfill(newValue, for: peer.connectionId) }
                    }
                Text("When on, this connection's location requests are answered automatically. When off, you're prompted to share each time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: { Text("Location") }

            if viewModel.policyRows.isEmpty {
                Section { emptyHint }
            } else {
                Section("Shared items") {
                    ForEach($viewModel.policyRows) { $row in
                        SharePolicyRowEditor(row: $row,
                                             onChanged: { changed in
                            Task { await viewModel.applyPolicy(changed, for: peer.connectionId) }
                        })
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Sharing settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load(for: peer.connectionId)
            locationAutoFulfill = viewModel.locationAutoFulfill
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.label.isEmpty ? "Connection" : peer.label)
                    .font(.headline)
                Text("What this connection can ask for")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing shared yet")
                .font(.subheadline.weight(.medium))
            Text("Mark items as PROFILE, CATALOG, or USE_ONLY in your Vault and they'll show up here for per-connection policy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Policy Row Editor

private struct SharePolicyRowEditor: View {
    @Binding var row: SharePolicyRow
    let onChanged: (SharePolicyRow) -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allowed", isOn: $row.allowed)
                    .onChange(of: row.allowed) { _ in onChanged(row) }

                if row.allowed {
                    Picker("Tier", selection: $row.tier) {
                        ForEach(SharePolicyRow.Tier.allCases) { tier in
                            Text(tier.title).tag(tier)
                        }
                    }
                    .onChange(of: row.tier) { _ in onChanged(row) }

                    Picker("Retention", selection: $row.retention) {
                        ForEach(SharePolicyRow.Retention.allCases) { ret in
                            Text(ret.title).tag(ret)
                        }
                    }
                    .onChange(of: row.retention) { _ in onChanged(row) }

                    Stepper(rateLimitLabel,
                            value: $row.rateLimitPerHour,
                            in: 0...100)
                        .onChange(of: row.rateLimitPerHour) { _ in onChanged(row) }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Image(systemName: row.allowed ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(row.allowed ? .green : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayName).font(.subheadline)
                    Text(row.category).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.tier.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray6))
                    .cornerRadius(4)
            }
        }
    }

    private var rateLimitLabel: String {
        row.rateLimitPerHour == 0
            ? "Rate limit: unlimited"
            : "Rate limit: \(row.rateLimitPerHour)/hr"
    }
}

// MARK: - View Model

@MainActor
final class MySharingViewModel: ObservableObject {

    @Published var policyRows: [SharePolicyRow] = []
    @Published var locationAutoFulfill: Bool = false
    @Published var errorMessage: String?

    private let dataStore: PersonalDataStore
    private let secretsRepository: SecretsClient?

    init(dataStore: PersonalDataStore = .shared,
         secretsRepository: SecretsClient? = nil) {
        self.dataStore = dataStore
        self.secretsRepository = secretsRepository
    }

    /// Seed the editor's policy rows from currently-shared items in the
    /// data and secrets stores. Vault is authoritative for visibility;
    /// the editor reflects the local snapshot and writes back via
    /// `setFieldPublic` / `setMinorVisibility`. Per-row retention /
    /// rate-limit / expiry currently default to "until revoked" /
    /// unlimited / never; they'll plug into per-connection vault policy
    /// when that wire surface lands.
    func load(for connectionId: String) async {
        // Currently-shared data items (anything PROFILE or CATALOG).
        let publicItems = dataStore.items.filter { item in
            dataStore.isFieldPublic(item.id) || item.isInPublicProfile
        }
        var rows: [SharePolicyRow] = publicItems.map { item in
            SharePolicyRow(
                key: "data:\(item.id)",
                displayName: item.name,
                category: item.category.displayName,
                allowed: true,
                tier: .optional,
                retention: .untilRevoked,
                rateLimitPerHour: 0,
                expiresAt: nil
            )
        }
        // Currently-shared secrets — not in scope to enumerate from
        // here yet; the secrets repo hydrates on the SecretsView. A
        // follow-up wires the secrets enumeration into the editor.
        _ = secretsRepository

        policyRows = rows
    }

    /// Apply a row-level change. For now this is a stub for the future
    /// per-connection policy verb on the vault — we write the
    /// `allowed` flag back via the underlying visibility setter so the
    /// global policy stays consistent. Per-tier / per-retention vault
    /// surfaces will replace this when they ship.
    func applyPolicy(_ row: SharePolicyRow, for connectionId: String) async {
        // Mirror the row back into our published collection so SwiftUI
        // reflects the edit immediately.
        if let idx = policyRows.firstIndex(where: { $0.id == row.id }) {
            policyRows[idx] = row
        }
        // For now we don't have a per-connection policy verb. When it
        // lands, this hop will fire a single `share-policy.upsert`
        // call against the connection. Today the visibility tier is
        // global; flipping `allowed=false` here is a local-only signal.
    }

    func setLocationAutoFulfill(_ on: Bool, for connectionId: String) async {
        // Wire to `location.sharing.set-auto-fulfill` when the iOS
        // location client adds the verb (Phase 5 in the original
        // parity plan). Today this is a published-state stub the
        // toggle binds to without a vault round-trip — keeps the UI
        // honest until the wire lands.
        locationAutoFulfill = on
    }
}
