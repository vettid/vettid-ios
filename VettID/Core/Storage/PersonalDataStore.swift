import Foundation
import Combine

// MARK: - Personal Data Store

/// In-memory cache + vault-backed writer for personal data.
///
/// The vault is the only persistent home for user data — every field,
/// custom category, public-profile selection, and sort-order entry lives
/// in a vault namespace (`personal-data/`, `profile/_categories`,
/// `profile/_public`, `personal-data/_sort_order`). This class is a
/// transient cache: in-memory only, populated on demand via `hydrate()`
/// after PIN unlock, dropped when the process ends.
///
/// Why a cache layer at all: ViewModels publish a synchronous view of
/// items to SwiftUI, so we need fast reads without a NATS round-trip per
/// render. The cache mirrors authoritative vault state and is refreshed
/// whenever the vault publishes a new snapshot via
/// `forApp.profile.public` — covers multi-device edits and any
/// out-of-band catalog changes the local ViewModels didn't drive.
///
/// Writes flow vault-first: every public mutator dispatches the
/// appropriate vault op and updates the cache only on success.
///
/// SECURITY (parity with Android `PersonalDataStore`). The cache lives
/// in memory only; nothing reaches device disk.
@MainActor
final class PersonalDataStore: ObservableObject {

    static let shared = PersonalDataStore()

    // MARK: - Published state

    @Published private(set) var items: [PersonalDataItem] = []
    @Published private(set) var isHydrated: Bool = false
    @Published private(set) var lastError: String?

    /// Authoritative set of namespaces the vault has marked public
    /// (Phase 2.11). Sourced from `profile.get`'s `public_fields` —
    /// the canonical view — falling back to `profile.get-published`'s
    /// `public_profile_fields` when `profile.get` is unavailable.
    /// Surfaces (catalog dialog, profile editor) should consult this
    /// rather than a per-item bool that could drift from vault truth.
    @Published private(set) var publicFieldNamespaces: Set<String> = []

    /// Vault-supplied display order for personal-data fields
    /// (Phase 2.8 prerequisite). Empty when the vault hasn't sent one;
    /// surfaces fall back to `PersonalDataItem.sortOrder` in that case.
    @Published private(set) var fieldOrder: [String] = []

    // MARK: - Dependencies (wired by configure())

    private var profileClient: ProfileClient?
    private var personalDataClient: PersonalDataClient?
    private var ownerSpaceClient: OwnerSpaceClient?
    private var snapshotTickTask: Task<Void, Never>?

    private init() {}

    // MARK: - Configuration

    /// Wire up clients once the vault is reachable. Idempotent. Call after
    /// `warmVault` succeeds; subsequent calls swap clients in place
    /// (e.g. after credential rotation).
    func configure(
        profileClient: ProfileClient,
        personalDataClient: PersonalDataClient,
        ownerSpaceClient: OwnerSpaceClient
    ) {
        self.profileClient = profileClient
        self.personalDataClient = personalDataClient
        self.ownerSpaceClient = ownerSpaceClient

        // Start the own-profile snapshot subscription; re-hydrate on every
        // publish so multi-device edits land in the cache without manual
        // pull-to-refresh.
        if snapshotTickTask == nil {
            ownerSpaceClient.startOwnProfileSnapshotSubscription()
            snapshotTickTask = Task { [weak self] in
                guard let stream = self?.ownerSpaceClient?.ownProfileSnapshotTicks else { return }
                for await _ in stream {
                    if Task.isCancelled { return }
                    try? await self?.hydrate()
                }
            }
        }
    }

    // MARK: - Hydrate

