import SwiftUI

// MARK: - Available Secrets Catalog View

/// "Available Secrets" surface (Phase 2.7).
///
/// Sibling to `AvailableDataCatalogView` but driven by the secrets list
/// from `SecretsViewModel`. Shows the user's PROFILE/CATALOG/USE_ONLY
/// secrets (anything not `.private`) grouped first by alias and then by
/// category. Secrets sharing an alias collapse into one card so multi-
/// key bundles like "Trading Wallet" read as a single group.
///
/// Matches Android's secrets catalog dialog, which uses the same
/// alias-then-category rule.
struct AvailableSecretsCatalogView: View {

    @ObservedObject var viewModel: SecretsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Available Secrets")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        // Secrets the user has flagged anything other than `.private`
        // are catalog-visible. The viewModel exposes the current list
        // via its loaded state — read it via filteredSecrets("") which
        // returns the whole set in vault-supplied order.
        let visible = viewModel.filteredSecrets(searchText: "")
            .filter { $0.visibility != .private }
        let sections = AvailableSecretsCatalog.sections(from: visible)

        if sections.isEmpty {
            emptyView
        } else {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { secret in
                            AvailableSecretRow(secret: secret)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.open")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("Nothing cataloged yet")
                .font(.headline)
            Text("Mark a secret as Public or Catalog and it'll show up here for connections to request.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct AvailableSecretRow: View {
    let secret: MinorSecret

    var body: some View {
        HStack {
            Image(systemName: secret.category.icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                if let alias = secret.alias, !alias.isEmpty {
                    Text(secret.name + " — " + alias)
                        .font(.subheadline)
                } else {
                    Text(secret.name).font(.subheadline)
                }
                Text(secret.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: secret.visibility.icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Catalog Section

struct SecretCatalogSection: Identifiable {
    let id: String
    let title: String
    let items: [MinorSecret]
}

// MARK: - Grouping

/// Pure-function helper that groups secrets the same way Android's
/// secrets catalog dialog does: alias-first (multi-record bundles
/// collapse), then category for items with no alias. Public so the
/// SwiftUI view and any unit tests can share the logic.
enum AvailableSecretsCatalog {

    static func sections(from secrets: [MinorSecret]) -> [SecretCatalogSection] {
        var aliasOrder: [String] = []
        var aliasBuckets: [String: [MinorSecret]] = [:]
        var categoryOrder: [SecretCategory] = []
        var categoryBuckets: [SecretCategory: [MinorSecret]] = [:]

        for s in secrets {
            if let alias = s.alias?.trimmingCharacters(in: .whitespaces),
               !alias.isEmpty {
                if aliasBuckets[alias] == nil { aliasOrder.append(alias) }
                aliasBuckets[alias, default: []].append(s)
            } else {
                if categoryBuckets[s.category] == nil { categoryOrder.append(s.category) }
                categoryBuckets[s.category, default: []].append(s)
            }
        }

        var out: [SecretCatalogSection] = []
        for alias in aliasOrder {
            out.append(SecretCatalogSection(
                id: "alias:\(alias)",
                title: friendlyAliasTitle(alias, items: aliasBuckets[alias] ?? []),
                items: aliasBuckets[alias] ?? []
            ))
        }
        for cat in categoryOrder {
            out.append(SecretCatalogSection(
                id: "cat:\(cat.rawValue)",
                title: cat.displayName,
                items: categoryBuckets[cat] ?? []
            ))
        }
        return out
    }

    /// Friendly title for an alias bucket. When every secret in the
    /// bucket has the same `SecretType` (e.g. all `.cryptoKey`), we
    /// suffix the alias with that type — "Trading Wallet · Keys" —
    /// to communicate the bundle kind. Single-type bundles only.
    private static func friendlyAliasTitle(_ alias: String, items: [MinorSecret]) -> String {
        guard items.count > 1 else { return alias }
        let types = Set(items.map { $0.type })
        guard types.count == 1, let only = types.first else { return alias }
        // Hide the suffix for plain .text bundles where it adds noise.
        if only == .text { return alias }
        return "\(alias) · \(only.displayName)"
    }
}
