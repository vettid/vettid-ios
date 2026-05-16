import SwiftUI

// MARK: - Available Data Catalog View

/// "Available Personal Data" surface (Phase 2.7).
///
/// Shows the user's published personal-data items (the ones in
/// `PersonalDataStore.publicFieldNamespaces`) grouped first by alias and
/// then by category — mirrors Android's `PublicMetadataDialog`.
///
/// Items sharing an alias collapse into one card so multi-field bundles
/// read naturally — e.g. a contact group with alias "Wife" collapses
/// `personal.legal.first_name`, `contact.phone.mobile`, `address.home.*`
/// into a single "Wife" section. Items with no alias bucket by category.
///
/// Bucket ordering is by first-occurrence in the vault-supplied order
/// (`PersonalDataStore.fieldOrder` ranks the underlying items), so the
/// dialog respects whatever sort the owner chose on the profile editor.
struct AvailableDataCatalogView: View {

    @ObservedObject private var store = PersonalDataStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Available Personal Data")
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
        let sections = AvailableDataCatalog.sections(
            from: store.items,
            publicFieldNamespaces: store.publicFieldNamespaces
        )
        if sections.isEmpty {
            emptyView
        } else {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            AvailableDataRow(item: item)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("Nothing published yet")
                .font(.headline)
            Text("Mark personal-data fields as public on your profile and they'll show up here for connections to request.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Catalog row

private struct AvailableDataRow: View {
    let item: PersonalDataItem

    var body: some View {
        HStack {
            Image(systemName: item.category.icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                Text(item.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "eye.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Catalog Section

struct CatalogSection: Identifiable {
    /// Stable id derived from the grouping key. For alias buckets that
    /// looks like `alias:<alias>`; for category buckets, `cat:<rawValue>`.
    let id: String
    let title: String
    let items: [PersonalDataItem]
}

// MARK: - Grouping

/// Pure-function helper that computes `CatalogSection`s from a list of
/// `PersonalDataItem`s and the vault's `publicFieldNamespaces`. Exposed
/// at module-scope so both the SwiftUI view and any unit tests can call
/// the same grouping logic. Matches Android `PublicMetadataDialog`.
enum AvailableDataCatalog {

    /// Build the section list for the dialog.
    ///
    /// - Parameters:
    ///   - items: every `PersonalDataItem` known to the store, in
    ///     vault-supplied display order.
    ///   - publicFieldNamespaces: which namespaces are flagged public.
    ///     Items not in this set are skipped.
    /// - Returns: sections in display order. Aliased items group first
    ///   (one section per distinct alias), then category buckets for
    ///   anything without an alias.
    static func sections(
        from items: [PersonalDataItem],
        publicFieldNamespaces: Set<String>
    ) -> [CatalogSection] {
        // Filter to the published subset; preserve vault-supplied order.
        let visible = items.filter { publicFieldNamespaces.contains($0.id) }

        // Walk once, building two parallel ordered bucket lists. The
        // "first occurrence" of an alias / category determines its rank
        // so the sections appear in the same order as their leading
        // item in the input. Items in `PersonalDataItem.alias` are not
        // currently tracked (the alias model only landed on
        // `MinorSecret`), so for personal-data this collapses to the
        // category-only path. The alias-bucket logic is here so the
        // same helper drives the secrets catalog when 2.10 wires it.
        var aliasOrder: [String] = []
        var aliasBuckets: [String: [PersonalDataItem]] = [:]
        var categoryOrder: [DataCategory] = []
        var categoryBuckets: [DataCategory: [PersonalDataItem]] = [:]

        for item in visible {
            if let alias = alias(for: item), !alias.isEmpty {
                if aliasBuckets[alias] == nil { aliasOrder.append(alias) }
                aliasBuckets[alias, default: []].append(item)
            } else {
                if categoryBuckets[item.category] == nil {
                    categoryOrder.append(item.category)
                }
                categoryBuckets[item.category, default: []].append(item)
            }
        }

        var out: [CatalogSection] = []
        for alias in aliasOrder {
            out.append(CatalogSection(
                id: "alias:\(alias)",
                title: alias,
                items: aliasBuckets[alias] ?? []
            ))
        }
        for cat in categoryOrder {
            out.append(CatalogSection(
                id: "cat:\(cat.rawValue)",
                title: cat.displayName,
                items: categoryBuckets[cat] ?? []
            ))
        }
        return out
    }

    /// `PersonalDataItem` doesn't carry an `alias` field today (only
    /// `MinorSecret` does — Phase 2.3). The catalog dialog falls back
    /// to category grouping for personal-data items. Hook left here so
    /// when PersonalDataItem grows an alias field the bucketing kicks
    /// in automatically.
    private static func alias(for item: PersonalDataItem) -> String? {
        // Reserved for a future `item.alias` field. Always nil today.
        return nil
    }
}