    /// Fan out the vault reads that build the cache. Idempotent — calling
    /// more than once just refreshes.
    func hydrate() async throws {
        guard let profileClient = profileClient,
              let personalDataClient = personalDataClient else {
            throw PersonalDataStoreError.notConfigured
        }

        do {
            var built: [PersonalDataItem] = []

            // 1) Published profile: system fields, public-field selection,
            //    photo, field_order. The canonical view that peers see.
            let published = try await profileClient.getPublishedProfile()
            let firstName = published["first_name"] as? String ?? ""
            let lastName = published["last_name"] as? String ?? ""
            let email = published["email"] as? String ?? ""

            // 1b) Authoritative public_fields source (Phase 2.11): prefer
            //     `profile.get` (the canonical full profile) over
            //     `profile.get-published`'s `public_profile_fields`. The
            //     latter is what peers see today, but it may lag a
            //     just-flipped toggle by a vault tick; `profile.get`
            //     reflects the very-latest local state. Fall back if
            //     `profile.get` doesn't return the field.
            let canonical = (try? await profileClient.getProfile()) ?? [:]
            let canonicalPublic: [String]? = canonical["public_fields"] as? [String]
            let publishedPublic: [String]? = published["public_profile_fields"] as? [String]
            let publicFields: Set<String> = Set(canonicalPublic ?? publishedPublic ?? [])
            let canonicalOrder: [String]? = canonical["field_order"] as? [String]
            let publishedOrder: [String]? = published["field_order"] as? [String]
            let vaultFieldOrder: [String] = canonicalOrder ?? publishedOrder ?? []

            if !firstName.isEmpty {
                built.append(systemField("_system_first_name", "First Name", firstName, publicFields))
            }
            if !lastName.isEmpty {
                built.append(systemField("_system_last_name", "Last Name", lastName, publicFields))
            }
            if !email.isEmpty {
                built.append(systemField("_system_email", "Email", email, publicFields))
            }

            // 2) Personal-data fields: namespaced optional + custom entries.
            //    Each value is a { "value": ..., "is_public": ... } shape.
            let fields = try await personalDataClient.getPersonalData()
            for (namespace, raw) in fields {
                guard let dict = raw as? [String: Any],
                      let value = dict["value"] as? String,
                      !value.isEmpty else { continue }
                built.append(makeField(namespace: namespace, value: value, raw: dict, publicFields: publicFields))
            }

            // 3) Sort-order: fold the namespace→index map into each item.
            let order = try await personalDataClient.getSortOrder()
            for i in built.indices {
                if let idx = order[built[i].id] {
                    built[i].sortOrder = idx
                }
            }

            // Publish the auxiliary view-models — consumers can react
            // to public_fields / field_order changes without poking at
            // individual items.
            self.publicFieldNamespaces = publicFields
            self.fieldOrder = vaultFieldOrder

            // Sort: if the vault gave us a field_order, prefer it.
            // Otherwise fall back to PersonalDataItem.sortOrder.
            if !vaultFieldOrder.isEmpty {
                let rank: [String: Int] = Dictionary(
                    uniqueKeysWithValues: vaultFieldOrder.enumerated().map { ($1, $0) }
                )
                built.sort { lhs, rhs in
                    let lr = rank[lhs.id] ?? Int.max
                    let rr = rank[rhs.id] ?? Int.max
                    if lr != rr { return lr < rr }
                    return lhs.sortOrder < rhs.sortOrder
                }
            } else {
                built.sort { $0.sortOrder < $1.sortOrder }
            }

            self.items = built
            self.isHydrated = true
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Writes (vault-first; cache updated on success)

    /// Set a single field's value. Pushes through `personal-data.update`,
    /// then refreshes the cache via `hydrate()` to pick up any
    /// vault-side side effects (sort-order shift, photo regeneration, etc.).
    func updateField(namespace: String, value: String) async throws {
        guard let client = personalDataClient else {
            throw PersonalDataStoreError.notConfigured
        }
        try await client.updatePersonalData(fields: [namespace: value])
        try await hydrate()
    }

    /// Delete a single field. Mirrors Android's per-namespace delete path.
    func deleteField(namespace: String) async throws {
        guard let client = personalDataClient else {
            throw PersonalDataStoreError.notConfigured
        }
        try await client.deleteField(namespace: namespace)
        try await hydrate()
    }

    /// Source-of-truth check: is this namespace in the vault's
    /// `public_fields` set? Phase 2.11 — consumers should call this
    /// rather than reading `PersonalDataItem.isInPublicProfile`, which
    /// is a snapshot taken at hydrate time and can drift if a write
    /// is in flight.
    func isFieldPublic(_ namespace: String) -> Bool {
        publicFieldNamespaces.contains(namespace)
    }

    /// Toggle public-profile membership for a single field.
    func setFieldPublic(namespace: String, isPublic: Bool) async throws {
        guard let client = personalDataClient else {
            throw PersonalDataStoreError.notConfigured
        }
        try await client.setFieldPublicVisibility(namespace: namespace, isPublic: isPublic)
        try await hydrate()
    }

    /// Push a new sort order. The argument map is namespace→index.
    func updateSortOrder(_ order: [String: Int]) async throws {
        guard let client = personalDataClient else {
            throw PersonalDataStoreError.notConfigured
        }
        try await client.updateSortOrder(order)
        // Cache reflects the new order immediately without round-trip.
        for i in items.indices {
            if let idx = order[items[i].id] {
                items[i].sortOrder = idx
            }
        }
        items.sort { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Reset

    /// Drop the in-memory cache (e.g. on logout). The vault retains
    /// everything; a subsequent `hydrate()` rebuilds the cache.
    func reset() {
        items = []
        isHydrated = false
        snapshotTickTask?.cancel()
        snapshotTickTask = nil
        profileClient = nil
        personalDataClient = nil
        ownerSpaceClient = nil
    }

    // MARK: - Builders (private)

    private func systemField(_ namespace: String, _ displayName: String, _ value: String, _ publicFields: Set<String>) -> PersonalDataItem {
        let isPublic = publicFields.contains(namespace)
        return PersonalDataItem(
            id: namespace,
            name: displayName,
            type: isPublic ? .public : .private,
            value: value,
            category: .identity,
            fieldType: namespace.contains("email") ? .email : .text,
            isSystemField: true,
            isInPublicProfile: isPublic,
            isSensitive: false,
            sortOrder: 0
        )
    }

    private func makeField(namespace: String, value: String, raw: [String: Any], publicFields: Set<String>) -> PersonalDataItem {
        let mapped = Self.namespaceToCategoryAndName(namespace)
        // `is_public` on the field record wins; fall back to the
        // top-level public-fields set for older vault payloads.
        let isPublic = (raw["is_public"] as? Bool) ?? publicFields.contains(namespace)
        return PersonalDataItem(
            id: namespace,
            name: mapped.name,
            type: isPublic ? .public : .private,
            value: value,
            category: mapped.category,
            fieldType: Self.fieldType(for: namespace),
            isSystemField: false,
            isInPublicProfile: isPublic,
            isSensitive: false,
            sortOrder: 0
        )
    }

    /// Map a dotted namespace to (category, human-readable name). Known
    /// optional namespaces are listed explicitly to match Android's
    /// `KNOWN_OPTIONAL_NAMESPACES`; anything else is treated as a custom
    /// field and gets a derived name + `.other` category.
    private static func namespaceToCategoryAndName(_ namespace: String) -> (category: DataCategory, name: String) {
        switch namespace {
        case "personal.legal.prefix":       return (.identity, "Name Prefix")
        case "personal.legal.first_name":   return (.identity, "Legal First Name")
        case "personal.legal.middle_name":  return (.identity, "Middle Name")
        case "personal.legal.last_name":    return (.identity, "Legal Last Name")
        case "personal.legal.suffix":       return (.identity, "Name Suffix")
        case "contact.phone.mobile":        return (.contact, "Mobile Phone")
        case "personal.info.birthday":      return (.identity, "Birthday")
        case "address.home.street":         return (.address, "Street")
        case "address.home.street2":        return (.address, "Street 2")
        case "address.home.city":           return (.address, "City")
        case "address.home.state":          return (.address, "State")
        case "address.home.postal_code":    return (.address, "Postal Code")
        case "address.home.country":        return (.address, "Country")
        case "social.website.personal":     return (.contact, "Website")
        case "social.linkedin.url":         return (.contact, "LinkedIn")
        case "social.twitter.handle":       return (.contact, "X/Twitter")
        case "social.instagram.handle":     return (.contact, "Instagram")
        case "social.github.username":      return (.contact, "GitHub")
        default:
            let last = namespace.split(separator: ".").last.map(String.init) ?? namespace
            let display = last.replacingOccurrences(of: "_", with: " ").capitalized
            return (.other, display)
        }
    }

    private static func fieldType(for namespace: String) -> FieldType {
        if namespace.contains("phone")    { return .phone }
        if namespace.contains("birthday") { return .date }
        if namespace.hasSuffix("date") || namespace.hasSuffix("expiry") { return .date }
        if namespace.contains("website") || namespace.hasSuffix(".url") { return .url }
        if namespace.contains("email")    { return .email }
        return .text
    }
}

// MARK: - Errors

enum PersonalDataStoreError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PersonalDataStore not configured — call configure() after vault warm"
        }
    }
}
